//
//  HashModels.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 单个文件的哈希计算结果。
struct FileHashResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64
    let crc32: String
    let md5: String
    let sha1: String
    let sha256: String
    let sha512: String
}

/// 一次哈希任务的汇总结果，用于弹窗展示。
struct HashReport: Identifiable {
    let id = UUID()
    let results: [FileHashResult]

    var fileCount: Int {
        results.count
    }

    var totalSize: Int64 {
        results.reduce(0) { $0 + $1.size }
    }
}
