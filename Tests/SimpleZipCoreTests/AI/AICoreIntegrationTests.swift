//
//  AICoreIntegrationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:Core AI 组合场景测试(白皮书工程补充一·加固 10 / acceptance「组合场景测试」)。
//  单类型测试已很多;这里验证几条**跨类型组合**:反馈→排序降权、任务时间→年龄事实、无读权限→内容挡但
//  路径/权限事实仍可用。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AICoreIntegrationTests {
    private let now = Date(timeIntervalSince1970: 100_000_000)

    /// dismiss 反馈 → 排序降权(AIFeedback × AIRanking)。
    @Test func dismissFeedbackDemotesInRanking() {
        let fb = AIFeedbackEvent(targetKind: .workspace, targetID: "ws", kind: .dismissed,
                                 surface: .sidebar, createdAt: now)
        var ctx = AIRankingContext(base: 0.5)
        if fb.isNegative { ctx = ctx.adding(.demote("feedback", 0.4, reason: fb.kind.rawValue)) }

        let demoted = AIRankingDecision.evaluate(ctx)
        let baseline = AIRankingDecision.evaluate(AIRankingContext(base: 0.5))
        #expect(demoted.verdict == .demoted)
        #expect(demoted.score < baseline.score)
        #expect(demoted.rankedSignals.first?.kind == "feedback")
    }

    /// 强 dismiss 把候选压到阈值以下 → 被压制(不展示)。
    @Test func strongNegativeFeedbackSuppresses() {
        let ctx = AIRankingContext(base: 0.3,
                                   signals: [.demote("not-interested", 0.5, reason: "user-x")],
                                   suppressionThreshold: 0)
        #expect(AIRankingDecision.evaluate(ctx).verdict == .suppressed)
    }

    /// 活动中心任务时间 → 年龄事实 + 时段桶(ActivityTask 时间 × AITimeSemantics)。
    @Test func taskTimeEntersAgeFactsAndTimeBucket() {
        // 任务昨晚 ~20:00 完成,now 是约 20 小时后。
        let finishedAt = now.addingTimeInterval(-20 * 3_600)
        let age = AIAgeFacts.make(from: finishedAt, now: now)
        #expect(age.bucket == .today)            // < 24h
        #expect(!age.isStale)
        #expect(AITimeBucket.bucket(forHour: 20) == .evening)   // App 提取的小时落到时段桶
    }

    /// 长期未动的大文件:90 天前 → stale,驱动「长期未动」主题。
    @Test func longIdleFileIsStale() {
        #expect(AIAgeFacts.make(from: now.addingTimeInterval(-120 * 86_400), now: now).isStale)
    }

    /// 无读权限:内容不进 facts,但路径哈希 / 权限事实仍可用(AIFileReadabilityPolicy × promptProjection)。
    @Test func noReadPermissionKeepsPathFactsButBlocksContent() {
        let loc = AILocationContext(kind: .desktop, pathHash: "loc-desk", folderNameTokens: ["desktop"])
        let fact = AIFileSystemFact.make(
            absolutePath: "/Users/yumeka/Desktop/locked.bin", location: loc,
            posixMode: "rw-------", currentUserCanRead: false, currentUserCanWrite: true,
            currentUserCanExecute: false, isDirectory: false)
        #expect(!fact.contentReadableByAI)
        #expect(fact.omissions.contains { $0.policy == "no_read_permission" })

        // prompt 投影仍带权限 / 路径哈希 / 类型(低敏事实可用于 AI 判断)。
        let p = fact.promptProjection()
        #expect(p.currentUserCanRead == false)
        #expect(p.posixMode == "rw-------")
        #expect(p.pathHash.hasPrefix("fp-"))
        #expect(p.absolutePath == nil)            // 默认不暴露完整路径(边界五)
    }

    /// 模型发明的 source ref 跨 pipeline 被丢弃(AIContextPipeline × validator),空 ref 默认拒绝。
    @Test func inventedRefDroppedThroughPipeline() throws {
        struct Facts: Codable, Equatable, Sendable { let n: Int }
        let real = AIContextSourceRef(kind: .archive, id: "arch-1")
        let invented = AIContextSourceRef(kind: .archive, id: "ghost")
        let req = try AIContextPipeline.makeRequest(
            purpose: .aiWorkspaceTree, privacyLevel: .localUserMetadata,
            facts: Facts(n: 1), sourceRefs: [real])
        struct Node { let refs: [AIContextSourceRef] }
        let kept = req.keepingValid([Node(refs: [real]), Node(refs: [invented]), Node(refs: [])]) { $0.refs }
        #expect(kept.count == 1)                  // invented 丢、空 ref 默认丢,只剩 real
    }
}
