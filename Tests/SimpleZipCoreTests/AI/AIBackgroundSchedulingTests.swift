//
//  AIBackgroundSchedulingTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:后台静默调度确定性条件(白皮书工程补充五)。启动静默期 / 重任务 / 低电 / 空闲 / 充电门控,
//  最深工作档位 none→deterministicIndex→modelPrewarm→deepContext。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIBackgroundSchedulingTests {
    /// 默认 = 充电 + 空闲 + 模型可用 + 平衡档(满足最深档),各测覆写需要的字段。
    private func ctx(
        appIsActive: Bool = false, heavy: Bool = false,
        sinceLaunch: Int = 300, sinceInteraction: Int = 120,
        powerSaver: Bool = false, lowBattery: Bool = false, charging: Bool? = true,
        model: Bool = true, level: AIBackgroundActivityLevel = .balanced
    ) -> AIBackgroundRuntimeContext {
        AIBackgroundRuntimeContext(
            appIsActive: appIsActive, runningTaskCount: 0, heavyArchiveTaskRunning: heavy,
            secondsSinceLaunch: sinceLaunch, secondsSinceLastInteraction: sinceInteraction,
            powerSaverMode: powerSaver, lowBattery: lowBattery, isCharging: charging,
            modelAvailable: model, activityLevel: level)
    }

    @Test func launchSilencePeriodBlocksEverything() {
        let t = AIBackgroundSchedulingRules.deepestAllowedTier(ctx(sinceLaunch: 30))
        #expect(t == .none)
    }

    @Test func heavyTaskBlocksEverything() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(heavy: true)) == .none)
    }

    @Test func activityOffBlocksEverything() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(level: .off)) == .none)
    }

    @Test func deterministicIndexWhenModelUnavailable() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(model: false)) == .deterministicIndex)
    }

    @Test func deterministicIndexWhenLowBattery() {
        // 低电只跑确定性索引。
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(lowBattery: true)) == .deterministicIndex)
    }

    @Test func deterministicIndexWhenPowerSaver() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(powerSaver: true)) == .deterministicIndex)
    }

    @Test func deterministicIndexWhenUserNotIdle() {
        // 用户刚交互(<20s)→ 不跑模型任务。
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(sinceInteraction: 5)) == .deterministicIndex)
    }

    @Test func deepContextWhenNotChargingButBalanced() {
        // 2026-06-18:去掉「充电中」硬要求后,电池供电(balanced)也能进 deepContext —— 否则 MacBook 用户
        // 归档定性 / 文件组 / 归档主动建议永远不跑。挡 deepContext 的只剩 powerSaver 档 / 低电 / 模型不可用。
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(charging: false)) == .deepContext)
    }

    @Test func modelPrewarmWhenChargingButPowerSaverLevel() {
        // 省电档(power-saver activity level)不满足 deepContext 的「平衡/积极」要求。
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(level: .powerSaver)) == .modelPrewarm)
    }

    @Test func deepContextWhenChargingIdleBalanced() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx()) == .deepContext)
    }

    @Test func deepContextWhenAggressive() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(level: .aggressive)) == .deepContext)
    }

    @Test func tierOrdering() {
        #expect(AIBackgroundWorkTier.none < .deterministicIndex)
        #expect(AIBackgroundWorkTier.deterministicIndex < .modelPrewarm)
        #expect(AIBackgroundWorkTier.modelPrewarm < .deepContext)
    }

    @Test func individualGatesConsistent() {
        let deep = ctx()
        #expect(AIBackgroundSchedulingRules.canRunDeterministicIndexing(deep))
        #expect(AIBackgroundSchedulingRules.canRunModelWork(deep))
        #expect(AIBackgroundSchedulingRules.canRunDeepContext(deep))
    }

    @Test func codableRoundTrip() throws {
        let c = ctx(appIsActive: true, sinceLaunch: 120, charging: false)
        let decoded = try JSONDecoder().decode(AIBackgroundRuntimeContext.self, from: JSONEncoder().encode(c))
        #expect(decoded == c)
    }

    // MARK: - 后台规划器(工程补充五:aggressive = 本地智能维护员)

    private let ws = AIStableHash.deterministicUUID("ws-plan")
    private let fileRef = AIContextSourceRef(kind: .file, id: "fs-1")
    private let epoch = Date(timeIntervalSince1970: 0)

    private func planningInput(
        runtime: AIBackgroundRuntimeContext, gaps: [AIWorkspaceEvidenceGap] = [],
        staleWorkspaces: [UUID] = [], staleSurfaces: [AISuggestionSurfaceID] = [],
        interaction: AIInteractionCounterSummary? = nil,
        interest: AIInterestSummary = AIInterestSummary(reactionPreferences: [], locationAffinities: [])
    ) -> AIBackgroundPlanningInput {
        AIBackgroundPlanningInput(
            runtime: runtime,
            interactionSummary: interaction ?? AIInteractionCounterSummary(window: "30d", generatedAt: epoch, counters: []),
            recentInterestSummary: interest, workspaceEvidenceGaps: gaps,
            staleWorkspaceIDs: staleWorkspaces, staleSuggestionSurfaces: staleSurfaces,
            indexHealth: AIIndexMaintenanceFacts())
    }

    @Test func plannerNoneTierYieldsEmptyPlan() {
        let plan = AIBackgroundPlanner.plan(planningInput(runtime: ctx(sinceLaunch: 30)))  // 启动静默期
        #expect(plan.allowedTier == .none)
        #expect(plan.isEmpty)
    }

    @Test func plannerDeterministicTierFiltersModelJobs() {
        // model 不可用 → 天花板 deterministicIndex;模型档 job(主题/虚拟树/预热)被剔除。
        let plan = AIBackgroundPlanner.plan(planningInput(
            runtime: ctx(model: false),
            gaps: [.missingHash(id: "g1", workspaceID: ws, refs: [fileRef], reason: "no hash")],
            staleWorkspaces: [ws], staleSurfaces: [.mainWindowSuggestion]))
        #expect(plan.allowedTier == .deterministicIndex)
        #expect(plan.jobs.allSatisfy { $0.requiredTier <= .deterministicIndex })
        #expect(plan.jobs.contains { $0.kind == .calculateCheapHashes })          // 确定性补哈希保留
        #expect(!plan.jobs.contains { $0.kind == .generateWorkspaceThemes })       // 模型档剔除
        #expect(!plan.jobs.contains { $0.kind == .prewarmMainWindowSuggestions })
    }

    @Test func plannerEvidenceGapBecomesBoostedHashJob() {
        let counter = AIInteractionCounterSummary.Counter(
            surface: "activityTaskRow", interaction: "expanded", targetKind: "task", targetToken: nil,
            roleTag: "release-package", diagnosticTag: "checksum-mismatch", locationKind: nil,
            count: 5, lastAt: nil, positiveOutcomeCount: 0, negativeOutcomeCount: 0)
        let plan = AIBackgroundPlanner.plan(planningInput(
            runtime: ctx(model: false),
            gaps: [.missingHash(id: "g1", workspaceID: ws, refs: [fileRef], reason: "no hash")],
            interaction: AIInteractionCounterSummary(window: "30d", generatedAt: epoch, counters: [counter])))
        let hashJob = plan.jobs.first { $0.kind == .calculateCheapHashes }
        #expect(hashJob?.sourceRefs == [fileRef])
        #expect(hashJob?.priority == 25)        // normal urgency 20 + 失败关注 boost 5
        #expect(hashJob?.budgetKey == "hash")
    }

    @Test func plannerStaleSurfacesBecomePrewarmJobs() {
        let plan = AIBackgroundPlanner.plan(planningInput(
            runtime: ctx(level: .powerSaver),    // modelPrewarm 档(充电不再决定深档,powerSaver 才挡在 deepContext 外)
            staleSurfaces: [.mainWindowSuggestion, .activityCenter, .settingsPane]))
        #expect(plan.allowedTier == .modelPrewarm)
        #expect(plan.jobs.contains { $0.kind == .prewarmMainWindowSuggestions })
        #expect(plan.jobs.contains { $0.kind == .prewarmActivityWorkbench })
        #expect(plan.jobs.contains { $0.kind == .prewarmSettingsDoctor })
    }

    @Test func plannerIsDeterministicAndSortedByPriority() {
        let input = planningInput(
            runtime: ctx(charging: false),
            gaps: [.missingHash(id: "g1", workspaceID: ws, refs: [fileRef], reason: "x", urgency: .high)],
            staleSurfaces: [.settingsPane])
        #expect(AIBackgroundPlanner.plan(input) == AIBackgroundPlanner.plan(input))   // 确定性
        let priorities = AIBackgroundPlanner.plan(input).jobs.map(\.priority)
        #expect(priorities == priorities.sorted(by: >))                              // 优先级降序
    }
}
