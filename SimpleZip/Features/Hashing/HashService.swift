//
//  HashService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import CryptoKit
import Foundation

/// 文件哈希服务：以流式方式读取文件，避免大文件一次性占用过多内存。
enum HashService {
    nonisolated static func sha256(for url: URL) throws -> String {
        let result = try calculateFileHash(for: url, algorithms: [.sha256])
        return result.hashes[.sha256] ?? ""
    }

    nonisolated static func calculate(for urls: [URL], includeHiddenFiles: Bool, algorithms: [HashAlgorithm] = HashAlgorithm.allCases) async throws -> HashReport {
        // CPU 密集，放 detached task 不阻塞调用方（主 actor）。detached task **不**继承父任务取消，
        // 所以用 withTaskCancellationHandler 在外层被取消时显式 cancel 这个 work，
        // 内部的 Task.checkCancellation() 据此中断 —— 让底部状态栏的「取消」对哈希真正生效。
        let work = Task.detached(priority: .userInitiated) {
            let fileURLs = try collectFiles(from: urls, includeHiddenFiles: includeHiddenFiles)
            guard !fileURLs.isEmpty else {
                throw ArchiveError.commandFailed(L10n.text("error.selectFilesForHash"))
            }

            let selectedAlgorithms = algorithms.isEmpty ? HashAlgorithm.allCases : algorithms
            // 多文件:跨核并行哈希(每个文件是纯 CPU、硬件 crypto 的独立工作,不 spawn 进程、无共享可变状态)。
            // 并发上限 = 性能核数:既吃满多核,又把同时打开的文件句柄数限在核数级别,避免几百文件一次性
            // 打开撞进程 FD 上限。结果按原始(已排序)下标回填,SHA256SUMS 等输出顺序与串行版一致。
            let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let indexed = try await withThrowingTaskGroup(of: (Int, FileHashResult).self) { group -> [(Int, FileHashResult)] in
                var collected: [(Int, FileHashResult)] = []
                collected.reserveCapacity(fileURLs.count)
                var next = 0
                func submit(_ idx: Int) {
                    let url = fileURLs[idx]
                    group.addTask {
                        try Task.checkCancellation()
                        return (idx, try calculateFileHash(for: url, algorithms: selectedAlgorithms))
                    }
                }
                while next < min(limit, fileURLs.count) { submit(next); next += 1 }
                while let finished = try await group.next() {
                    collected.append(finished)
                    if next < fileURLs.count { submit(next); next += 1 }
                }
                return collected
            }
            let results = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
            return HashReport(algorithms: selectedAlgorithms, results: results)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// 展开用户选择的文件夹，计算其中所有普通文件。
    private nonisolated static func collectFiles(from urls: [URL], includeHiddenFiles: Bool) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        var collected: [URL] = []

        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true {
                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !includeHiddenFiles {
                    options.insert(.skipsHiddenFiles)
                }

                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: options
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    let childValues = try fileURL.resourceValues(forKeys: resourceKeys)
                    if childValues.isRegularFile == true {
                        collected.append(fileURL)
                    }
                }
            } else if values.isRegularFile == true {
                if includeHiddenFiles || values.isHidden != true {
                    collected.append(url)
                }
            }
        }

        return collected.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private nonisolated static func calculateFileHash(for url: URL, algorithms: [HashAlgorithm]) throws -> FileHashResult {
        let chunkSize = 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let algorithmSet = Set(algorithms)
        var crc32 = algorithmSet.contains(.crc32) ? CRC32() : nil
        var md5 = algorithmSet.contains(.md5) ? Insecure.MD5() : nil
        var sha1 = algorithmSet.contains(.sha1) ? Insecure.SHA1() : nil
        var sha256 = algorithmSet.contains(.sha256) ? SHA256() : nil
        var sha512 = algorithmSet.contains(.sha512) ? SHA512() : nil
        var totalSize: Int64 = 0

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            try Task.checkCancellation() // 大文件分块途中也能及时响应取消
            totalSize += Int64(data.count)
            crc32?.update(data)
            md5?.update(data: data)
            sha1?.update(data: data)
            sha256?.update(data: data)
            sha512?.update(data: data)
        }

