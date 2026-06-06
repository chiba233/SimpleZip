import Foundation
import Testing
@testable import SimpleZipCore

/// #115 压缩 Presets —— 模型 sanitize + UserDefaults 持久化的回归测试。
struct CompressionPresetTests {

    /// 每个测试用独立的 in-memory UserDefaults suite，互不污染。
    private func makeStore() -> (CompressionPresetStore, UserDefaults) {
        let suite = "SimpleZipTests.presets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CompressionPresetStore(defaults: defaults), defaults)
    }

    private func optionsWithSecrets() -> ArchiveCreationOptions {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.compressionLevel = .maximum
        options.sevenZipMethod = .lzma2
        options.password = "hunter2"
        options.passwordConfirmation = "hunter2"
        options.showPassword = true
        options.gpgSign = true
        options.gpgSigningKeyFingerprint = "DEADBEEF"
        options.gpgRecipientFingerprints = ["AAAA", "BBBB"]
        options.gpgSymmetricPassphrase = "s3cret"
        options.gpgDeliveryNote = "hi there"
        return options
    }

    @Test func sanitizeStripsSecretsButKeepsReusableSettings() {
        let preset = CompressionPreset(name: "高压缩 7z", options: optionsWithSecrets())
        let clean = preset.sanitized().options

        // 抹掉的敏感字段
        #expect(clean.password.isEmpty)
        #expect(clean.passwordConfirmation.isEmpty)
        #expect(clean.showPassword == false)
        #expect(clean.gpgSigningKeyFingerprint.isEmpty)
        #expect(clean.gpgRecipientFingerprints.isEmpty)
        #expect(clean.gpgSymmetricPassphrase.isEmpty)
        #expect(clean.gpgDeliveryNote.isEmpty)
        // 保留的可复用设置
        #expect(clean.format == .sevenZip)
        #expect(clean.compressionLevel == .maximum)
        #expect(clean.sevenZipMethod == .lzma2)
        #expect(clean.gpgSign == true) // 「是否签名」是可复用意图；签名 key 才是逐次选
    }

    @Test func addLoadRoundTripsAndPersistsSanitized() {
        let (store, _) = makeStore()
        let preset = CompressionPreset(name: "work zip", options: optionsWithSecrets())

        let afterAdd = store.add(preset)
        #expect(afterAdd.count == 1)

        let loaded = store.load()
        #expect(loaded.count == 1)
        let only = try! #require(loaded.first)
        #expect(only.id == preset.id)
        #expect(only.name == "work zip")
        // 持久化的内容已 sanitize：明文密码不该落盘。
        #expect(only.options.password.isEmpty)
        #expect(only.options.gpgSymmetricPassphrase.isEmpty)
        #expect(only.options.format == .sevenZip)
    }

    @Test func updateReplacesByIDAndIgnoresUnknownID() {
        let (store, _) = makeStore()
        var preset = CompressionPreset(name: "v1", options: ArchiveCreationOptions())
        store.add(preset)

        preset.name = "v2"
        preset.options.format = .tarGzip
        let afterUpdate = store.update(preset)
        #expect(afterUpdate.count == 1)
        #expect(store.load().first?.name == "v2")
        #expect(store.load().first?.options.format == .tarGzip)

        // 未知 id 不改动
        let stranger = CompressionPreset(name: "ghost", options: ArchiveCreationOptions())
        let afterStranger = store.update(stranger)
        #expect(afterStranger.count == 1)
        #expect(store.load().first?.name == "v2")
    }

    @Test func removeDeletesByID() {
        let (store, _) = makeStore()
        let a = CompressionPreset(name: "a", options: ArchiveCreationOptions())
        let b = CompressionPreset(name: "b", options: ArchiveCreationOptions())
        store.add(a); store.add(b)
        #expect(store.load().count == 2)

        let afterRemove = store.remove(id: a.id)
        #expect(afterRemove.map(\.name) == ["b"])
        #expect(store.load().map(\.name) == ["b"])
    }

    @Test func loadReturnsEmptyWhenNothingStored() {
        let (store, _) = makeStore()
        #expect(store.load().isEmpty)
    }

