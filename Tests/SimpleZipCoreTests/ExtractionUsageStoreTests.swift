//
//  ExtractionUsageStoreTests.swift
//  SimpleZipCoreTests
//
//  #71:解压习惯统计 —— record 累积、mostUsed 取每字段众数(平票偏 false)、wouldChange/apply 只动推荐字段、清空。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ExtractionUsageStoreTests {
    private func makeStore() -> ExtractionUsageStore {
        let suite = UserDefaults(suiteName: "SZExtractUsageTest-\(UUID().uuidString)")!
        return ExtractionUsageStore(defaults: suite)
    }

    private func makeRequest(skipJunk: Bool = false, skipSymlinks: Bool = false,
                             extractIntoSubfolder: Bool = false, autoRenameConflicts: Bool = false,
                             revealWhenDone: Bool = false, trashOriginalWhenDone: Bool = false) -> ExtractArchiveRequest {
        var r = ExtractArchiveRequest(archiveURL: URL(fileURLWithPath: "/tmp/a.zip"),
                                      destinationURL: URL(fileURLWithPath: "/tmp"))
        r.skipJunk = skipJunk
        r.skipSymlinks = skipSymlinks
        r.extractIntoSubfolder = extractIntoSubfolder
        r.autoRenameConflicts = autoRenameConflicts
        r.revealWhenDone = revealWhenDone
        r.trashOriginalWhenDone = trashOriginalWhenDone
        return r
    }

    @Test func mostUsedPicksModalValuePerField() {
        let store = makeStore()
        store.record(makeRequest(skipJunk: true))
        store.record(makeRequest(skipJunk: true))
        store.record(makeRequest(skipJunk: true))
        store.record(makeRequest(skipJunk: false))   // 3 true vs 1 false → true

        let rec = store.mostUsed()
        #expect(rec != nil)
        #expect(rec?.values[.skipJunk] == true)
        #expect(rec?.values[.revealWhenDone] == false)   // 一直默认 false
    }

    @Test func tieFavorsFalse() {
        let store = makeStore()
        store.record(makeRequest(extractIntoSubfolder: true))
        store.record(makeRequest(extractIntoSubfolder: false))   // 平票 → 取 false(保守)
        #expect(store.mostUsed()?.values[.extractIntoSubfolder] == false)
    }

    @Test func noDataReturnsNil() {
        let store = makeStore()
        #expect(store.mostUsed() == nil)
        #expect(store.hasData() == false)
    }

    @Test func clearRemovesAllData() {
        let store = makeStore()
        store.record(makeRequest(skipJunk: true))
        #expect(store.hasData() == true)
        store.clear()
        #expect(store.hasData() == false)
        #expect(store.mostUsed() == nil)
    }

    @Test func wouldChangeReflectsCurrentRequest() {
        let rec = ExtractionUsageRecommendation(values: [.skipJunk: true, .revealWhenDone: false])
        #expect(rec.wouldChange(makeRequest(skipJunk: false)) == true)    // 当前 false,推荐 true
        #expect(rec.wouldChange(makeRequest(skipJunk: true)) == false)    // 已一致 → 不必露出
    }

    @Test func applyTouchesOnlyRecommendedFields() {
        let rec = ExtractionUsageRecommendation(values: [.skipJunk: true])
        var request = makeRequest(skipJunk: false, trashOriginalWhenDone: true)
        rec.apply(to: &request)
        #expect(request.skipJunk == true)               // 被推荐 → 改
        #expect(request.trashOriginalWhenDone == true)  // 不在推荐里 → 不动
    }
}
