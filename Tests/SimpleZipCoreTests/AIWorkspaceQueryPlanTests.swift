//
//  AIWorkspaceQueryPlanTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:工作区 query plan + 确定性执行器(Feat 6)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceQueryPlanTests {
    private func memoryRecord(path: String, name: String, entries: [String],
                              recordedAt: TimeInterval = 1_750_000_000) -> ArchiveMemoryRecord {
        let cached = entries.map { ArchiveListingCacheEntry.CachedEntry(name: $0, isDirectory: false, size: 1) }
        let entry = ArchiveListingCacheEntry(
            archivePath: path, archiveName: name, recordedAt: Date(timeIntervalSince1970: recordedAt),
            archiveByteSize: 1, archiveModified: nil, totalEntryCount: cached.count,
            encryptedEntryCount: 0, truncated: false, entries: cached)
        return ArchiveMemoryIndex.derive(from: entry, home: "/Users/tester")
    }

    private func taskRecord(id: String, title: String, failure: String?) -> AITaskRecord {
        AITaskRecord.make(id: id, category: "archive", kind: "test", source: "cli",
                          status: failure == nil ? "succeeded" : "failed", title: title,
                          startedAt: nil, finishedAt: nil, failureMessage: failure, rawOutput: failure)
    }

    @Test func matchesArchivesBySemanticTag() {
        let release = memoryRecord(path: "/Users/tester/Downloads/rel.zip", name: "rel.zip",
                                   entries: ["SHA256SUMS", "App.dmg"])
        let source = memoryRecord(path: "/Users/tester/Projects/src.zip", name: "src.zip",
                                  entries: ["Package.swift", "a.swift", "b.swift", "c.swift", "d.swift", "e.swift"])
        let plan = AIWorkspaceQueryPlan(semanticTags: ["release-artifact"])
        let matched = AIWorkspaceQueryExecutor.matchArchives(plan, in: [release, source])
        #expect(matched.map(\.archiveName) == ["rel.zip"])
    }

    @Test func matchesArchivesByMarkerOrKeyword() {
        let source = memoryRecord(path: "/x/src.zip", name: "src.zip",
                                  entries: ["Package.swift", "a.swift"])
        #expect(AIWorkspaceQueryExecutor.matchArchives(AIWorkspaceQueryPlan(markerFiles: ["Package.swift"]),
                                                       in: [source]).count == 1)
        #expect(AIWorkspaceQueryExecutor.matchArchives(AIWorkspaceQueryPlan(keywords: ["src"]),
                                                       in: [source]).count == 1)
    }

    @Test func ordersByMatchCountThenRecency() {
        // 一个命中 2 信号、一个命中 1 信号 → 2 信号的靠前。
        let strong = memoryRecord(path: "/Users/tester/Downloads/rel.zip", name: "rel.zip",
                                  entries: ["SHA256SUMS", "App.dmg"], recordedAt: 1)
        let weak = memoryRecord(path: "/Users/tester/Downloads/other.zip", name: "other.zip",
                                entries: ["SHA256SUMS"], recordedAt: 2)
        let plan = AIWorkspaceQueryPlan(semanticTags: ["release-artifact"], markerFiles: ["App.dmg"])
        let matched = AIWorkspaceQueryExecutor.matchArchives(plan, in: [weak, strong])
        #expect(matched.first?.archiveName == "rel.zip")
    }

    @Test func matchesTasksByDiagnosticTag() {
        let failed = taskRecord(id: "t1", title: "Test rel.7z", failure: "ERROR: CRC Failed")
        let ok = taskRecord(id: "t2", title: "Test ok.7z", failure: nil)
        let plan = AIWorkspaceQueryPlan(taskTags: ["checksum-mismatch"])
        #expect(AIWorkspaceQueryExecutor.matchTasks(plan, in: [failed, ok]).map(\.id) == ["t1"])
    }

    @Test func emptyPlanMatchesNothing() {
        let r = memoryRecord(path: "/x/a.zip", name: "a.zip", entries: ["Package.swift"])
        #expect(AIWorkspaceQueryExecutor.matchArchives(AIWorkspaceQueryPlan(), in: [r]).isEmpty)
        #expect(AIWorkspaceQueryPlan().isEmpty)
    }

    @Test func includeTogglesGateResults() {
        let r = memoryRecord(path: "/x/a.zip", name: "a.zip", entries: ["Package.swift"])
        let plan = AIWorkspaceQueryPlan(markerFiles: ["Package.swift"], includeArchives: false)
        #expect(AIWorkspaceQueryExecutor.matchArchives(plan, in: [r]).isEmpty)
    }

    @Test func executorIsDeterministic() {
        let a = memoryRecord(path: "/x/a.zip", name: "a.zip", entries: ["SHA256SUMS"])
        let b = memoryRecord(path: "/x/b.zip", name: "b.zip", entries: ["SHA256SUMS", "App.dmg"])
        let plan = AIWorkspaceQueryPlan(semanticTags: ["release-artifact"], markerFiles: ["App.dmg"])
        #expect(AIWorkspaceQueryExecutor.matchArchives(plan, in: [a, b])
                == AIWorkspaceQueryExecutor.matchArchives(plan, in: [a, b]))
    }
}
