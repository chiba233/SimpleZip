//
//  AISelectionQueryTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 自然语言选择器(白皮书 Feat 14)。受控标签过滤、空 query 选零项、AND 组合、确定性执行。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISelectionQueryTests {
    @Test func normalizedKeepsOnlyControlledTags() {
        let q = AISelectionQuery(semanticTags: ["release-artifact", "not-a-real-tag", "test-fixture"])
        let n = q.normalized()
        #expect(n.semanticTags == ["release-artifact", "test-fixture"])
    }

    @Test func normalizedLowercasesAndDedupesExtensions() {
        let q = AISelectionQuery(extensions: ["ZIP", "7z", "ZIP", "Dmg"])
        #expect(q.normalized().extensions == ["zip", "7z", "dmg"])
    }

    @Test func emptyQuerySelectsNothing() {
        let q = AISelectionQuery()
        #expect(q.isEmpty)
        let candidates = [AISelectionCandidate(id: "a", fileExtension: "zip")]
        #expect(AISelectionQueryExecutor.select(candidates, with: q).isEmpty)
    }

    @Test func matchesByTag() {
        let q = AISelectionQuery(semanticTags: ["release-artifact"])
        let hit = AISelectionCandidate(id: "a", semanticTags: ["release-artifact", "signed-container"])
        let miss = AISelectionCandidate(id: "b", semanticTags: ["source-archive"])
        #expect(AISelectionQueryExecutor.matches(hit, q))
        #expect(!AISelectionQueryExecutor.matches(miss, q))
    }

    @Test func matchesByExtensionCaseInsensitive() {
        let q = AISelectionQuery(extensions: ["dmg", "zip"])
        let hit = AISelectionCandidate(id: "a", fileExtension: "DMG")
        let miss = AISelectionCandidate(id: "b", fileExtension: "7z")
        #expect(AISelectionQueryExecutor.matches(hit, q.normalized()))
        #expect(!AISelectionQueryExecutor.matches(miss, q.normalized()))
    }

    @Test func matchesByTaskState() {
        let q = AISelectionQuery(taskState: .noSuccessfulTest)
        let hit = AISelectionCandidate(id: "a", taskState: .noSuccessfulTest)
        let miss = AISelectionCandidate(id: "b", taskState: .testedOk)
        #expect(AISelectionQueryExecutor.matches(hit, q))
        #expect(!AISelectionQueryExecutor.matches(miss, q))
    }

    @Test func keywordSubstringMatch() {
        let q = AISelectionQuery(keywords: ["release"])
        let hit = AISelectionCandidate(id: "a", nameTokens: ["SimpleZip", "0.4.5", "release"])
        let miss = AISelectionCandidate(id: "b", nameTokens: ["notes", "draft"])
        #expect(AISelectionQueryExecutor.matches(hit, q))
        #expect(!AISelectionQueryExecutor.matches(miss, q))
    }

    @Test func andCombinationRequiresAllNonEmptyDimensions() {
        // 「像发布产物但还没测试过的包」:tag + taskState + extension 全部要满足。
        let q = AISelectionQuery(semanticTags: ["release-artifact"], extensions: ["zip", "dmg"],
                                 taskState: .noSuccessfulTest)
        let full = AISelectionCandidate(id: "a", fileExtension: "zip",
                                        semanticTags: ["release-artifact"], taskState: .noSuccessfulTest)
        let testedAlready = AISelectionCandidate(id: "b", fileExtension: "zip",
                                                 semanticTags: ["release-artifact"], taskState: .testedOk)
        let wrongExt = AISelectionCandidate(id: "c", fileExtension: "7z",
                                            semanticTags: ["release-artifact"], taskState: .noSuccessfulTest)
        #expect(AISelectionQueryExecutor.matches(full, q))
        #expect(!AISelectionQueryExecutor.matches(testedAlready, q))
        #expect(!AISelectionQueryExecutor.matches(wrongExt, q))
    }

    @Test func selectPreservesInputOrder() {
        let q = AISelectionQuery(extensions: ["zip"])
        let candidates = [
            AISelectionCandidate(id: "1", fileExtension: "zip"),
            AISelectionCandidate(id: "2", fileExtension: "7z"),
            AISelectionCandidate(id: "3", fileExtension: "zip"),
        ]
        #expect(AISelectionQueryExecutor.select(candidates, with: q).map(\.id) == ["1", "3"])
    }

    @Test func codableRoundTrip() throws {
        let q = AISelectionQuery(semanticTags: ["release-artifact"], extensions: ["zip"],
                                 keywords: ["build"], taskState: .testFailed,
                                 actionAfterSelection: .openVirtualFolder)
        let decoded = try JSONDecoder().decode(AISelectionQuery.self, from: JSONEncoder().encode(q))
        #expect(decoded == q)
    }
}
