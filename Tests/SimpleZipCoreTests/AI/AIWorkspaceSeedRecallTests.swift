//
//  AIWorkspaceSeedRecallTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:从用户种子召回工作区成员(闭环:喜欢→pin、不喜欢→exclude、描述→themePrompts 都改变召回)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceSeedRecallTests {
    private let ws = UUID()
    private let now = Date(timeIntervalSince1970: 1)
    private func ref(_ id: String) -> AIContextSourceRef { AIContextSourceRef(kind: .file, id: id) }

    private func cand(_ id: String, name: String, tokens: [String] = []) -> AIVirtualNodeCandidate {
        AIVirtualNodeCandidate(id: id, kind: .file, displayName: name,
                               sourceRefs: [ref(id)], roleTags: [], semanticTokens: tokens)
    }

    private func seed(prompts: [String] = [], pinned: [String] = [], excluded: [String] = []) -> AIWorkspaceUserSeed {
        AIWorkspaceUserSeed(workspaceID: ws, themePrompts: prompts,
                            pinnedSourceRefs: pinned.map(ref), excludedSourceRefs: excluded.map(ref),
                            createdAt: now, updatedAt: now)
    }

    @Test func themePromptRecallsBySemanticToken() {
        let pool = [cand("a", name: "thesis-data.csv"), cand("b", name: "vacation.jpg"), cand("c", name: "thesis-fig.png")]
        // 描述「thesis」→ 召回名字含 thesis 的,不召回 vacation。
        let members = AIWorkspaceSeedRecall.members(in: pool, seed: seed(prompts: ["thesis charts"]))
        #expect(Set(members.map(\.id)) == ["a", "c"])
    }

    @Test func cjkPromptRecallsBySubstring() {
        let pool = [cand("p", name: "论文初稿.docx"), cand("q", name: "预算.xlsx")]
        let members = AIWorkspaceSeedRecall.members(in: pool, seed: seed(prompts: ["论文"]))
        #expect(members.map(\.id) == ["p"])
    }

    @Test func pinnedAlwaysIncludedExcludedAlwaysOut() {
        let pool = [cand("a", name: "random.bin"), cand("b", name: "thesis.txt"), cand("c", name: "thesis-old.txt")]
        // pin a(虽不匹配也进);exclude c(虽匹配 thesis 也出)。
        let members = AIWorkspaceSeedRecall.members(in: pool, seed: seed(prompts: ["thesis"], pinned: ["a"], excluded: ["c"]))
        #expect(Set(members.map(\.id)) == ["a", "b"])
    }

    @Test func noPromptNoPinReturnsEmpty() {
        let pool = [cand("a", name: "x.txt"), cand("b", name: "y.txt")]
        #expect(AIWorkspaceSeedRecall.members(in: pool, seed: seed()).isEmpty)
    }

    @Test func seedPinningAndExclusionAreMutuallyExclusive() {
        var s = seed()
        s = s.pinning([ref("a")], updatedAt: now)
        #expect(s.isPinned(ref("a")))
        s = s.excluding([ref("a")], updatedAt: now)
        #expect(s.isExcluded(ref("a")) && !s.isPinned(ref("a")))
        s = s.pinning([ref("a")], updatedAt: now)
        #expect(s.isPinned(ref("a")) && !s.isExcluded(ref("a")))
    }
}
