//
//  ToolbarActionUsageStoreTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 建议七:工具栏动作习惯统计 —— 按选择上下文桶记点击、产出习惯信号、桶隔离、清空。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite final class ToolbarActionUsageStoreTests {
    private let suiteDefaults = SuiteDefaults()
    private func makeStore() -> ToolbarActionUsageStore {
        ToolbarActionUsageStore(defaults: suiteDefaults.make("test.toolbarUsage"), storageKey: "stats")
    }

    private func file(_ name: String) -> ContextualToolbarSnapshot.SelectedFile {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return ContextualToolbarSnapshot.SelectedFile(
            name: name, pathExtension: url.pathExtension.lowercased(),
            isDirectory: false, isSupportedArchive: ArchiveService.isSupportedArchive(url))
    }

    @Test func recordsClicksKeyedByContext() {
        let store = makeStore()
        let snapshot = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip")])
        store.record(actionID: "analyzeSpace", in: snapshot)
        store.record(actionID: "analyzeSpace", in: snapshot)
        store.record(actionID: "checkupArchives", in: snapshot)

        let signals = store.usageSignals(for: snapshot)
        #expect(signals.first(where: { $0.actionID == "analyzeSpace" })?.clicked == 2)
        #expect(signals.first(where: { $0.actionID == "checkupArchives" })?.clicked == 1)
    }

    @Test func bucketsSeparateDifferentContexts() {
        let store = makeStore()
        let folder = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip")])
        let archive = ContextualToolbarSnapshot(mode: .archive, selectedArchiveItemCount: 1)
        store.record(actionID: "analyzeSpace", in: folder)

        #expect(store.usageSignals(for: folder).isEmpty == false)
        #expect(store.usageSignals(for: archive).isEmpty)
    }

    @Test func contextBucketStableBySelectionShape() {
        let bucket = ToolbarActionUsageStore.contextBucket(for:)
        let oneZip = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip")])
        let oneZipB = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("b.zip")])
        let oneTxt = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.txt")])
        let twoZip = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip"), file("b.zip")])
        // 单选:同后缀同桶、不同后缀不同桶(细颗粒)。
        #expect(bucket(oneZip) == bucket(oneZipB))
        #expect(bucket(oneZip) != bucket(oneTxt))
        // 单选 vs 复选:不同桶。
        #expect(bucket(oneZip) != bucket(twoZip))
    }

    @Test func multiSelectSharesOnePoolRegardlessOfExtension() {
        let bucket = ToolbarActionUsageStore.contextBucket(for:)
        let twoZip = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip"), file("b.zip")])
        let twoMixed = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip"), file("b.txt")])
        let threeZip = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip"), file("b.zip"), file("c.zip")])
        // 复选即使同后缀也走同一桶,不按后缀细分。
        #expect(bucket(twoZip) == bucket(twoMixed))
        #expect(bucket(twoZip) == bucket(threeZip))
    }

    @Test func clearResetsSignals() {
        let store = makeStore()
        let snapshot = ContextualToolbarSnapshot(mode: .folder, selectedFiles: [file("a.zip")])
        store.record(actionID: "analyzeSpace", in: snapshot)
        store.clear()
        #expect(store.usageSignals(for: snapshot).isEmpty)
    }
}
