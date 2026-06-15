//
//  AICompactContextCodec.swift
//  SimpleZip
//
//  0.4.5 #80:AI 上下文 JSON 键值压缩(白皮书工程补充四「JSON 键值压缩状态机」)。Apple FoundationModels
//  的本地首字延迟(TTFT)对 prompt 长度敏感,而 SimpleZip 的上下文反复出现 `diagnosticTags`、
//  `checksum-mismatch`、`sourceRefs`、`folderNameTokens` 这类长 key/value。这里在 `AIContextEnvelope.jsonString()`
//  之后、模型调用之前,用固定 token 字典把长 key/value 换成短 token。
//
//  **不用正则替换 prompt 字符串** —— 基于 JSON AST 遍历(只替换字典 key 与匹配的字符串值),数字 / bool /
//  结构不动。压缩只用于模型输入,**不替代持久化 schema**;模型按同一短 token 输出,App decode 后映射回长 token。
//  <1.5 KB 的上下文不压缩(复杂度大于收益)。字典版本固定,有回归测试。纯函数、确定性,SwiftPM 可断言。
//

import Foundation

nonisolated enum AICompactContextCodec {
    /// 固定 token 字典(long → short)。**版本一旦发布不可改 token 映射** —— 改了要新版本号 + 回归测试。
    nonisolated struct TokenDictionary: Codable, Equatable, Sendable {
        let schema: String
        /// 字典 key 的 long → short 映射。
        let keys: [String: String]
        /// 字符串值(稳定枚举 token)的 long → short 映射。
        let values: [String: String]
    }

    static let v1 = TokenDictionary(
        schema: "simplezip.ai.compactDict.v1",
        keys: [
            "schema": "s",
            "purpose": "p",
            "facts": "f",
            "diagnosticTags": "dt",
            "sourceRefs": "sr",
            "archiveProfile": "ap",
            "markerFiles": "mf",
            "semanticTags": "st",
            "dominantExtensions": "de",
            "locationKinds": "lk",
            "folderNameTokens": "fnt",
            "encryptedEntriesOmitted": "eeo",
            "allowedActions": "aa",
        ],
        values: [
            "checksum-mismatch": "csm",
            "permission-denied": "pd",
            "missing-volume": "mv",
            "needs-password": "npw",
            "release-artifact": "rel",
            "source-archive": "src",
            "signed-container-related": "sig",
        ]
    )

    /// 小于此字节数的上下文不压缩。
    static let minBytesToCompress = 1536

    /// 按字典压缩 JSON(基于 AST)。返回压缩后的 JSON 与是否真的压缩了。
    /// 不可解析 / 太小 → 原样返回 `compacted == false`。
    static func compact(_ json: String, dictionary: TokenDictionary = v1) -> (json: String, compacted: Bool) {
        guard json.utf8.count >= minBytesToCompress,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return (json, false) }

        let transformed = transform(object, keyMap: dictionary.keys, valueMap: dictionary.values)
        guard let out = try? JSONSerialization.data(
            withJSONObject: transformed, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return (json, false) }
        return (String(decoding: out, as: UTF8.self), true)
    }

    /// 反向展开:把短 token 还原成长 token(模型输出走这里)。不可解析 → 原样返回。
    static func expand(_ json: String, dictionary: TokenDictionary = v1) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return json }

        let keyMap = invert(dictionary.keys)
        let valueMap = invert(dictionary.values)
        let transformed = transform(object, keyMap: keyMap, valueMap: valueMap)
        guard let out = try? JSONSerialization.data(
            withJSONObject: transformed, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: -

    /// 递归遍历 JSON AST:字典 key 走 `keyMap`,字符串值走 `valueMap`;数字 / bool / 结构不动。
    private static func transform(_ value: Any, keyMap: [String: String], valueMap: [String: String]) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, child) in dict {
                out[keyMap[key] ?? key] = transform(child, keyMap: keyMap, valueMap: valueMap)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { transform($0, keyMap: keyMap, valueMap: valueMap) }
        }
        if let string = value as? String {
            return valueMap[string] ?? string
        }
        return value
    }

    /// 反转 long→short 为 short→long。short token 应唯一;万一重复,保留第一个而非崩溃。
    private static func invert(_ map: [String: String]) -> [String: String] {
        Swift.Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }
}
