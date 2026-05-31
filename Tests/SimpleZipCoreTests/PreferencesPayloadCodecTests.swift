//
//  PreferencesPayloadCodecTests.swift
//  SimpleZip
//
//  钉死偏好导出 JSON 的 schema + 版本号 + 错误识别。任何让恶意 / 异常 JSON 偷偷
//  写进 UserDefaults 的回归都会很糟，所以这里所有 decode 失败的分支都有显式断言。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct PreferencesPayloadCodecTests {

    // MARK: - 正向

    @Test
    func makePayloadIncludesSchemaVersionAndValues() {
        let values: [String: Any] = ["appLanguage": "zh-Hans", "rememberLastFolder": true]
        let payload = PreferencesPayloadCodec.makePayload(values: values, date: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(payload["schema"] as? String == "SimpleZip.preferences")
        #expect(payload["version"] as? Int == 1)
        let unwrappedValues = payload["values"] as? [String: Any]
        #expect(unwrappedValues?["appLanguage"] as? String == "zh-Hans")
        #expect(unwrappedValues?["rememberLastFolder"] as? Bool == true)
        // 时间戳格式必须是 ISO-8601 —— 老老实实匹配前缀就行（时区位末尾可能是 Z 或 +08:00）。
        let exported = payload["exportedAt"] as? String ?? ""
        #expect(exported.hasPrefix("2023-11-14"))
    }

    @Test
    func decodeReturnsValuesForWellFormedPayload() throws {
        let payload: [String: Any] = [
            "schema": "SimpleZip.preferences",
            "version": 1,
            "exportedAt": "2026-05-29T17:18:24Z",
            "values": ["startupLocation": "downloads"]
        ]
        let values = try PreferencesPayloadCodec.decode(payload)
        #expect(values["startupLocation"] as? String == "downloads")
    }

    @Test
    func roundTripMakeAndDecodePreservesValues() throws {
        let original: [String: Any] = [
            "showHiddenFiles": false,
            "hiddenCustomSuffixes": ["tmp", "log"],
            "sevenZipBackend": "automatic"
        ]
        let payload = PreferencesPayloadCodec.makePayload(values: original)
        let decoded = try PreferencesPayloadCodec.decode(payload)
        #expect(decoded["showHiddenFiles"] as? Bool == false)
        #expect(decoded["hiddenCustomSuffixes"] as? [String] == ["tmp", "log"])
        #expect(decoded["sevenZipBackend"] as? String == "automatic")
    }

    // MARK: - 错误分支

    @Test
    func decodeRejectsPayloadWithoutSchemaField() {
        let payload: [String: Any] = [
            "version": 1,
            "values": [:]
        ]
        #expect(throws: PreferencesPayloadCodec.DecodeError.missingSchema) {
            try PreferencesPayloadCodec.decode(payload)
        }
    }

    @Test
    func decodeRejectsForeignSchema() {
        let payload: [String: Any] = [
            "schema": "OtherApp.preferences",
            "version": 1,
            "values": [:]
        ]
        #expect(throws: PreferencesPayloadCodec.DecodeError.foreignSchema("OtherApp.preferences")) {
            try PreferencesPayloadCodec.decode(payload)
        }
    }

    @Test
    func decodeRejectsUnsupportedVersion() {
        let payload: [String: Any] = [
            "schema": "SimpleZip.preferences",
            "version": 99,
            "values": [:]
        ]
        // 未来 schema bump 时，旧版 SimpleZip 读到要明确告诉用户「请升级」，
        // 而不是悄悄写一堆它根本不认识的 key 进 UserDefaults。
        #expect(throws: PreferencesPayloadCodec.DecodeError.unsupportedVersion(found: 99, supported: 1)) {
            try PreferencesPayloadCodec.decode(payload)
        }
    }

    @Test
    func decodeRejectsMissingValuesField() {
        let payload: [String: Any] = [
            "schema": "SimpleZip.preferences",
            "version": 1
        ]
        #expect(throws: PreferencesPayloadCodec.DecodeError.missingValues) {
            try PreferencesPayloadCodec.decode(payload)
        }
    }

    // MARK: - 导出完整性

    /// 导出快照必须覆盖每一个可导出 key（含停在默认值的 key）—— 守住「备份是一份完整配置快照」的不变量，
    /// 防止有人往 exportableUserDefaultsKeys 加了 key 却忘了在 exportableSnapshot 里补对应的有效值。
    /// `startupCustomLocationPath` 是可选路径，未设置时不落键，单独排除。
    /// 只读 UserDefaults.standard、不写，对测试环境无副作用。
    @Test
    func exportableSnapshotCoversAllExportableKeys() {
        let snapshotKeys = Set(AppPreferences.exportableSnapshot().keys)
        let required = Set(AppPreferences.exportableUserDefaultsKeys)
            .subtracting([AppPreferences.Key.startupCustomLocationPath])
        let missing = required.subtracting(snapshotKeys)
        #expect(missing.isEmpty, "exportableSnapshot 缺这些可导出 key：\(missing.sorted())")
    }
}
