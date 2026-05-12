//
//  HashModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 用户可以选择只计算需要的哈希算法，避免大文件重复消耗 CPU。
enum HashAlgorithm: String, CaseIterable, Identifiable, Hashable {
    case crc32 = "CRC32"
    case md5 = "MD5"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// 单个文件的哈希计算结果。
struct FileHashResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64
    let hashes: [HashAlgorithm: String]

    func value(for algorithm: HashAlgorithm) -> String? {
        hashes[algorithm]
    }
}

/// 一次哈希任务的汇总结果，用于弹窗展示。
struct HashReport: Identifiable {
    let id = UUID()
    let algorithms: [HashAlgorithm]
    let results: [FileHashResult]

    var fileCount: Int {
        results.count
    }

    var totalSize: Int64 {
        results.reduce(0) { $0 + $1.size }
    }
}
