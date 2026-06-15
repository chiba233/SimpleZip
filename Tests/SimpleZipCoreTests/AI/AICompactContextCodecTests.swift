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

    // MARK: - 边界三:key 命名空间 / 碰撞 + field-aware value 展开(白皮书工程补充一)

    @Test func compactionRefusesKeyCollision() throws {
        // 同层同时有 "facts"(→"f")和字面量 "f" → 压缩会让 "f" 互相覆盖,必须退回未压缩。
        let payload: [String: Any] = [
            "facts": ["diagnosticTags": Array(repeating: "checksum-mismatch", count: 100)],
            "f": "literal-collision",
        ]
        let json = String(decoding: try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        #expect(json.utf8.count >= AICompactContextCodec.minBytesToCompress)
        let result = AICompactContextCodec.compact(json)
        #expect(result.compacted == false)   // 碰撞 → 不压缩
        #expect(result.json == json)         // 原样返回,不产出被覆盖的错 JSON
    }

    @Test func expandDoesNotRewriteUserFilenameNamedMV() throws {
        // 用户文件名 "mv" 在非枚举字段(displayName)下,绝不能被展开成 "missing-volume"。
        let json = #"{"facts":{"displayName":"mv","dt":["mv"]}}"#
        let expanded = AICompactContextCodec.expand(json)
        let obj = try JSONSerialization.jsonObject(with: Data(expanded.utf8)) as! [String: Any]
        let facts = obj["facts"] as! [String: Any]
        #expect(facts["displayName"] as? String == "mv")                  // 用户文件名原样
        #expect(facts["diagnosticTags"] as? [String] == ["missing-volume"]) // 枚举字段下才展开
    }

    @Test func expandOnlyRewritesKnownEnumFields() throws {
        let json = #"{"facts":{"dt":["csm"],"displayName":"csm","archiveName":"npw"}}"#
        let obj = try JSONSerialization.jsonObject(
            with: Data(AICompactContextCodec.expand(json).utf8)) as! [String: Any]
        let facts = obj["facts"] as! [String: Any]
        #expect(facts["diagnosticTags"] as? [String] == ["checksum-mismatch"])  // 枚举字段:展开
        #expect(facts["displayName"] as? String == "csm")                       // 用户文本:不动
        #expect(facts["archiveName"] as? String == "npw")                       // 用户文本:不动
    }

    @Test func compactExpandRoundTripPreservesDisplayNameAndArchiveName() throws {
        let payload: [String: Any] = [
            "facts": [
                "displayName": "mv",          // 文件名恰好等于枚举短 token
                "archiveName": "csm",
                "diagnosticTags": Array(repeating: "checksum-mismatch", count: 100),
            ],
        ]
        let json = String(decoding: try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        let compacted = AICompactContextCodec.compact(json)
        #expect(compacted.compacted)
        let obj = try JSONSerialization.jsonObject(
            with: Data(AICompactContextCodec.expand(compacted.json).utf8)) as! [String: Any]
        let facts = obj["facts"] as! [String: Any]
        #expect(facts["displayName"] as? String == "mv")    // 往返不被改写
        #expect(facts["archiveName"] as? String == "csm")
        #expect((facts["diagnosticTags"] as? [String])?.first == "checksum-mismatch") // 枚举仍正确往返
    }
}
