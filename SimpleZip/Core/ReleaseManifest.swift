//
//  ReleaseManifest.swift
//  SimpleZip
//
//  0.4.4 #4:机器可读的发布清单(release-manifest.json)。CI / 下载方脚本可直接解析:
//  产物名 / 版本 / SHA-256 / 大小 / 结构指纹 / 生成工具。
//  确定性编码(sortedKeys + prettyPrinted + ISO8601,SZSArchive.encodeManifest 同款口径)——
//  同一输入编两次逐字节一致,可单测。字段名固定英文(交换格式不跟 UI 语言走)。
//

import Foundation

nonisolated struct ReleaseManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        /// 产物文件名(不含目录 —— 清单与产物同目录,相对引用)。
        let name: String
        let sha256: String?
        let sizeBytes: Int64?
        /// 结构指纹(#9):重新打包不变,标识「同一份内容」。
        let structuralFingerprint: String?
    }

    /// 清单格式版本(将来字段演进用)。
    let manifestVersion: Int
    /// 发布名(通常 = 归档主名)。
    let name: String
    /// 版本标签(发布助手的可选字段;没填则 nil)。
    let version: String?
    let generatedBy: String
    /// ISO8601(UTC)。
    let generatedAt: String
    let files: [File]

    init(
        name: String,
        version: String?,
        generatedBy: String,
        generatedAt: Date,
        files: [File]
    ) {
        self.manifestVersion = 1
        self.name = name
        self.version = version
        self.generatedBy = generatedBy
        // 现场建 formatter:ISO8601DateFormatter 非 Sendable,不能挂 static(并发检查);构造开销可忽略。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        self.generatedAt = formatter.string(from: generatedAt)
        self.files = files
    }

    /// 确定性 JSON(同一输入逐字节一致)。
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