    @Test func loadReturnsEmptyOnCorruptData() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: "SimpleZip.CompressionPresets.v1")
        #expect(store.load().isEmpty)
    }

    // MARK: - 默认预设（Finder / NSService 一键简化压缩用）

    @Test func defaultPresetRoundTrips() {
        let (store, _) = makeStore()
        let a = CompressionPreset(name: "a", options: ArchiveCreationOptions())
        var bOptions = ArchiveCreationOptions()
        bOptions.format = .sevenZip
        bOptions.compressionLevel = .maximum
        let b = CompressionPreset(name: "b", options: bOptions)
        store.add(a); store.add(b)

        #expect(store.defaultPresetID() == nil)
        #expect(store.defaultPreset() == nil)

        store.setDefaultPresetID(b.id)
        #expect(store.defaultPresetID() == b.id)
        let def = try! #require(store.defaultPreset())
        #expect(def.name == "b")
        #expect(def.options.format == .sevenZip)
        #expect(def.options.compressionLevel == .maximum)
    }

    @Test func setDefaultIgnoresUnknownIDAndClearsOnNil() {
        let (store, _) = makeStore()
        let a = CompressionPreset(name: "a", options: ArchiveCreationOptions())
        store.add(a)
        store.setDefaultPresetID(a.id)
        #expect(store.defaultPresetID() == a.id)

        // 未知 id 不改变现有默认。
        store.setDefaultPresetID(UUID())
        #expect(store.defaultPresetID() == a.id)

        // nil 清除。
        store.setDefaultPresetID(nil)
        #expect(store.defaultPresetID() == nil)
    }

    @Test func removingDefaultClearsDefault() {
        let (store, _) = makeStore()
        let a = CompressionPreset(name: "a", options: ArchiveCreationOptions())
        let b = CompressionPreset(name: "b", options: ArchiveCreationOptions())
        store.add(a); store.add(b)
        store.setDefaultPresetID(a.id)

        store.remove(id: a.id)
        #expect(store.defaultPresetID() == nil)
        #expect(store.defaultPreset() == nil)
        // 删非默认的不影响默认。
        store.setDefaultPresetID(b.id)
        store.remove(id: UUID())
        #expect(store.defaultPresetID() == b.id)
    }

    @Test func defaultIDDanglingPointerTreatedAsUnset() {
        let (store, defaults) = makeStore()
        // 手动写一个指向不存在预设的默认 id（模拟历史数据）。
        defaults.set(UUID().uuidString, forKey: "SimpleZip.CompressionPresets.defaultID.v1")
        #expect(store.defaultPresetID() == nil)
        #expect(store.defaultPreset() == nil)
    }

    // MARK: - 按格式默认值（CompressionDefaultsStore + CompressionFormatPreset，#115 重做）

    private func makeDefaultsStore() -> CompressionDefaultsStore {
        let defaults = UserDefaults(suiteName: "SimpleZipTests.defaults.\(UUID().uuidString)")!
        return CompressionDefaultsStore(defaults: defaults)
    }

    @Test func formatPresetSanitizesAndPinsFormat() {
        var o = ArchiveCreationOptions()
        o.format = .zip                 // 故意填错格式
        o.compressionLevel = .maximum
        o.password = "secret"           // 必须被抹掉
        o.gpgSigningKeyFingerprint = "DEAD"
        let preset = CompressionFormatPreset(format: .sevenZip, includedFields: [.level], options: o)
        #expect(preset.options.format == .sevenZip)
        #expect(preset.options.password.isEmpty)
        #expect(preset.options.gpgSigningKeyFingerprint.isEmpty)
        #expect(preset.options.compressionLevel == .maximum)
    }

    @Test func applyOnlyOverridesEnabledFields() {
        var stored = ArchiveCreationOptions()
        stored.compressionLevel = .maximum
        stored.sevenZipMethod = .ppmd
        stored.skipDSStore = false
        // 只启用 level + method，不启用 skipDSStore。
        let preset = CompressionFormatPreset(format: .sevenZip, includedFields: [.level, .sevenZipMethod], options: stored)

        var target = ArchiveCreationOptions()   // 全默认（level=.normal, method=.automatic, skipDSStore=true）
        target.format = .sevenZip
        preset.apply(to: &target)

        #expect(target.compressionLevel == .maximum)   // 启用 → 覆盖
        #expect(target.sevenZipMethod == .ppmd)        // 启用 → 覆盖
        #expect(target.skipDSStore == true)            // 没启用 → 保持 target 默认（不被 stored 的 false 覆盖）
    }

    @Test func defaultsStoreRoundTripAndReset() {
        let store = makeDefaultsStore()
        #expect(store.preset(for: .sevenZip) == nil)
        #expect(store.hasPreset(for: .sevenZip) == false)
        #expect(store.allPresets().isEmpty)

        store.save(CompressionFormatPreset(format: .sevenZip, includedFields: [.level], options: ArchiveCreationOptions()))
        store.save(CompressionFormatPreset(format: .zip, includedFields: [], options: ArchiveCreationOptions()))
        #expect(store.hasPreset(for: .sevenZip))
        #expect(store.allPresets().count == 2)

        store.reset(for: .sevenZip)
        #expect(store.hasPreset(for: .sevenZip) == false)
        #expect(store.hasPreset(for: .zip))            // 互不影响
    }

    /// #115 备份覆盖:默认压缩设置存的是 JSON Data,备份导出要把它转成 JSON 对象、导入再 JSON 重编码回 Data。
    /// 这条守住那段「Data ↔ JSON 对象」round-trip —— 也是 `exportablePayload` / `importPayload` 实际依赖的逻辑。
    @Test func formatPresetSurvivesBackupJSONRoundTrip() throws {
        let key = AppPreferences.Key.compressionFormatPresets
        let suiteA = UserDefaults(suiteName: "SimpleZipTests.backupA.\(UUID().uuidString)")!
        let storeA = CompressionDefaultsStore(defaults: suiteA)
        var options = ArchiveCreationOptions()
        options.compressionLevel = .maximum
        storeA.save(CompressionFormatPreset(format: .sevenZip, includedFields: [.level], options: options))

        // 模拟备份导出:读存盘 Data → JSON 对象（必须是合法 JSON 对象,否则进不了 payload）。
        let exportedData = try #require(suiteA.data(forKey: key))
        let jsonObject = try JSONSerialization.jsonObject(with: exportedData)
        #expect(JSONSerialization.isValidJSONObject(jsonObject))

        // 模拟备份导入:JSON 对象 → Data → 写进另一台机器的 suite。
        let reEncoded = try JSONSerialization.data(withJSONObject: jsonObject)
        let suiteB = UserDefaults(suiteName: "SimpleZipTests.backupB.\(UUID().uuidString)")!
        suiteB.set(reEncoded, forKey: key)

        let storeB = CompressionDefaultsStore(defaults: suiteB)
        let restored = try #require(storeB.preset(for: .sevenZip))
        #expect(restored.includedFields == [.level])
        #expect(restored.options.compressionLevel == .maximum)
        #expect(restored.format == .sevenZip)
    }
}
