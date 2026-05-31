//
//  TemporaryResourceManager.swift
//  SimpleZip
//
//  Created by OpenAI on 2026/05/18.
//

import Foundation

enum TemporaryResourceManager {
    nonisolated static let openedArchiveItemsDirectoryName = "SimpleZipArchiveOpen"

    // 纯路径计算 / 文件操作，无 UI 状态 —— 标 nonisolated，以便 nonisolated 的 cleanStaleOpenedArchiveItems
    // 和后台 Task 调用（app target 的 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor 否则会把它们推成 MainActor）。
    nonisolated static func openedArchiveItemsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(openedArchiveItemsDirectoryName, isDirectory: true)
    }

    /// 清理「打开压缩包内文件」遗留的解压子目录 —— 只删 mtime **早于** `reference` 的（即上次会话残留、
    /// 当前不在用的），逐个 UUID 子目录判断。绝不再无条件删整个 `SimpleZipArchiveOpen` 根：
    /// 那样一旦有第二个窗口 / 第二个 `ArchiveBrowserModel` 正在用某个子目录，就会被连根删掉（在用文件丢失）。
    /// 应在 App 启动时**单次**调用（AppDelegate），而不是每个 model.init —— 模型不该拥有清理全 app 临时目录的权力。
    /// 拿不到 mtime 的子项按「不陈旧」处理（保守不删）。
    nonisolated static func cleanStaleOpenedArchiveItems(
        olderThan reference: Date,
        fileManager: FileManager = .default
    ) {
        let root = openedArchiveItemsRoot(fileManager: fileManager)
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        for entry in entries {
            guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime < reference else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    nonisolated static func makeOpenedArchiveItemDirectory(fileManager: FileManager = .default) throws -> URL {
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

    /// 本次 App 会话的启动时间。手动清理只删 mtime **早于**这个时间的临时项 ——
    /// 这样本次会话产生的（很可能正在用的：当前打开的档案解压目录、进行中的 .siz/.szs staging）绝不会被删。
    /// `static let` 惰性初始化一次；AppDelegate 在启动时 touch 一下确保它落在「会话开始」而不是「点清理那一刻」。
    nonisolated static let sessionStart = Date()

    /// 列出系统临时目录里所有 SimpleZip 临时条目。`baseDirectory` 仅供单测注入隔离目录用。
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

    /// 「陈旧」临时条目 = mtime 早于 `reference` 的（即非本次会话产生、当前不在用的）。
    /// 拿不到 mtime 的条目按「不陈旧」处理（不删，保守）。
    nonisolated static func staleTemporaryArtifactURLs(
        olderThan reference: Date,
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        temporaryArtifactURLs(in: baseDirectory, fileManager: fileManager).filter { url in
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return false
            }
            return mtime < reference
        }
    }

    /// 陈旧临时条目占用的总字节数（按实际磁盘分配大小累加）。可能递归遍历，建议在后台线程调用。
    nonisolated static func temporaryArtifactsByteSize(
        olderThan reference: Date,
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int64 {
        staleTemporaryArtifactURLs(olderThan: reference, in: baseDirectory, fileManager: fileManager)
            .reduce(0) { $0 + allocatedSize(of: $1, fileManager: fileManager) }
    }

    /// 只删**陈旧**临时条目（mtime < reference），返回释放的字节数。本次会话的在用 staging 不会被碰。建议后台调用。
    @discardableResult
    nonisolated static func clearTemporaryArtifacts(
        olderThan reference: Date,
        in baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int64 {
        var freed: Int64 = 0
        for url in staleTemporaryArtifactURLs(olderThan: reference, in: baseDirectory, fileManager: fileManager) {
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
