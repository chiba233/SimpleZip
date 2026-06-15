//
//  AIWorkspaceCandidateTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:工作区候选池 —— 主题/节点候选 + 确定性排序 + 落成虚拟节点(工程补充七)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceCandidateTests {
    @Test func deterministicUUIDIsStableAndDistinct() {
        #expect(AIStableHash.deterministicUUID("a") == AIStableHash.deterministicUUID("a"))
        #expect(AIStableHash.deterministicUUID("a") != AIStableHash.deterministicUUID("b"))
    }

    @Test func rankThemesPrefersMoreSignals() {
        let weak = AIWorkspaceThemeCandidate(id: "z-weak", titleSeed: "x", scoreSignals: ["a"])
        let strong = AIWorkspaceThemeCandidate(id: "a-strong", titleSeed: "y", scoreSignals: ["a", "b", "c"])
        let ranked = AIWorkspaceCandidateRanker.rankThemes([weak, strong])
        #expect(ranked.map(\.id) == ["a-strong", "z-weak"])
    }

    @Test func rankThemesTieBreaksById() {
        let b = AIWorkspaceThemeCandidate(id: "b", titleSeed: "x", scoreSignals: ["a"])
        let a = AIWorkspaceThemeCandidate(id: "a", titleSeed: "y", scoreSignals: ["a"])
        #expect(AIWorkspaceCandidateRanker.rankThemes([b, a]).map(\.id) == ["a", "b"])
    }

    @Test func nodeCandidateBecomesVirtualNode() {
        let ref = AIContextSourceRef(kind: .archive, id: "arch-1")
        let candidate = AIVirtualNodeCandidate(
            id: "cand-1", kind: .archive, displayName: "release.7z",
            sourceRefs: [ref], scoreSignals: ["archiveRole=release-package", "marker=SHA256SUMS"])
        let node = candidate.toNode()
        #expect(node.kind == .archive)
        #expect(node.title == "release.7z")
        #expect(node.sourceRefs == [ref])
        #expect(node.reason == "archiveRole=release-package, marker=SHA256SUMS")
        // 确定性 UUID:同候选两次落成相同 id。
        #expect(candidate.toNode().id == node.id)
    }

    @Test func nodeCandidatesSurviveSanitizerWithValidRefs() {
        let ref = AIContextSourceRef(kind: .archive, id: "arch-ok")
        let bad = AIContextSourceRef(kind: .archive, id: "ghost")
        let good = AIVirtualNodeCandidate(id: "g", kind: .archive, displayName: "ok", sourceRefs: [ref]).toNode()
        let invented = AIVirtualNodeCandidate(id: "b", kind: .archive, displayName: "ghost", sourceRefs: [bad]).toNode()
        let clean = AIVirtualTreeSanitizer.sanitize([good, invented], allowed: [ref])
        #expect(clean.map(\.title) == ["ok"])
    }

    @Test func rankNodesIsDeterministic() {
        let nodes = [
            AIVirtualNodeCandidate(id: "b", kind: .file, displayName: "B", scoreSignals: ["a"]),
            AIVirtualNodeCandidate(id: "a", kind: .file, displayName: "A", scoreSignals: ["a", "b"])
        ]
        #expect(AIWorkspaceCandidateRanker.rankNodes(nodes) == AIWorkspaceCandidateRanker.rankNodes(nodes))
        #expect(AIWorkspaceCandidateRanker.rankNodes(nodes).first?.id == "a")
    }

    @Test func candidatesRoundTripThroughCodable() throws {
        let theme = AIWorkspaceThemeCandidate(id: "t", titleSeed: "release verification",
                                              themeTokens: ["release"], scoreSignals: ["folderRole=release"])
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(AIWorkspaceThemeCandidate.self, from: data) == theme)
    }
}
