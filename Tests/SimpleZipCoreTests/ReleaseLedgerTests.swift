//
//  ReleaseLedgerTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #2:发布账本 —— 追加顺序 / 上限裁旧 / Codable 兼容。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseLedgerTests {
    private func makeStore() -> (ReleaseLedgerStore, UserDefaults) {
        let suiteName = "ReleaseLedgerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ReleaseLedgerStore(defaults: defaults), defaults)
    }

    private func entry(_ label: String, sha: String? = nil) -> ReleaseLedgerEntry {
        ReleaseLedgerEntry(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            artifactPath: "/tmp/\(label).zip",
            versionLabel: label,
            formatRawValue: "zip",
            sha256: sha,
            structuralFingerprint: nil,
            reproducible: true,
            excludeJunk: true,
            inspectionRan: true,
            testPassed: true,
            suspiciousPathCount: 0,
            junkCount: 0,
            emptyDirectoryCount: 0,
            fileCount: 12,
            totalBytes: 1024,
            wroteChecksums: true,
            signRequested: false,
            appVersion: "0.4.4",
            backendVersion: "24.09",
            steps: [ReleaseRunStep(id: .createArchive, status: .succeeded, durationSeconds: 1.5, failureMessage: nil)]
        )
    }

    @Test func appendsNewestFirst() {
        let (store, _) = makeStore()
        store.append(entry("1.0.0"))
        store.append(entry("1.0.1"))
        let all = store.loadAll()
        #expect(all.map(\.versionLabel) == ["1.0.1", "1.0.0"])
    }

    @Test func capsAtMaxEntriesDroppingOldest() {
        let (store, _) = makeStore()
        for index in 0...(ReleaseLedgerStore.maxEntries + 4) {
            store.append(entry("v\(index)"))
        }
        let all = store.loadAll()
        #expect(all.count == ReleaseLedgerStore.maxEntries)
        #expect(all.first?.versionLabel == "v\(ReleaseLedgerStore.maxEntries + 4)")
        #expect(all.last?.versionLabel == "v5")
    }

    @Test func deleteRemovesByID() {
        let (store, _) = makeStore()
        let target = entry("1.2.3")
        store.append(target)
        store.append(entry("1.2.4"))
        store.delete(id: target.id)
        #expect(store.loadAll().map(\.versionLabel) == ["1.2.4"])
    }

    @Test func roundTripsAndStepsSurvive() {
        let (store, _) = makeStore()
        store.append(entry("2.0.0", sha: "abc123"))
        let loaded = store.loadAll()
        #expect(loaded.first?.sha256 == "abc123")
        #expect(loaded.first?.steps.first?.id == .createArchive)
        #expect(loaded.first?.steps.first?.formattedDuration == "1.5 s")
    }

    @Test func workspacePresetWithoutVersionLabelStillDecodes() throws {
        // 旧版 ReleaseWorkspacePreset JSON 没有 versionLabel —— 解码必须兼容(nil)。
        let legacy = """
        [{"id":"\(UUID().uuidString)","name":"legacy","fileName":"app","formatRawValue":"zip",
          "excludeJunk":true,"reproducible":true,"runInspection":true,"writeChecksums":true,
          "createSignedManifest":false}]
        """
        let presets = try JSONDecoder().decode([ReleaseWorkspacePreset].self, from: Data(legacy.utf8))
        #expect(presets.first?.versionLabel == nil)
        #expect(presets.first?.name == "legacy")
    }
}
