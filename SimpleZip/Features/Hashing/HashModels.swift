//
//  HashModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 用户可以选择只计算需要的哈希算法，避免大文件重复消耗 CPU。
enum HashAlgorithm: String, CaseIterable, Identifiable, Hashable, Codable {
    case crc32 = "CRC32"
    case md5 = "MD5"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// 单个文件的哈希计算结果。
struct FileHashResult: Identifiable, Hashable, Codable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64
    let hashes: [HashAlgorithm: String]

    nonisolated func value(for algorithm: HashAlgorithm) -> String? {
        hashes[algorithm]
    }
}

/// 一次哈希任务的汇总结果，用于弹窗展示。
struct HashReport: Identifiable, Codable {
    let id = UUID()
    let algorithms: [HashAlgorithm]
    let results: [FileHashResult]

    var fileCount: Int {
        results.count
    }

    var totalSize: Int64 {
        results.reduce(0) { $0 + $1.size }
    }

    /// 纯文本表示：每个文件一段「路径 + 各算法哈希行」。供「全部复制」与活动中心详情共用，
    /// 避免哈希结果只在弹窗里、关掉就没了——活动中心能留底、可复制。
    var plainTextSummary: String {
        results.map { result in
            let hashLines = algorithms.compactMap { algorithm -> String? in
                guard let value = result.value(for: algorithm) else { return nil }
                return "\(algorithm.title): \(value)"
            }.joined(separator: "\n")
            return "\(result.url.path)\n\(hashLines)"
        }.joined(separator: "\n\n")
    }
}
