//
//  AIWorkspaceModelTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 工作区 / 虚拟树值模型 + 安全清洗(建议四 / 补充十一)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceModelTests {
    private let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let validRef = AIContextSourceRef(kind: .archive, id: "arch-1")
    private let invalidRef = AIContextSourceRef(kind: .archive, id: "ghost")

    @Test func safetyV1Gate() {
        #expect(AISuggestionSafety.safe.isAllowedInV1)
        #expect(!AISuggestionSafety(destructive: true).isAllowedInV1)
        #expect(!AISuggestionSafety(touchesEncryptedContent: true).isAllowedInV1)
    }

    @Test func actionsAreAllDirectlySafe() {
        let actions: [AISuggestionAction] = [
            .openTask(id1), .openFolder(path: "/x"), .revealFile(path: "/x/a"),
            .openArchive(path: "/x/a.zip", revealEntry: "README.md"),
            .applyArchiveSearch(archiveID: "arch-1", query: "readme"),
            .openReport(taskID: id1), .explainFailure(taskID: id1), .openActivityCenter,
            .pinRecommendedWorkspace(id1), .dismissRecommendedWorkspace(id1)
        ]
        let allSafe = actions.allSatisfy { $0.isDirectlySafe }
        #expect(allSafe)
    }

    @Test func nodeCodableRoundTripWithAction() throws {
        let node = AIVirtualNode(id: id1, kind: .archive, title: "a", sourceRefs: [validRef],
                                 primaryAction: .openArchive(path: "/x/a.zip", revealEntry: "README.md"))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(AIVirtualNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func sanitizerDropsInventedRefsAndDestructiveNodes() {
        let nodes = [
            AIVirtualNode(id: id1, kind: .archive, title: "ok", sourceRefs: [validRef]),
            AIVirtualNode(id: id2, kind: .archive, title: "invented", sourceRefs: [invalidRef]),
            AIVirtualNode(id: id3, kind: .archive, title: "danger", sourceRefs: [validRef],
                          safety: AISuggestionSafety(destructive: true))
        ]
        let clean = AIVirtualTreeSanitizer.sanitize(nodes, allowed: [validRef])
        #expect(clean.map(\.title) == ["ok"])
    }

    @Test func sanitizerCleansNestedGroupChildren() {
        let group = AIVirtualNode(id: id1, kind: .group, title: "Group", children: [
            AIVirtualNode(id: id2, kind: .archive, title: "child-ok", sourceRefs: [validRef]),
            AIVirtualNode(id: id3, kind: .archive, title: "child-bad", sourceRefs: [invalidRef])
        ])
        let clean = AIVirtualTreeSanitizer.sanitize([group], allowed: [validRef])
        #expect(clean.count == 1)
        #expect(clean.first?.children.map(\.title) == ["child-ok"])
    }

    @Test func sanitizerDropsEmptiedGroups() {
        let emptyGroup = AIVirtualNode(id: id1, kind: .group, title: "Empty", children: [
            AIVirtualNode(id: id2, kind: .archive, title: "bad", sourceRefs: [invalidRef])
        ])
        #expect(AIVirtualTreeSanitizer.sanitize([emptyGroup], allowed: [validRef]).isEmpty)
    }

    @Test func workspaceCodableRoundTrip() throws {
        let ws = AIWorkspace(id: id1, origin: .system, title: "Needs Attention",
                             queryPlan: AIWorkspaceQueryPlan(taskTags: ["checksum-mismatch"]),
                             iconSystemName: "exclamationmark.triangle",
                             generatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(AIWorkspace.self, from: data)
        #expect(decoded == ws)
    }
}
