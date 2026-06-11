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
    /// 归档编辑（add/delete/rename）的口令输入策略：空口令 → 不喂 stdin；非空 → PTY 提示后灌口令。
    /// header-encrypted 7z 更新时有的 7zz 版本会依次提示「旧包口令 + 新口令 + 确认新口令」；
    /// 多余响应不会被消费（responder 按提示出现次数逐个取），不足才会抛 passwordPromptExhausted。
    private static func passwordInputStrategy(_ password: String) -> ProcessInputStrategy {
        password.isEmpty ? .none : .passwordPrompts(Array(repeating: password, count: 4))
    }

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
            // 安全（审计 P1，口令暴露）：不把口令拼进 argv（`ps -ww` 可见）。
            // 改用裸 `-p` 让 7zz 在 PTY 上提示,口令经 stdin 灌入（跟 list/extract 同款）。
            arguments.append("-p")
        }
        arguments.append(contentsOf: relativePaths)
        arguments.append(contentsOf: ["-y", "-bb1", "-bsp1"])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: payloadRoot,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        // 4) 工作副本现在是「更新后的归档」→ 原子替换原包。失败前原包始终是旧的完整包。
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
    }

    /// 安全地从 `archiveURL`(zip/7z)删除若干条目(按归档内相对路径)。同样**绝不原地破坏**:
    /// 复制原包 → 在副本上跑 7zz `d`(delete)→ 原子替换。失败时原包不变。
    public static func deleteEntries(
        from archiveURL: URL,
        entryPaths: [String],
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard !entryPaths.isEmpty else { return }
        guard supportsEntryUpdate(archiveURL) else {
            throw ArchiveError.commandFailed("This archive format does not support deleting entries.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.commandFailed("Archive no longer exists.")
        }
        let normalized = try entryPaths.map { try normalizedEntryRelativePath($0) }

        let staging = fm.temporaryDirectory
            .appendingPathComponent("SimpleZip-EntryDelete-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let workCopy = staging.appendingPathComponent("work." + archiveURL.pathExtension)
        try fm.copyItem(at: archiveURL, to: workCopy)

        let tool = try SevenZipBackend.toolPath()
        var arguments = ["d", workCopy.path]
        if !password.isEmpty {
            // 安全（审计 P1，口令暴露）：不把口令拼进 argv（`ps -ww` 可见）。
            // 改用裸 `-p` 让 7zz 在 PTY 上提示,口令经 stdin 灌入（跟 list/extract 同款）。
            arguments.append("-p")
        }
        arguments.append(contentsOf: normalized)
        arguments.append(contentsOf: ["-y", "-bb1", "-bsp1"])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
    }

    /// 安全地把 `archiveURL`(zip/7z)里的一个条目从 `oldPath` 重命名到 `newPath`。
    /// 复制原包 → 在副本上跑 7zz `rn old new` → 原子替换。失败时原包不变。
    public static func renameEntry(
        in archiveURL: URL,
        from oldPath: String,
        to newPath: String,
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard supportsEntryUpdate(archiveURL) else {
            throw ArchiveError.commandFailed("This archive format does not support renaming entries.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.commandFailed("Archive no longer exists.")
        }
        let from = try normalizedEntryRelativePath(oldPath)
        let to = try normalizedEntryRelativePath(newPath)
        guard from != to else { return }

        let staging = fm.temporaryDirectory
            .appendingPathComponent("SimpleZip-EntryRename-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let workCopy = staging.appendingPathComponent("work." + archiveURL.pathExtension)
        try fm.copyItem(at: archiveURL, to: workCopy)

        let tool = try SevenZipBackend.toolPath()
        var arguments = ["rn", workCopy.path]
        if !password.isEmpty {
            // 安全（审计 P1，口令暴露）：不把口令拼进 argv（`ps -ww` 可见）。
            // 改用裸 `-p` 让 7zz 在 PTY 上提示,口令经 stdin 灌入（跟 list/extract 同款）。
            arguments.append("-p")
        }
        arguments.append(contentsOf: [from, to, "-y"])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
    }

    /// 归档内相对路径校验 / 规范化 —— 拒绝绝对路径、`..` 逃逸、空段,防止 staging 时写到 payload 之外
    /// 或在归档里塞出诡异路径。返回用 `/` 连接的干净相对路径。
    ///
    /// **跨平台路径逃逸面(archive safety)**:macOS 本机只把 `/` 当分隔符,但归档条目会被喂给 7zz / 别的
    /// 解压器,在 **Windows 语义**下 `\` 是路径分隔、`C:` 是盘符、`\\server\share` 是 UNC —— 这些若作为
    /// 「普通单段路径」放进包里,在 Windows 解压时就会写到目标目录之外。所以一律拒绝(绝不静默改写,符合
    /// CLAUDE.md「不静默破坏 / 不隐藏失败」):
    /// - 含反斜杠 `\`(Windows 分隔 / UNC) → 拒绝;
    /// - 任一段是 `..` / `.`(`/` 分隔的逃逸) → 拒绝;
    /// - 任一段形如盘符 `C:` / `C:foo`(字母 + 冒号开头) → 拒绝。
    static func normalizedEntryRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\") else {
            throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
        }
        var components: [String] = []
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(segment)
            guard part != "..", part != ".", !isWindowsDriveComponent(part) else {
                throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
            }
            components.append(part)
        }
        guard !components.isEmpty else {
            throw ArchiveError.commandFailed("Invalid entry path: \(raw)")
        }
        return components.joined(separator: "/")
    }

    /// 某段是否是 Windows 盘符语义(`C:` / `c:` / `C:foo`)—— 字母开头紧跟冒号。这类段在 Windows 解压器
    /// 会被当作「切换到 C 盘根」,属逃逸面,拒绝。`:` 在 macOS 文件名里本就非法(legacy 路径分隔符),不误伤本机名。
    private static func isWindowsDriveComponent(_ part: String) -> Bool {
        let chars = Array(part)
        guard chars.count >= 2 else { return false }
        return chars[0].isLetter && chars[1] == ":"
    }
}
