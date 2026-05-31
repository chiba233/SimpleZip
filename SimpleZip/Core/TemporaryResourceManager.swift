//
//  TemporaryResourceManager.swift
//  SimpleZip
//
//  Created by OpenAI on 2026/05/18.
//

import Foundation

enum TemporaryResourceManager {
    static let openedArchiveItemsDirectoryName = "SimpleZipArchiveOpen"

    static func openedArchiveItemsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(openedArchiveItemsDirectoryName, isDirectory: true)
    }

    static func cleanStaleOpenedArchiveItems(fileManager: FileManager = .default) {
        let root = openedArchiveItemsRoot(fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    static func makeOpenedArchiveItemDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = openedArchiveItemsRoot(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 手动清理临时文件（设置 → 运行状态）

    /// 所有 SimpleZip 自己产生的临时目录 / 文件都用这个前缀（A7 约定：scratch 目录命名 `SimpleZip...`）。
    /// 覆盖：打开压缩包的解压目录 `SimpleZipArchiveOpen`、`.szs` 创建 staging `SimpleZip-SZS-Create-*`、
    /// `.siz` wrap/unwrap staging 等。只删名字以此前缀开头的条目，绝不碰系统临时目录里别的东西。
    nonisolated static let temporaryArtifactPrefix = "SimpleZip"

    /// 列出系统临时目录里所有 SimpleZip 临时条目。`baseDirectory` 仅供单测注入隔离目录用，
    /// 生产代码走默认的 `fileManager.temporaryDirectory`。
    nonisolated static func temporaryArtifactURLs(
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        let base = baseDirectory ?? fileManager.temporaryDirectory
        let entries = (try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(temporaryArtifactPrefix) }
    }

    /// 这些临时条目占用的总字节数（按实际磁盘分配大小累加）。可能涉及递归遍历，建议在后台线程调用。
    nonisolated static func temporaryArtifactsByteSize(
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int64 {
        temporaryArtifactURLs(in: baseDirectory, fileManager: fileManager)
            .reduce(0) { $0 + allocatedSize(of: $1, fileManager: fileManager) }
    }

    /// 删除所有 SimpleZip 临时条目，返回释放的字节数。建议在后台线程调用。
    @discardableResult
    nonisolated static func clearTemporaryArtifacts(
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int64 {
        var freed: Int64 = 0
        for url in temporaryArtifactURLs(in: baseDirectory, fileManager: fileManager) {
            freed += allocatedSize(of: url, fileManager: fileManager)
            try? fileManager.removeItem(at: url)
        }
        return freed
    }

    /// 单文件取磁盘分配大小；目录则递归累加。拿不到大小的条目按 0 计。
    nonisolated private static func allocatedSize(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

        func sizeOfFile(_ fileURL: URL) -> Int64 {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { return sizeOfFile(url) }

        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let child as URL in enumerator {
                let childIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !childIsDirectory {
                    total += sizeOfFile(child)
                }
            }
        }
        return total
    }
}
