//
//  ArchiveListingCacheTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #34:归档清单缓存 —— 记录/搜索、隐私排除加密条目、去重、上限裁旧、TTL 过期、开关与清空。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite final class ArchiveListingCacheTests {
    private let suiteDefaults = SuiteDefaults()

    private func makeStore(enabled: Bool = true,
                           maxArchives: Int = 50,
                           ttlDays: Int = 30) -> ArchiveListingCacheStore {
        let defaults = suiteDefaults.make("ArchiveListingCacheTests")
        let policy = ArchiveListingCachePolicy(enabled: enabled, maxArchives: maxArchives, ttlDays: ttlDays)
        return ArchiveListingCacheStore(defaults: defaults, policyProvider: { policy })
    }

    private func item(_ name: String, isDirectory: Bool = false, encrypted: Bool = false) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: isDirectory, size: 10, modified: nil,
                    sizeText: "", modifiedText: "", method: "", isEncrypted: encrypted)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/SZListingCacheTest-\(UUID().uuidString)/\(name)")
    }

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func recordsAndSearchesEntryNames() {
        let store = makeStore()
        #expect(store.record(archiveURL: url("docs.zip"),
                             items: [item("readme.md"), item("src/Main.swift")], now: t0))
        #expect(store.count() == 1)

        let hits = store.search("main.swift", now: t0)
        #expect(hits.count == 1)
        #expect(hits.first?.entryName == "src/Main.swift")
        #expect(hits.first?.archiveName == "docs.zip")
    }

    @Test func excludesEncryptedEntries() {
        let store = makeStore()
        #expect(store.record(archiveURL: url("mixed.zip"),
                             items: [item("public.txt"), item("secret.txt", encrypted: true)], now: t0))
        // 加密条目名不入缓存,搜不到;计数单独记。
        #expect(store.search("public", now: t0).count == 1)
        #expect(store.search("secret", now: t0).isEmpty)
        let entry = store.loadAll().first
        #expect(entry?.totalEntryCount == 2)
        #expect(entry?.encryptedEntryCount == 1)
        #expect(entry?.entries.count == 1)
    }

    @Test func fullyEncryptedArchiveNotRecorded() {
        let store = makeStore()
        #expect(store.record(archiveURL: url("vault.7z"),
                             items: [item("a", encrypted: true), item("b", encrypted: true)], now: t0) == false)
        #expect(store.count() == 0)
    }

    @Test func emptyArchiveNotRecorded() {
        let store = makeStore()
        #expect(store.record(archiveURL: url("empty.zip"), items: [], now: t0) == false)
        #expect(store.count() == 0)
    }

    @Test func sameArchiveDedupesAndMovesToFront() {
        let store = makeStore()
        let target = url("repeat.zip")
        #expect(store.record(archiveURL: target, items: [item("first.txt")], now: t0))
        #expect(store.record(archiveURL: target, items: [item("second.txt")],
                             now: t0.addingTimeInterval(60)))
        // 同路径替换 → 仍只有一条,且是最新内容。
        #expect(store.count() == 1)
        #expect(store.search("first", now: t0).isEmpty)
        #expect(store.search("second", now: t0).count == 1)
    }

    @Test func capEvictsOldestArchives() {
        let store = makeStore(maxArchives: 2)
        store.record(archiveURL: url("a.zip"), items: [item("alpha.txt")], now: t0)
        store.record(archiveURL: url("b.zip"), items: [item("bravo.txt")], now: t0.addingTimeInterval(10))
        store.record(archiveURL: url("c.zip"), items: [item("charlie.txt")], now: t0.addingTimeInterval(20))
        // 上限 2 → 最旧的 a 被裁掉,b/c 保留。
        #expect(store.count() == 2)
        #expect(store.search("alpha", now: t0).isEmpty)
        #expect(store.search("bravo", now: t0).count == 1)
        #expect(store.search("charlie", now: t0).count == 1)
    }

    @Test func ttlExpiresOldEntries() {
        let store = makeStore(ttlDays: 1)
        store.record(archiveURL: url("stale.zip"), items: [item("old.txt")], now: t0)
        let later = t0.addingTimeInterval(2 * 86_400) // 2 天后 > 1 天 TTL
        // 搜索时过期项被跳过。
        #expect(store.search("old", now: later).isEmpty)
        // 落地清理后 count 归零。
        store.pruneExpiredInPlace(now: later)
        #expect(store.count() == 0)
    }

    @Test func ttlZeroNeverExpires() {
        let store = makeStore(ttlDays: 0)
        store.record(archiveURL: url("forever.zip"), items: [item("keep.txt")], now: t0)
        let muchLater = t0.addingTimeInterval(3650 * 86_400) // 10 年后
        #expect(store.search("keep", now: muchLater).count == 1)
    }

    @Test func searchSkipsDirectoriesAndIsCaseInsensitive() {
        let store = makeStore()
        store.record(archiveURL: url("d.zip"),
                     items: [item("MatchDir", isDirectory: true), item("MatchFile.txt")], now: t0)
        let hits = store.search("match", now: t0) // 小写查询命中混合大小写
        #expect(hits.count == 1)
        #expect(hits.first?.entryName == "MatchFile.txt")
    }

    @Test func disabledPolicyDoesNotRecord() {
        let store = makeStore(enabled: false)
        #expect(store.record(archiveURL: url("x.zip"), items: [item("y.txt")], now: t0) == false)
        #expect(store.count() == 0)
    }

    @Test func applyCurrentLimitsTrimsToLoweredCap() {
        // 共享一个 UserDefaults:先用宽松策略(上限 5)塞 3 个,再用收紧策略(上限 1)的 store
        // 调 applyCurrentLimits —— 模拟用户在设置里把上限调小后立刻生效。
        let defaults = suiteDefaults.make("ArchiveListingCacheTests")
        let loose = ArchiveListingCacheStore(defaults: defaults,
            policyProvider: { ArchiveListingCachePolicy(enabled: true, maxArchives: 5, ttlDays: 30) })
        loose.record(archiveURL: url("a.zip"), items: [item("alpha.txt")], now: t0)
        loose.record(archiveURL: url("b.zip"), items: [item("bravo.txt")], now: t0.addingTimeInterval(10))
        loose.record(archiveURL: url("c.zip"), items: [item("charlie.txt")], now: t0.addingTimeInterval(20))
        #expect(loose.count() == 3)

        let tight = ArchiveListingCacheStore(defaults: defaults,
            policyProvider: { ArchiveListingCachePolicy(enabled: true, maxArchives: 1, ttlDays: 30) })
        tight.applyCurrentLimits(now: t0.addingTimeInterval(30))
        // 只留最新的 c。
        #expect(tight.count() == 1)
        #expect(tight.search("charlie", now: t0.addingTimeInterval(30)).count == 1)
        #expect(tight.search("alpha", now: t0.addingTimeInterval(30)).isEmpty)
    }

    @Test func fileBaseNamesDedupesAndSkipsDirectories() {
        let store = makeStore()
        store.record(archiveURL: url("k.zip"), items: [
            item("Resources/zh-Hans.lproj/Localizable.strings"),
            item("Resources/en.lproj/Localizable.strings"), // 同 basename Localizable.strings → 去重
            item("src", isDirectory: true),                 // 目录跳过
            item("README.md")
        ], now: t0)
        guard let entry = store.loadAll().first else { #expect(Bool(false)); return }
        let names = entry.fileBaseNames()
        // basename 去重(两个 Localizable.strings 只留一个)+ 跳过目录条目 "src"。
        #expect(names == ["Localizable.strings", "README.md"])
    }

    @Test func filePathsKeepFullPathsNoDedup() {
        let store = makeStore()
        store.record(archiveURL: url("paths.zip"), items: [
            item("Resources/zh-Hans.lproj/Localizable.strings"),
            item("Resources/en.lproj/Localizable.strings"), // 同 basename 但**不**去重(路径不同)
            item("docs", isDirectory: true),                 // 目录跳过
            item("README.md")
        ], now: t0)
        guard let entry = store.loadAll().first else { #expect(Bool(false)); return }
        let paths = entry.filePaths()
        // 保留完整路径、不去重、跳目录 —— 颗粒度比去重 basename 细。
        #expect(paths == [
            "Resources/zh-Hans.lproj/Localizable.strings",
            "Resources/en.lproj/Localizable.strings",
            "README.md"
        ])
        #expect(entry.fileEntryCount == 3)
        #expect(entry.filePaths(limit: 2).count == 2)
    }

    @Test func fileBaseNamesRespectsLimit() {
        let store = makeStore()
        store.record(archiveURL: url("big.zip"),
                     items: (0..<10).map { item("f\($0).txt") }, now: t0)
        guard let entry = store.loadAll().first else { #expect(Bool(false)); return }
        #expect(entry.fileBaseNames(limit: 3).count == 3)
    }

    @Test func removeAndClear() {
        let store = makeStore()
        store.record(archiveURL: url("one.zip"), items: [item("one.txt")], now: t0)
        store.record(archiveURL: url("two.zip"), items: [item("two.txt")], now: t0.addingTimeInterval(1))
        #expect(store.count() == 2)

        if let path = store.loadAll().first?.archivePath {
            store.remove(archivePath: path)
            #expect(store.count() == 1)
        }
        store.clear()
        #expect(store.count() == 0)
    }
}
