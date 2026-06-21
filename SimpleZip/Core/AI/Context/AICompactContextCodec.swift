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

    /// **field-aware value 展开白名单**(白皮书工程补充一·边界三)。只有这些字段的值是稳定枚举 token,才做
    /// value token 压缩 / 展开。`displayName` / `archiveName` / `folderNameTokens` / `dominantExtensions` /
    /// `absolutePath` / `pathTokens` 等是**用户文本**,永不 value-expand —— 否则用户文件名叫 `mv` 会被错展开
    /// 成 `missing-volume`、叫 `csm` 会被错展开成 `checksum-mismatch`。
    static let enumValueFields: Set<String> = [
        "diagnosticTags", "semanticTags", "roleTags", "locationKinds", "allowedActions",
    ]

    /// 压缩 / 展开中检出的结构问题(目前只有 key 碰撞)。`compact` / `expand` 捕获后退回未压缩 JSON(安全侧)。
    private enum CodecError: Error { case keyCollision }

    /// 按字典压缩 JSON(基于 AST)。返回压缩后的 JSON 与是否真的压缩了。
    /// 不可解析 / 太小 / **同层短 token 撞上已有业务 key** → 原样返回 `compacted == false`。
    static func compact(_ json: String, dictionary: TokenDictionary = v1) -> (json: String, compacted: Bool) {
        guard json.utf8.count >= minBytesToCompress,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return (json, false) }

        // transform 抛 keyCollision → try? 得 nil → 退回未压缩(不会产出 key 被覆盖的错 JSON)。
        guard let transformed = try? transform(
                object, keyMap: dictionary.keys, valueMap: dictionary.values,
                valueFields: enumValueFields, expandValuesHere: false),
              let out = try? JSONSerialization.data(
                withJSONObject: transformed, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return (json, false) }
        return (String(decoding: out, as: UTF8.self), true)
    }

    /// 反向展开:把短 token 还原成长 token(模型输出走这里)。不可解析 / 碰撞 → 原样返回。
    static func expand(_ json: String, dictionary: TokenDictionary = v1) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return json }

        let keyMap = invert(dictionary.keys)
        let valueMap = invert(dictionary.values)
        guard let transformed = try? transform(
                object, keyMap: keyMap, valueMap: valueMap,
                valueFields: enumValueFields, expandValuesHere: false),
              let out = try? JSONSerialization.data(
                withJSONObject: transformed, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: -

    /// 递归遍历 JSON AST。字典 key 走 `keyMap`;字符串值**只在 enum value 字段下**走 `valueMap`(field-aware,
    /// 防用户文件名被错展开)。数字 / bool / 结构不动。同层两个 key 映射到同一 token → 抛 `keyCollision`。
    /// `expandValuesHere` 表示当前层的值是否处在某个 enum value 字段内(由父级 key 判定后传入;数组继承父级)。
    private static func transform(_ value: Any, keyMap: [String: String], valueMap: [String: String],
                                  valueFields: Set<String>, expandValuesHere: Bool) throws -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, child) in dict {
                let mappedKey = keyMap[key] ?? key
                guard out[mappedKey] == nil else { throw CodecError.keyCollision }
                // 子值是否处在 enum value 字段内:长字段名命中白名单即可 —— compact 时 key 是长名、
                // expand 时 mappedKey 是长名,两个方向各命中一侧。
                let childInEnumField = valueFields.contains(key) || valueFields.contains(mappedKey)
                out[mappedKey] = try transform(child, keyMap: keyMap, valueMap: valueMap,
                                               valueFields: valueFields, expandValuesHere: childInEnumField)
            }
            return out
        }
        if let array = value as? [Any] {
            return try array.map {
                try transform($0, keyMap: keyMap, valueMap: valueMap,
                              valueFields: valueFields, expandValuesHere: expandValuesHere)
            }
        }
        if let string = value as? String {
            return expandValuesHere ? (valueMap[string] ?? string) : string
        }
        return value
    }

    /// 反转 long→short 为 short→long。short token 应唯一;万一重复,保留第一个而非崩溃。
    private static func invert(_ map: [String: String]) -> [String: String] {
        Swift.Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }
}
