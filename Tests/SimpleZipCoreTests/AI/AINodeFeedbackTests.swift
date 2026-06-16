//
//  AINodeFeedbackTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:AI 文件夹节点级反馈(我很喜欢 / 我不喜欢)+ 工作区可编辑描述。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AINodeFeedbackTests {
    private let ws = UUID()
    private let other = UUID()
    private func ref(_ id: String) -> AIContextSourceRef { AIContextSourceRef(kind: .file, id: id) }

    @Test func likeAndDislikeAreMutuallyExclusive() {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.liking(ws, [ref("a")])
        #expect(ledger.isLiked(ws, ref("a")))
        #expect(!ledger.isDisliked(ws, ref("a")))
        // 改标不喜欢 → 自动从 liked 移除。
        ledger = ledger.disliking(ws, [ref("a")])
        #expect(ledger.isDisliked(ws, ref("a")))
        #expect(!ledger.isLiked(ws, ref("a")))
    }

    @Test func dislikedRefsScopedPerWorkspace() {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.disliking(ws, [ref("a"), ref("b")])
        #expect(ledger.dislikedRefs(ws) == Set([ref("a"), ref("b")]))
        #expect(ledger.dislikedRefs(other).isEmpty)   // 不串工作区
    }

    @Test func nodeIsLikedChecksAnyRef() {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.liking(ws, [ref("a")])
        #expect(ledger.nodeIsLiked(ws, refs: [ref("a"), ref("z")]))
        #expect(!ledger.nodeIsLiked(ws, refs: [ref("z")]))
    }

    @Test func clearingRemovesBothSides() {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.liking(ws, [ref("a")]).disliking(ws, [ref("b")])
        ledger = ledger.clearing(ws, [ref("a"), ref("b")])
        #expect(!ledger.isLiked(ws, ref("a")))
        #expect(!ledger.isDisliked(ws, ref("b")))
    }

    @Test func clearingWorkspaceWipesAll() {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.liking(ws, [ref("a")]).disliking(ws, [ref("b")])
        ledger = ledger.clearingWorkspace(ws)
        #expect(ledger.dislikedRefs(ws).isEmpty)
        #expect(!ledger.isLiked(ws, ref("a")))
    }

    @Test func ledgerCodableRoundTrips() throws {
        var ledger = AINodeFeedbackLedger()
        ledger = ledger.liking(ws, [ref("a")]).disliking(ws, [ref("b")])
        let data = try JSONEncoder().encode(ledger)
        let back = try JSONDecoder().decode(AINodeFeedbackLedger.self, from: data)
        #expect(back == ledger)
    }

    @Test func workspaceDescriptionRoundTripsAndTrims() {
        let plan = AIWorkspaceQueryPlan(taskTags: [])
        let ws = AIWorkspace(id: UUID(), origin: .recommended, title: "T",
                             userDescription: "hello", queryPlan: plan, iconSystemName: "sparkles",
                             generatedAt: Date(timeIntervalSince1970: 1))
        var collection = AIWorkspaceCollection([ws])
        collection = collection.settingDescription(ws.id, "  trimmed  ")
        #expect(collection.workspace(ws.id)?.userDescription == "trimmed")
        // 空白 → 清回 nil。
        collection = collection.settingDescription(ws.id, "   ")
        #expect(collection.workspace(ws.id)?.userDescription == nil)
    }
}
