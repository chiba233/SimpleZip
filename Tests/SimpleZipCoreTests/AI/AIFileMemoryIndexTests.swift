//
//  AIFileMemoryIndexTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:白名单目录持久文件预索引容器(工程补充五 / 六)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFileMemoryIndexTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let scopeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let scopeB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func rec(_ name: String, at loc: AILocationKind = .downloads) -> AIFileMemoryRecord {
        AIFileMemoryRecord.make(fileName: name, isDirectory: false, byteSize: 100, modifiedAt: now,
                                location: AILocationContext(kind: loc, pathHash: "loc-" + loc.rawValue,
                                                            folderNameTokens: []))
    }

    @Test func upsertDedupsByRecordID() {
        let index = AIFileMemoryIndex()
            .upserting([rec("a.txt"), rec("b.txt")], scopeID: scopeA, at: now)
            .upserting([rec("a.txt")], scopeID: scopeA, at: now.addingTimeInterval(10))  // 同 id 覆盖
        #expect(index.fileCount == 2)
    }

    @Test func capDropsOldest() {
        var index = AIFileMemoryIndex(maxFiles: 2)
        index = index.upserting([rec("old1.txt")], scopeID: scopeA, at: now)
        index = index.upserting([rec("old2.txt")], scopeID: scopeA, at: now.addingTimeInterval(10))
        index = index.upserting([rec("new.txt")], scopeID: scopeA, at: now.addingTimeInterval(20))
        #expect(index.fileCount == 2)
        // 最旧的 old1 被淘汰。
        #expect(!index.records.contains { $0.fileName == "old1.txt" })
        #expect(index.records.contains { $0.fileName == "new.txt" })
    }

    @Test func clearingScopeRemovesOnlyThatScope() {
        let index = AIFileMemoryIndex()
            .upserting([rec("a.txt")], scopeID: scopeA, at: now)
            .upserting([rec("b.txt", at: .desktop)], scopeID: scopeB, at: now)
            .clearingScope(scopeA)
        #expect(index.fileCount == 1)
        #expect(index.records.first?.fileName == "b.txt")
    }

    @Test func clearedEmptiesAll() {
        let index = AIFileMemoryIndex()
            .upserting([rec("a.txt"), rec("b.txt")], scopeID: scopeA, at: now)
            .cleared()
        #expect(index.isEmpty)
    }

    @Test func recentRecordsRespectsLimit() {
        var index = AIFileMemoryIndex()
        for i in 0..<5 { index = index.upserting([rec("f\(i).txt")], scopeID: scopeA, at: now.addingTimeInterval(Double(i))) }
        #expect(index.recentRecords(limit: 3).count == 3)
    }

    @Test func codableRoundTrips() throws {
        let index = AIFileMemoryIndex().upserting([rec("a.txt")], scopeID: scopeA, at: now)
        let data = try JSONEncoder().encode(index)
        let back = try JSONDecoder().decode(AIFileMemoryIndex.self, from: data)
        #expect(back == index)
    }
}
