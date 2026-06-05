//
//  ArchiveEntryUpdate.swift
//  SimpleZip
//
//  「往已存在的压缩包里加 / 替换条目」的**数据安全核心**——拖入文件、归档内编辑写回 共用这一份。
//
//  铁律(CLAUDE.md 反复强调档案数据安全、不静默破坏用户数据):
//  **绝不原地改原包**。复制原包 → 在副本上跑 7zz `a`(add/update)→ 成功后**原子替换**原包。
//  任何一步失败,原包**一个字节都不动**(我们只写过临时副本)。
//

import Foundation

/// 要加入 / 替换进归档的一个条目:磁盘上的真实文件 + 它在归档内的目标相对路径。
public struct ArchiveEntryAddition: Hashable {
    /// 磁盘上的源文件(拖入的文件 / 加密临时卷里编辑过的副本)。
    public let sourceFile: URL
    /// 归档内的目标相对路径(如 `docs/a.txt`);同名条目存在则被替换(7zz `a` 的 update 语义)。
    public let entryPath: String

    public init(sourceFile: URL, entryPath: String) {
        self.sourceFile = sourceFile
        self.entryPath = entryPath
    }
}

extension ArchiveService {
    /// 一个归档是否可被 SimpleZip 安全地「加 / 替换条目」—— 仅 **zip / 7z**(7zz 可写)且 7zz 可用。
    /// TAR 系 / DMG / RAR(7zz 不可写)/ GPG 容器 都不开放(返回 false),调用方据此决定是否给「拖入 / 写回」入口。
    public static func supportsEntryUpdate(_ archiveURL: URL) -> Bool {
        guard SevenZipBackend.isAvailable() else { return false }
        switch archiveURL.pathExtension.lowercased() {
        case "zip", "7z":
            return true
        default:
            return false
        }
    }

    /// 安全地把 `additions` 加入 / 替换进 `archiveURL`(zip/7z)。详见文件头铁律。
    ///
    /// - `password`:打开 / 加密用。空 = 不加密新条目(适合未加密归档);非空 = 用它打开 header-encrypted 7z
    ///   并对新条目加密(适合加密归档,跟原包口令一致)。
    /// - 抛错时原包不变(只动了临时副本);成功后原子替换。
    public static func addOrReplaceEntries(
        in archiveURL: URL,
        additions: [ArchiveEntryAddition],
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard !additions.isEmpty else { return }
        guard supportsEntryUpdate(archiveURL) else {
            throw ArchiveError.commandFailed("This archive format does not support adding or replacing entries.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.commandFailed("Archive no longer exists.")
        }

        // 全程在系统临时目录的隔离子目录里干活,结束即清(成功 / 失败都清)。
        let staging = fm.temporaryDirectory
            .appendingPathComponent("SimpleZip-EntryUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1) 复制原包到工作副本(原包从此刻起绝不被本流程触碰)。
        let workCopy = staging.appendingPathComponent("work." + archiveURL.pathExtension)
        try fm.copyItem(at: archiveURL, to: workCopy)

        // 2) 把每个源文件摆到 payload 根下的目标相对路径(7zz 以 payload 为 cwd,相对路径即归档内路径)。
        let payloadRoot = staging.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        var relativePaths: [String] = []
        for addition in additions {
            let normalized = try normalizedEntryRelativePath(addition.entryPath)
            let dest = payloadRoot.appendingPathComponent(normalized)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: addition.sourceFile, to: dest)
            relativePaths.append(normalized)
        }

        // 3) 在**工作副本**上跑 7zz add/update。`a` 对已存在的同名条目执行替换、新条目执行新增。
        let tool = try SevenZipBackend.toolPath()
        var arguments = ["a", workCopy.path]
        if !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(contentsOf: relativePaths)
        arguments.append(contentsOf: ["-y", "-bb1", "-bsp1"])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: payloadRoot,
            inputStrategy: .none,
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        // 4) 工作副本现在是「更新后的归档」→ 原子替换原包。失败前原包始终是旧的完整包。
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
    }

    /// 归档内相对路径校验 / 规范化 —— 拒绝绝对路径、`..` 逃逸、空段,防止 staging 时写到 payload 之外
    /// 或在归档里塞出诡异路径。返回用 `/` 连接的干净相对路径。
    static func normalizedEntryRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
        }
        var components: [String] = []
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(segment)
            guard part != "..", part != "." else {
                throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
            }
            components.append(part)
        }
        guard !components.isEmpty else {
            throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
        }
        return components.joined(separator: "/")
    }
}
