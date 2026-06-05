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
}
