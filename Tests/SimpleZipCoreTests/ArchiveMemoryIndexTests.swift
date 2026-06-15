//
//  ArchiveMemoryIndexTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:归档记忆派生 —— 画像复用、位置上下文、样本、加密省略、稳定 id。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveMemoryIndexTests {
    private func cached(_ name: String, dir: Bool = false, size: Int64? = nil)
        -> ArchiveListingCacheEntry.CachedEntry {
        ArchiveListingCacheEntry.CachedEntry(name: name, isDirectory: dir, size: size)
    }

    private func entry(path: String, name: String, encrypted: Int = 0, truncated: Bool = false,
                       entries: [ArchiveListingCacheEntry.CachedEntry]) -> ArchiveListingCacheEntry {
        ArchiveListingCacheEntry(
            archivePath: path, archiveName: name, recordedAt: Date(timeIntervalSince1970: 1_750_000_000),
            archiveByteSize: 4096, archiveModified: nil,
            totalEntryCount: entries.count + encrypted, encryptedEntryCount: encrypted,
            truncated: truncated, entries: entries)
    }

    @Test func derivesProfileAndLocationFromCache() {
        let e = entry(path: "/Users/tester/Downloads/Source.zip", name: "Source.zip", entries: [
            cached("App/Package.swift", size: 100),
            cached("App/a.swift", size: 2000),
            cached("App/b.swift", size: 50),
            cached("App/README.md", size: 300)
        ])
        let record = ArchiveMemoryIndex.derive(from: e, home: "/Users/tester")
        #expect(record.archiveName == "Source.zip")
        #expect(record.archiveExtension == "zip")
        #expect(record.location.kind == .downloads)
        #expect(record.profile.semanticTags.contains("swift-project"))
        #expect(record.largestFiles.first?.name == "a.swift") // size 降序
        #expect(record.samplePaths.contains("App/Package.swift"))
        #expect(record.archiveID.hasPrefix("arch-"))
    }

    @Test func recordCarriesEncryptedOmissionCount() {
        let e = entry(path: "/x/mixed.7z", name: "mixed.7z", encrypted: 5, entries: [cached("readme.md")])
        let record = ArchiveMemoryIndex.derive(from: e)
        #expect(record.entryStats.encryptedEntriesOmitted == 5)
        #expect(record.entryStats.visibleEntries == 1)
        #expect(record.entryStats.totalEntries == 6)
        #expect(record.omissions.contains { $0.type == "encrypted_entry_names" && $0.count == 5 })
    }

    @Test func recordNeverExposesFullArchivePath() {
        // AI 面向记录不含完整磁盘路径,只用 hash + name + 位置 token。
        let e = entry(path: "/Users/secretuser/private/Vault.zip", name: "Vault.zip",
                      entries: [cached("note.txt")])
        let record = ArchiveMemoryIndex.derive(from: e, home: "/Users/secretuser")
        let json = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
        #expect(!json.contains("/Users/secretuser/private"))
        #expect(!json.contains("secretuser"))
    }

    @Test func archiveIDIsStableAndDistinct() {
        #expect(ArchiveMemoryIndex.archiveID(forPath: "/a/b.zip") == ArchiveMemoryIndex.archiveID(forPath: "/a/b.zip"))
        #expect(ArchiveMemoryIndex.archiveID(forPath: "/a/b.zip") != ArchiveMemoryIndex.archiveID(forPath: "/a/c.zip"))
    }

    @Test func truncatedFlagBecomesOmission() {
        let e = entry(path: "/x/big.zip", name: "big.zip", truncated: true, entries: [cached("a.txt")])
        let record = ArchiveMemoryIndex.derive(from: e)
        #expect(record.entryStats.truncated)
        #expect(record.omissions.contains { $0.type == "archive_entries" })
    }
}
