//
//  CompressionUsageStoreTests.swift
//  SimpleZipCoreTests
//
//  #32:压缩使用频率统计 —— record 累积、mostUsedPreset 取每字段众数、清空。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite final class CompressionUsageStoreTests {
    private let suiteDefaults = SuiteDefaults()
    private func makeStore() -> CompressionUsageStore {
        // 独立 suite 隔离,不碰 standard 的真实数据;实例释放时自动清域。
        CompressionUsageStore(defaults: suiteDefaults.make("SZUsageTest"))
    }

    @Test func mostUsedPicksModalValuePerField() {
        let store = makeStore()
        var heavy = ArchiveCreationOptions(); heavy.format = .zip
        heavy.compressionLevel = .maximum
        heavy.skipDSStore = true
        var light = ArchiveCreationOptions(); light.format = .zip
        light.compressionLevel = .normal
        light.skipDSStore = false
        store.record(heavy); store.record(heavy); store.record(heavy)
        store.record(light)

        let preset = store.mostUsedPreset(for: .zip)
        #expect(preset != nil)
        #expect(preset?.options.compressionLevel == .maximum)   // 3 vs 1
        #expect(preset?.options.skipDSStore == true)            // 3 vs 1
        #expect(preset?.includedFields.contains(.level) == true)
        #expect(preset?.includedFields.contains(.skipDSStore) == true)
    }

    @Test func keysPerFormatDoNotMix() {
        let store = makeStore()
        var zip = ArchiveCreationOptions(); zip.format = .zip; zip.compressionLevel = .maximum
        var sevenZip = ArchiveCreationOptions(); sevenZip.format = .sevenZip; sevenZip.compressionLevel = .fast
        store.record(zip)
        store.record(sevenZip)
        #expect(store.mostUsedPreset(for: .zip)?.options.compressionLevel == .maximum)
        #expect(store.mostUsedPreset(for: .sevenZip)?.options.compressionLevel == .fast)
    }

    @Test func noDataReturnsNil() {
        let store = makeStore()
        #expect(store.mostUsedPreset(for: .sevenZip) == nil)
        #expect(store.hasData(for: .sevenZip) == false)
    }

    @Test func clearRemovesAllData() {
        let store = makeStore()
        var options = ArchiveCreationOptions(); options.format = .zip
        store.record(options)
        #expect(store.hasData(for: .zip) == true)
        store.clear()
        #expect(store.hasData(for: .zip) == false)
        #expect(store.mostUsedPreset(for: .zip) == nil)
    }

    @Test func sensitiveFieldsAreNeverTracked() {
        // password / GPG 不属于 CompressionOptionField,自然不在 trackedFields 里 —— 这里钉死这个不变量。
        let tracked = Set(CompressionUsageStore.trackedFields.map(\.rawValue))
        #expect(!tracked.contains("password"))
        #expect(!tracked.contains("rawParameters"))   // 自由文本也排除
        #expect(!tracked.contains("customExcludes"))
    }
}
