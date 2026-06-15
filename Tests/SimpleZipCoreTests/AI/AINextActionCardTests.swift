//
//  AINextActionCardTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:下一步动作卡确定性排序(白皮书 Feat 3)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AINextActionCardTests {
    private func candidate(_ id: String, safety: AISuggestionSafety = .safe) -> AIActionCandidate {
        AIActionCandidate(id: id, safety: safety)
    }

    @Test func preservesProviderOrderWithoutUsage() {
        let cards = AINextActionRanker.rank(candidates: [
            candidate("inspectRelease"), candidate("convertArchive"), candidate("testArchive")
        ])
        #expect(cards.map(\.actionID) == ["inspectRelease", "convertArchive", "testArchive"])
    }

    @Test func usageCompletionLiftsAction() {
        // convertArchive 在 provider 顺序里第二,但有很多完成记录 → 应升到第一。
        let cards = AINextActionRanker.rank(
            candidates: [candidate("inspectRelease"), candidate("convertArchive")],
            usage: [AIActionUsageSignal(actionID: "convertArchive", completed: 5)])
        #expect(cards.first?.actionID == "convertArchive")
    }

    @Test func dismissalsDemoteAction() {
        let cards = AINextActionRanker.rank(
            candidates: [candidate("convertArchive"), candidate("inspectRelease")],
            usage: [AIActionUsageSignal(actionID: "convertArchive", dismissed: 6)])
        #expect(cards.first?.actionID == "inspectRelease")
    }

    @Test func dropsUnsafeCandidates() {
        let cards = AINextActionRanker.rank(candidates: [
            candidate("deleteEverything", safety: AISuggestionSafety(destructive: true)),
            candidate("inspectRelease")
        ])
        #expect(cards.map(\.actionID) == ["inspectRelease"])
    }

    @Test func limitTruncatesResults() {
        let cards = AINextActionRanker.rank(
            candidates: [candidate("a"), candidate("b"), candidate("c"), candidate("d")],
            limit: 2)
        #expect(cards.count == 2)
    }

    @Test func confirmationActionsCarryRisk() {
        let cards = AINextActionRanker.rank(candidates: [
            candidate("retest", safety: AISuggestionSafety(requiresConfirmation: true))
        ])
        #expect(cards.first?.risk == "requires-confirmation")
        #expect(cards.first?.requiresConfirmation == true)
    }

    @Test func rankingIsDeterministic() {
        let cands = [candidate("b"), candidate("a")]
        let usage = [AIActionUsageSignal(actionID: "a", clicked: 1)]
        #expect(AINextActionRanker.rank(candidates: cands, usage: usage)
                == AINextActionRanker.rank(candidates: cands, usage: usage))
    }

    @Test func cardRoundTripsThroughCodable() throws {
        let card = AINextActionRanker.rank(candidates: [candidate("inspectRelease")]).first
        let data = try JSONEncoder().encode(card)
        #expect(try JSONDecoder().decode(AINextActionCard?.self, from: data) == card)
    }
}
