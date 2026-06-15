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

    @Test func modelPrewarmWhenIdleButNotCharging() {
        #expect(AIBackgroundSchedulingRules.deepestAllowedTier(ctx(charging: false)) == .modelPrewarm)
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
}