        var hashes: [HashAlgorithm: String] = [:]
        if let crc32 {
            hashes[.crc32] = crc32.finalize()
        }
        if let md5 {
            hashes[.md5] = hex(md5.finalize())
        }
        if let sha1 {
            hashes[.sha1] = hex(sha1.finalize())
        }
        if let sha256 {
            hashes[.sha256] = hex(sha256.finalize())
        }
        if let sha512 {
            hashes[.sha512] = hex(sha512.finalize())
        }

        return FileHashResult(
            url: url,
            displayName: url.lastPathComponent,
            size: totalSize,
            hashes: hashes
        )
    }

    /// digest 字节序列转 hex 小写字符串。internal 让同 target 复用（如 ArchiveExtractionCoordinator 的 manifest 哈希）。
    nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// CRC32 的增量计算实现，对齐 7-Zip 常见的 CRC 列。
///
/// 用 slice-by-8：每轮吃 8 字节、查 8 张表，互相独立的查表能被 CPU 流水并行，
/// 配合按字读取，比逐字节 slice-by-1 快 ~2-4×（CRC32 在默认算法集里，多 GB 文件受益）。
/// 纯可移植 Swift，不依赖任何架构 intrinsic —— arm64 与 x86_64 通用二进制走同一份代码。
/// 已用标准向量 `"123456789"→0xCBF43926`、随机模糊与任意块边界的流式对拍验证与原 slice-by-1 字节级一致。
private struct CRC32 {
    /// slice-by-8 的 8 张表。`tables[0]` 是标准 CRC32 表（`0xEDB88320` 反射多项式），
    /// `tables[k][i] = (tables[k-1][i] >> 8) ^ tables[0][tables[k-1][i] & 0xFF]`，一次性构建。
    private nonisolated static let tables: [[UInt32]] = {
        var t0 = [UInt32](repeating: 0, count: 256)
        for value in 0..<256 {
            var crc = UInt32(value)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            t0[value] = crc
        }
        var all: [[UInt32]] = [t0]
        for k in 1..<8 {
            let prev = all[k - 1]
            var next = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                next[i] = (prev[i] >> 8) ^ t0[Int(prev[i] & 0xFF)]
            }
            all.append(next)
        }
        return all
    }()

    private var value: UInt32 = 0xFFFFFFFF

    nonisolated init() {}

    nonisolated mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        let tables = Self.tables
        let t0 = tables[0], t1 = tables[1], t2 = tables[2], t3 = tables[3]
        let t4 = tables[4], t5 = tables[5], t6 = tables[6], t7 = tables[7]
        var crc = value
        data.withUnsafeBytes { raw in
            let n = raw.count
            var i = 0
            // 主循环：每轮 8 字节。macOS 仅小端（arm64/x86_64 皆是），`loadUnaligned` 按主机字节序读、
            // `UInt32(littleEndian:)` 在小端上是恒等（零成本）、对大端仍正确，故跨架构安全。
            while n - i >= 8 {
                let one = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)) ^ crc
                let two = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self))
                crc = t7[Int(one & 0xFF)]
                    ^ t6[Int((one >> 8) & 0xFF)]
                    ^ t5[Int((one >> 16) & 0xFF)]
                    ^ t4[Int((one >> 24) & 0xFF)]
                    ^ t3[Int(two & 0xFF)]
                    ^ t2[Int((two >> 8) & 0xFF)]
                    ^ t1[Int((two >> 16) & 0xFF)]
                    ^ t0[Int((two >> 24) & 0xFF)]
                i += 8
            }
            // 尾部不足 8 字节：退回 slice-by-1（`tables[0]` 即标准表）。
            while i < n {
                crc = (crc >> 8) ^ t0[Int((crc ^ UInt32(raw[i])) & 0xFF)]
                i += 1
            }
        }
        value = crc
    }

    nonisolated func finalize() -> String {
        String(format: "%08x", value ^ 0xFFFFFFFF)
    }
}
