//
//  AIInteractionSignalTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:逐 surface 轻量交互信号 + 聚合计数 + interaction 亲和度(白皮书工程补充八扩写)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIInteractionSignalTests {
    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)

    private func signal(_ surface: AIInteractionSignalEvent.Surface,
                        _ interaction: AIInteractionSignalEvent.Interaction,
                        at: Date, targetKind: AIUserInterestEvent.TargetKind = .task,
                        roleTags: [String] = [], evidence: [String] = []) -> AIInteractionSignalEvent {
        AIInteractionSignalEvent(id: AIStableHash.deterministicUUID("\(surface)\(interaction)\(at)"),
                                 occurredAt: at, surface: surface, interaction: interaction,
                                 targetKind: targetKind, roleTags: roleTags, evidenceTokens: evidence)
    }

    // MARK: - 事件

    @Test func makeRedactsEvidenceTokens() {
        let e = AIInteractionSignalEvent.make(
            id: AIStableHash.deterministicUUID("e"), occurredAt: t1,
            surface: .searchBar, interaction: .searched, targetKind: .file,
            evidenceTokens: ["status=failed", "password=hunter2"])
        #expect(e.evidenceTokens.contains("status=failed"))
        #expect(!e.evidenceTokens.contains { $0.contains("hunter2") })   // 口令被脱敏
    }

    @Test func interactionPolarityClassifies() {
        #expect(AIInteractionSignalEvent.Interaction.clicked.outcomePolarity == .positive)
        #expect(AIInteractionSignalEvent.Interaction.acceptedSuggestion.outcomePolarity == .positive)
        #expect(AIInteractionSignalEvent.Interaction.dismissed.outcomePolarity == .negative)
        #expect(AIInteractionSignalEvent.Interaction.notInterested.outcomePolarity == .negative)
        #expect(AIInteractionSignalEvent.Interaction.revertedPatch.outcomePolarity == .negative)
        // shown/expanded/changedOption 是中性,不是反馈。
        #expect(AIInteractionSignalEvent.Interaction.shown.outcomePolarity == .neutral)
        #expect(AIInteractionSignalEvent.Interaction.expanded.outcomePolarity == .neutral)
        #expect(AIInteractionSignalEvent.Interaction.changedOption.outcomePolarity == .neutral)
        // 强度:shown < expanded < clicked < doubleClicked。
        #expect(AIInteractionSignalEvent.Interaction.shown.interestWeight
                < AIInteractionSignalEvent.Interaction.expanded.interestWeight)
        #expect(AIInteractionSignalEvent.Interaction.expanded.interestWeight
                < AIInteractionSignalEvent.Interaction.clicked.interestWeight)
    }

    @Test func signalCodableRoundTrips() throws {
        let e = signal(.activityTaskRow, .expanded, at: t1, roleTags: ["release-package"],
                       evidence: ["tag=checksum-mismatch"])
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(AIInteractionSignalEvent.self, from: data) == e)
    }

    // MARK: - 聚合

    @Test func counterSummaryGroupsCountsAndPolarity() {
        let events = [
            signal(.activityTaskRow, .expanded, at: t1, roleTags: ["release-package"], evidence: ["tag=checksum-mismatch"]),
            signal(.activityTaskRow, .expanded, at: t2, roleTags: ["release-package"], evidence: ["tag=checksum-mismatch"]),
            signal(.activityAIWorkbench, .dismissed, at: t1),
        ]
        let summary = AIInteractionSignalAggregator.counterSummary(from: events, window: "30d", generatedAt: t2)
        #expect(summary.schema == "simplezip.ai.interactionCounterSummary.v1")
        #expect(summary.window == "30d")

        let expanded = summary.counters.first { $0.surface == "activityTaskRow" && $0.interaction == "expanded" }
        #expect(expanded?.count == 2)
        #expect(expanded?.lastAt == t2)                       // 取最新
        #expect(expanded?.diagnosticTag == "checksum-mismatch")
        #expect(expanded?.roleTag == "release-package")
        #expect(expanded?.targetToken == nil)                 // 聚合不带具体对象

        let dismissed = summary.counters.first { $0.interaction == "dismissed" }
        #expect(dismissed?.negativeOutcomeCount == 1)
        #expect(dismissed?.roleTag == nil)
    }

    @Test func counterSummaryDeterministicOrder() {
        let events = [
            signal(.sidebar, .clicked, at: t1),
            signal(.sidebar, .clicked, at: t1),                // 同组 → count 2
            signal(.activityTaskRow, .shown, at: t1),
        ]
        let a = AIInteractionSignalAggregator.counterSummary(from: events, window: "7d", generatedAt: t2)
        let b = AIInteractionSignalAggregator.counterSummary(from: events.reversed(), window: "7d", generatedAt: t2)
        #expect(a == b)                                        // 与输入顺序无关
        #expect(a.counters.first?.count == 2)                  // 次数降序
    }

    @Test func affinitiesFeedInterestSummary() {
        let signals = [
            signal(.activityTaskRow, .expanded, at: t1, roleTags: ["release-package"], evidence: ["tag=checksum-mismatch"]),
            signal(.activityTaskRow, .expanded, at: t2, roleTags: ["release-package"], evidence: ["tag=checksum-mismatch"]),
        ]
        let summary = AIInterestAggregator.summarize([], signals: signals)
        #expect(summary.interactionAffinities.count == 1)
        #expect(summary.interactionAffinities.first?.count == 2)
        #expect(summary.interactionAffinities.first?.diagnosticTag == "checksum-mismatch")
        #expect(!summary.isEmpty)                              // interactionAffinities 计入 isEmpty
    }

    @Test func interestSummaryBackwardCompatibleDefault() {
        // 旧 2 参构造仍可用,interactionAffinities 默认空。
        let s = AIInterestSummary(reactionPreferences: [], locationAffinities: [])
        #expect(s.interactionAffinities.isEmpty)
        #expect(s.isEmpty)
    }
}
