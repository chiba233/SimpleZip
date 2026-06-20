//
//  AIDerivedHelpersTests.swift
//  SimpleZipCoreTests
//
//  独立 AI 进程改造 · 把 AIBackgroundIndexer(app target god-object)里的纯确定性 helper 下沉 Core 后**首次可单测**:
//  AIArchivePrefetchScope.leastRecentlyScanned(scope 轮转排序)、AIPrereadSelection.topAppBundleNames(dmg 内
//  .app 抽取)、AIAgeFacts.coarseWhenText(相对时间桶文本)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDerivedHelpersTests {
    // MARK: AIArchivePrefetchScope.leastRecentlyScanned

    private func scope(_ path: String, scannedAt: Date?) -> AIArchivePrefetchScope {
        AIArchivePrefetchScope(id: UUID(), directoryPath: path, origin: .userAdded,
                               createdAt: Date(timeIntervalSince1970: 0), lastScannedAt: scannedAt)
    }

    @Test func neverScannedSortsBeforeScanned() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let never = scope("/never", scannedAt: nil)
        let old = scope("/old", scannedAt: base)
        let recent = scope("/recent", scannedAt: base.addingTimeInterval(3_600))
        let sorted = [recent, old, never].sorted(by: AIArchivePrefetchScope.leastRecentlyScanned)
        #expect(sorted.map(\.directoryPath) == ["/never", "/old", "/recent"])
    }

    @Test func twoNeverScannedAreEqualUnderComparator() {
        // 两个都 nil → 比较器两向都返回 false(等价、不交换),排序稳定。
        let a = scope("/a", scannedAt: nil)
        let b = scope("/b", scannedAt: nil)
        #expect(!AIArchivePrefetchScope.leastRecentlyScanned(a, b))
        #expect(!AIArchivePrefetchScope.leastRecentlyScanned(b, a))
    }

    // MARK: AIPrereadSelection.topAppBundleNames

    private func item(_ name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: nil, modified: nil,
                    sizeText: "", modifiedText: "", method: "")
    }

    @Test func extractsDedupedAppBundleNames() {
        let items = [
            item("DockDoor Installer/DockDoor.app/Contents/MacOS/DockDoor"),
            item("DockDoor Installer/DockDoor.app/Contents/Info.plist"),  // 同一 .app 再现 → 去重
            item("Extras/Helper.app/Contents/MacOS/Helper"),
            item("readme.txt"),
        ]
        #expect(AIPrereadSelection.topAppBundleNames(in: items) == ["DockDoor.app", "Helper.app"])
    }

    @Test func returnsEmptyWhenNoApp() {
        #expect(AIPrereadSelection.topAppBundleNames(in: [item("a/b.txt"), item("c.zip")]).isEmpty)
    }

    @Test func capsAtSix() {
        let items = (1...10).map { item("Pkg/App\($0).app/Contents/x") }
        #expect(AIPrereadSelection.topAppBundleNames(in: items).count == 6)
    }

    // MARK: AIAgeFacts.coarseWhenText

    @Test func coarseWhenTextBuckets() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func when(_ ago: TimeInterval) -> String {
            AIAgeFacts.coarseWhenText(now.addingTimeInterval(-ago), now: now)
        }
        #expect(when(60) == "just now")
        #expect(when(1_800) == "a few minutes ago")
        #expect(when(7_200) == "earlier today")
        #expect(when(150_000) == "yesterday")
        #expect(when(400_000) == "a few days ago")
        #expect(when(1_000_000) == "recently")
    }
}
