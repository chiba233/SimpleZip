//
//  PreferencesPayloadCodec.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 偏好导出 / 导入用的 JSON payload 格式契约。
///
/// 设计动机：导出文件结构和 schema 校验、版本号迁移属于「永远不能被 UI / Foundation 偶发改动
/// 拖坏」的纯逻辑 —— 抽到 Core 里让 SwiftPM 测试可以用字典字面量构造异常 case，
/// 不必经过 UserDefaults / NSOpenPanel。AppPreferences 那一头只负责真实读 / 写 UserDefaults。
///
/// payload 形态:
/// ```json
/// {
///   "schema": "SimpleZip.preferences",
///   "version": 1,
///   "exportedAt": "2026-05-29T17:18:24Z",
///   "values": {
///     "<key>": <value>,
///     ...
///   }
/// }
/// ```
public enum PreferencesPayloadCodec {
    /// 标识这是 SimpleZip 偏好导出文件 —— 任何其它 JSON 都拒绝。
    /// 也兼顾防止误导入别的 app 的 plist 把 UserDefaults 写乱。
    public static let schema = "SimpleZip.preferences"

    /// 当前 schema 版本。未来字段格式变了再 bump，旧版本走兼容逻辑或直接拒绝。
    public static let supportedVersion = 1

    /// 把一份 raw values 字典包成完整 payload（含 schema / version / 时间戳）。
    public static func makePayload(values: [String: Any], date: Date = Date()) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "schema": schema,
            "version": supportedVersion,
            "exportedAt": formatter.string(from: date),
            "values": values
        ]
    }

    /// 校验输入 payload 并返回里头的 values 字典。
    /// 任何 schema / version / 结构异常都抛 `DecodeError`，让上层提示用户。
    public static func decode(_ payload: [String: Any]) throws -> [String: Any] {
        guard let raw = payload["schema"] as? String else {
            throw DecodeError.missingSchema
        }
        guard raw == schema else {
            throw DecodeError.foreignSchema(raw)
        }
        let version = payload["version"] as? Int ?? 0
        guard version == supportedVersion else {
            throw DecodeError.unsupportedVersion(found: version, supported: supportedVersion)
        }
        guard let values = payload["values"] as? [String: Any] else {
            throw DecodeError.missingValues
        }
        return values
    }

    public enum DecodeError: Error, Equatable {
        /// 没有 `schema` 字段 —— 大概率不是 SimpleZip 的导出文件。
        case missingSchema
        /// schema 字符串不是 SimpleZip 自己的 —— 防止把别的 app 的 plist 导进来。
        case foreignSchema(String)
        /// 版本号不在已知范围 —— 比如未来 v2 文件被 v1 应用读到。
        case unsupportedVersion(found: Int, supported: Int)
        /// `values` 字段缺失或类型错。
        case missingValues
    }
}
