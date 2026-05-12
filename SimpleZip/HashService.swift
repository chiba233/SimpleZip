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
        try calculateFileHash(for: url).sha256
    }

    nonisolated static func calculate(for urls: [URL], includeHiddenFiles: Bool) async throws -> HashReport {
        try await Task.detached(priority: .userInitiated) {
            let fileURLs = try collectFiles(from: urls, includeHiddenFiles: includeHiddenFiles)
            guard !fileURLs.isEmpty else {
                throw ArchiveError.commandFailed(L10n.text("error.selectFilesForHash"))
            }

            let results = try fileURLs.map { url in
                try calculateFileHash(for: url)
            }
            return HashReport(results: results)
        }.value
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

    private nonisolated static func calculateFileHash(for url: URL) throws -> FileHashResult {
        let chunkSize = 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var crc32 = CRC32()
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()
        var totalSize: Int64 = 0

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            totalSize += Int64(data.count)
            crc32.update(data)
            md5.update(data: data)
            sha1.update(data: data)
            sha256.update(data: data)
            sha512.update(data: data)
        }

        return FileHashResult(
            url: url,
            displayName: url.lastPathComponent,
            size: totalSize,
            crc32: crc32.finalize(),
            md5: hex(md5.finalize()),
            sha1: hex(sha1.finalize()),
            sha256: hex(sha256.finalize()),
            sha512: hex(sha512.finalize())
        )
    }

    private nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// CRC32 的增量计算实现，对齐 7-Zip 常见的 CRC 列。
private struct CRC32 {
    private nonisolated static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    private var value: UInt32 = 0xFFFFFFFF

    nonisolated init() {}

    nonisolated mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xFF)
            value = (value >> 8) ^ Self.table[index]
        }
    }

    nonisolated func finalize() -> String {
        String(format: "%08x", value ^ 0xFFFFFFFF)
    }
}
