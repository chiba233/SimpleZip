//
//  AISuggestionBusTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:全局 AI Suggestion Bus 契约 + 渲染前安全闸(工程补充十)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISuggestionBusTests {
    private func card(_ id: String, priority: Int, safety: AISuggestionSafety = .safe) -> AISuggestionCard {
        AISuggestionCard(id: id, surfaceID: .mainToolbar, title: id, body: "", priority: priority, safety: safety)
    }

    @Test func everySurfaceHasStableToken() {
        for s in AISuggestionSurfaceID.allCases { #expect(!s.rawValue.isEmpty) }
    }

    @Test func sanitizeSortsByPriorityThenID() {
        let cards = AISuggestionBus.sanitize([
            card("b", priority: 1), card("a", priority: 5), card("c", priority: 5)
        ])
        #expect(cards.map(\.id) == ["a", "c", "b"])
    }

    @Test func sanitizeDropsUnsafeCards() {
        let cards = AISuggestionBus.sanitize([
            card("danger", priority: 9, safety: AISuggestionSafety(destructive: true)),
            card("ok", priority: 1)
        ])
        #expect(cards.map(\.id) == ["ok"])
    }

    @Test func sanitizeDedupesByID() {
        let cards = AISuggestionBus.sanitize([
            card("dup", priority: 3), card("dup", priority: 9)
        ])
        #expect(cards.count == 1)
        #expect(cards.first?.priority == 3)  // 保留首个
    }

    @Test func requestRoundTripsThroughCodable() throws {
        let req = AISuggestionRequest(
            surfaceID: .archiveSelection, purpose: .actionRecommendation, currentMode: "archive",
            sourceRefs: [AIContextSourceRef(kind: .archive, id: "arch-1")],
            visibleFacts: ["extension": "zip"],
            candidateActions: [.openArchive(path: "/x/a.zip", revealEntry: nil)],
            budget: .activityWorkbench)
        let data = try JSONEncoder().encode(req)
        #expect(try JSONDecoder().decode(AISuggestionRequest.self, from: data) == req)
    }

    @Test func cardRoundTripsThroughCodable() throws {
        let c = AISuggestionCard(
            id: "card-1", surfaceID: .reportView, title: "t", body: "b", priority: 2,
            action: .openReport(taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            evidence: [AIEvidenceCard(title: "why", reason: "because")],
            dismissBehavior: .notInterested)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(AISuggestionCard.self, from: data) == c)
    }

    @Test func budgetIsNowCodable() throws {
        let data = try JSONEncoder().encode(AIBudget.archiveMemory)
        #expect(try JSONDecoder().decode(AIBudget.self, from: data) == AIBudget.archiveMemory)
    }
}
