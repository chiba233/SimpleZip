//
//  AICompactContextCodecTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 上下文 JSON 键值压缩(白皮书工程补充四)。压缩只为降 TTFT,round-trip 必须语义等价。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AICompactContextCodecTests {

    /// 造一个 > 1.5 KB 的上下文 JSON,含字典里的 key 和 value token。
    private func largeContext() -> String {
        var tags: [String] = []
        for _ in 0..<60 { tags.append("checksum-mismatch"); tags.append("missing-volume") }
        let payload: [String: Any] = [
            "schema": "simplezip.ai.context.v1",
            "purpose": "activityFilter",
            "facts": [
                "diagnosticTags": tags,
                "folderNameTokens": ["release", "simplezip"],
                "semanticTags": ["source-archive", "release-artifact"],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func smallContextNotCompressed() {
        let small = #"{"schema":"x","facts":{"diagnosticTags":["checksum-mismatch"]}}"#
        let result = AICompactContextCodec.compact(small)
        #expect(result.compacted == false)
        #expect(result.json == small)
    }

    @Test func largeContextGetsKeyAndValueTokens() {
        let result = AICompactContextCodec.compact(largeContext())
        #expect(result.compacted)
        // 长 key 被换成短 token。
        #expect(result.json.contains("\"f\":"))   // facts
        #expect(result.json.contains("\"dt\":"))  // diagnosticTags
        #expect(result.json.contains("\"fnt\":")) // folderNameTokens
        // 长 value 被换成短 token。
        #expect(result.json.contains("\"csm\""))  // checksum-mismatch
        #expect(result.json.contains("\"mv\""))   // missing-volume
        // 原长 token 不再裸露。
        #expect(!result.json.contains("diagnosticTags"))
        #expect(!result.json.contains("checksum-mismatch"))
    }

    @Test func roundTripIsSemanticallyEqual() throws {
        let original = largeContext()
        let compacted = AICompactContextCodec.compact(original)
        #expect(compacted.compacted)
        let expanded = AICompactContextCodec.expand(compacted.json)

        // 解析回对象比较结构,而非字符串(key 顺序 / 空白可不同)。
        let a = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]
        let b = try JSONSerialization.jsonObject(with: Data(expanded.utf8)) as! [String: Any]
        #expect(NSDictionary(dictionary: a).isEqual(to: b))
    }

    @Test func expandReversesCompactOnShortTokens() {
        let compactJSON = #"{"f":{"dt":["csm","mv"]},"p":"activityFilter","s":"x"}"#
        let expanded = AICompactContextCodec.expand(compactJSON)
        #expect(expanded.contains("facts"))
        #expect(expanded.contains("diagnosticTags"))
        #expect(expanded.contains("checksum-mismatch"))
        #expect(expanded.contains("missing-volume"))
    }

    @Test func numbersAndBoolsSurviveRoundTrip() throws {
        var padding: [String: Any] = [:]
        for i in 0..<80 { padding["folderNameTokens\(i)"] = "release-artifact" }
        padding["count"] = 42
        padding["flag"] = true
        let json = String(decoding: try JSONSerialization.data(withJSONObject: padding, options: [.sortedKeys]), as: UTF8.self)
        let expanded = AICompactContextCodec.expand(AICompactContextCodec.compact(json).json)
        let back = try JSONSerialization.jsonObject(with: Data(expanded.utf8)) as! [String: Any]
        #expect(back["count"] as? Int == 42)
        #expect(back["flag"] as? Bool == true)
    }

    @Test func unparseableInputReturnedUnchanged() {
        let garbage = String(repeating: "not json at all ", count: 200) // > 1.5KB 但非 JSON
        #expect(garbage.utf8.count >= AICompactContextCodec.minBytesToCompress)
        let result = AICompactContextCodec.compact(garbage)
        #expect(result.compacted == false)
        #expect(result.json == garbage)
    }

    @Test func dictionaryVersionStable() {
        #expect(AICompactContextCodec.v1.schema == "simplezip.ai.compactDict.v1")
        #expect(AICompactContextCodec.v1.keys["facts"] == "f")
        #expect(AICompactContextCodec.v1.values["checksum-mismatch"] == "csm")
        // 短 token 无重复(invert 不丢映射)。
        #expect(Set(AICompactContextCodec.v1.keys.values).count == AICompactContextCodec.v1.keys.count)
        #expect(Set(AICompactContextCodec.v1.values.values).count == AICompactContextCodec.v1.values.count)
    }
}
