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
        outputObserver: (@Sendable (String) -> Void)? = nil,
        expectedStamp: FileStateStamp? = nil,
        onWaitForLock: (@Sendable () -> Void)? = nil
    ) async throws {
        guard !additions.isEmpty else { return }
        guard supportsEntryUpdate(archiveURL) else {
            throw ArchiveError.commandFailed("This archive format does not support adding or replacing entries.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.commandFailed("Archive no longer exists.")
        }

        // 0.4.3 #2/#3:同包写互斥(排队,等待时上报)+ 外部改动检测。锁内先核对「用户所见版本」,
        // 替换前再核对一次 —— Finder / 其他 App 不走进程内锁,只能靠快照戳兜底。
        await ArchiveWriteLock.shared.acquire(archiveURL, onWait: onWaitForLock)
        defer { ArchiveWriteLock.shared.scheduleRelease(archiveURL) }
        try expectedStamp?.ensureUnchanged(at: archiveURL)
        let preWorkStamp = try FileStateStamp.capture(archiveURL)

        // 0.4.3 #4:空间预检 —— 临时卷要装下「原包副本 + 7zz 重写中间产物 + 新增内容」(~2x 包 + 新增),
        // 目标卷要装下跨卷原子替换的落地拷贝(~1x 包 + 新增)。不足时开工前拦截,而不是写一半神秘失败。
        let additionsBytes = additions.reduce(Int64(0)) { sum, addition in
            sum + ((try? FileStateStamp.capture(addition.sourceFile).size) ?? 0)
        }
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size * 2 + additionsBytes, at: fm.temporaryDirectory)
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size + additionsBytes, at: archiveURL.deletingLastPathComponent())

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
        // 0.4.2 自审：条目名是不可信输入（形如 `-r` 的名字会被当开关）——开关全部放 `--` 之前，
        // 条目名一律 `--` 之后（与解压侧 0.4.1 的加固同口径）。
        arguments.append(contentsOf: ["-y", "-bb1", "-bsp1", "--"])
        arguments.append(contentsOf: relativePaths)
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
        // 替换前最后核对:干活期间原包被外部改过就放弃(否则会覆盖外部改动)。
        try preWorkStamp.ensureUnchanged(at: archiveURL)
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
        ArchiveService.notifyArchiveRewritten(archiveURL)
    }

    /// 安全地从 `archiveURL`(zip/7z)删除若干条目(按归档内相对路径)。同样**绝不原地破坏**:
    /// 复制原包 → 在副本上跑 7zz `d`(delete)→ 原子替换。失败时原包不变。
    public static func deleteEntries(
        from archiveURL: URL,
        entryPaths: [String],
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        expectedStamp: FileStateStamp? = nil,
        onWaitForLock: (@Sendable () -> Void)? = nil
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

        // 0.4.3 #2/#3:同包写互斥 + 外部改动检测(语义见 addOrReplaceEntries)。
        await ArchiveWriteLock.shared.acquire(archiveURL, onWait: onWaitForLock)
        defer { ArchiveWriteLock.shared.scheduleRelease(archiveURL) }
        try expectedStamp?.ensureUnchanged(at: archiveURL)
        let preWorkStamp = try FileStateStamp.capture(archiveURL)

        // 0.4.3 #4:空间预检(语义见 addOrReplaceEntries;本操作无新增内容)。
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size * 2, at: fm.temporaryDirectory)
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size, at: archiveURL.deletingLastPathComponent())

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
        // 0.4.2 自审：条目名（来自归档内,不可信）放 `--` 之后,防 `-r` 之类的名字被当开关。
        arguments.append(contentsOf: ["-y", "-bb1", "-bsp1", "--"])
        arguments.append(contentsOf: normalized)
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        try preWorkStamp.ensureUnchanged(at: archiveURL)
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
        ArchiveService.notifyArchiveRewritten(archiveURL)
    }

    /// 安全地把 `archiveURL`(zip/7z)里的一个条目从 `oldPath` 重命名到 `newPath`。
    /// 复制原包 → 在副本上跑 7zz `rn old new` → 原子替换。失败时原包不变。
    public static func renameEntry(
        in archiveURL: URL,
        from oldPath: String,
        to newPath: String,
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        expectedStamp: FileStateStamp? = nil,
        onWaitForLock: (@Sendable () -> Void)? = nil
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

        // 0.4.3 #2/#3:同包写互斥 + 外部改动检测(语义见 addOrReplaceEntries)。
        await ArchiveWriteLock.shared.acquire(archiveURL, onWait: onWaitForLock)
        defer { ArchiveWriteLock.shared.scheduleRelease(archiveURL) }
        try expectedStamp?.ensureUnchanged(at: archiveURL)
        let preWorkStamp = try FileStateStamp.capture(archiveURL)

        // 0.4.3 #4:空间预检(语义见 addOrReplaceEntries;本操作无新增内容)。
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size * 2, at: fm.temporaryDirectory)
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size, at: archiveURL.deletingLastPathComponent())

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
        // 0.4.2 自审：条目名放 `--` 之后（不可信输入,防被当开关）；开关须在 `--` 之前。
        arguments.append(contentsOf: ["-y", "--", from, to])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        try preWorkStamp.ensureUnchanged(at: archiveURL)
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
        ArchiveService.notifyArchiveRewritten(archiveURL)
    }

    /// 0.4.2 #11：批量重命名 —— 一份工作副本上跑**一次** `7zz rn old1 new1 old2 new2 …`，
    /// 成功后原子替换。任何一对路径非法或 7zz 失败 → 整批不落地、原包字节不变（不会改一半）。
    public static func renameEntries(
        in archiveURL: URL,
        pairs: [(from: String, to: String)],
        password: String = "",
        operationID: UUID? = nil,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        expectedStamp: FileStateStamp? = nil,
        onWaitForLock: (@Sendable () -> Void)? = nil
    ) async throws {
        guard supportsEntryUpdate(archiveURL) else {
            throw ArchiveError.commandFailed("This archive format does not support renaming entries.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw ArchiveError.commandFailed("Archive no longer exists.")
        }
        // 先整批校验（任何一对坏就不开工），并丢掉 from == to 的空操作。
        var normalizedPairs: [(String, String)] = []
        for pair in pairs {
            let from = try normalizedEntryRelativePath(pair.from)
            let to = try normalizedEntryRelativePath(pair.to)
            if from != to { normalizedPairs.append((from, to)) }
        }
        guard !normalizedPairs.isEmpty else { return }

        // 0.4.3 #2/#3:同包写互斥 + 外部改动检测(语义见 addOrReplaceEntries)。
        await ArchiveWriteLock.shared.acquire(archiveURL, onWait: onWaitForLock)
        defer { ArchiveWriteLock.shared.scheduleRelease(archiveURL) }
        try expectedStamp?.ensureUnchanged(at: archiveURL)
        let preWorkStamp = try FileStateStamp.capture(archiveURL)

        // 0.4.3 #4:空间预检(语义见 addOrReplaceEntries;本操作无新增内容)。
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size * 2, at: fm.temporaryDirectory)
        try DiskSpacePreflight.ensure(estimatedBytes: preWorkStamp.size, at: archiveURL.deletingLastPathComponent())

        let staging = fm.temporaryDirectory
            .appendingPathComponent("SimpleZip-EntryRename-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let workCopy = staging.appendingPathComponent("work." + archiveURL.pathExtension)
        try fm.copyItem(at: archiveURL, to: workCopy)

        let tool = try SevenZipBackend.toolPath()
        var arguments = ["rn", workCopy.path]
        if !password.isEmpty {
            arguments.append("-p")   // 口令走 PTY，不进 argv（与单条 rename 同款）。
        }
        // 0.4.2 自审：开关在前、`--` 之后全是条目名（不可信输入,防被当开关）。
        arguments.append(contentsOf: ["-y", "--"])
        for (from, to) in normalizedPairs {
            arguments.append(contentsOf: [from, to])
        }
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            inputStrategy: passwordInputStrategy(password),
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )

        try preWorkStamp.ensureUnchanged(at: archiveURL)
        _ = try fm.replaceItemAt(archiveURL, withItemAt: workCopy)
        ArchiveService.notifyArchiveRewritten(archiveURL)
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

// MARK: - 批量重命名计划（0.4.2 #11）

/// 批量重命名的一种变换。都只作用于条目的**最后一段**（文件名），目录前缀不动。
enum BatchRenameOperation: Equatable {
    case replaceText(find: String, replacement: String)
    case addPrefix(String)
    /// 插在扩展名之前：`report.pdf` + "-final" → `report-final.pdf`。无扩展名直接追加。
    case addSuffix(String)
    case lowercased
    case uppercased
    /// 按序号重命名：`base001.ext / base002.ext …`（保留各自扩展名）。
    case sequence(baseName: String, start: Int, digits: Int)
}

/// 一条计划中的改名。`isConflicting` = 新名与组内另一新名 / 包内未改名的既有条目撞名，
/// 或变换产生了非法文件名（空 / 含路径分隔符）—— 执行时必须排除。
struct BatchRenameChange: Equatable, Identifiable {
    let fromPath: String
    let toPath: String
    let isConflicting: Bool
    var id: String { fromPath }

    var fromLeaf: String { String(fromPath.split(separator: "/").last ?? Substring(fromPath)) }
    var toLeaf: String { String(toPath.split(separator: "/").last ?? Substring(toPath)) }
}

/// 纯名字变换引擎 —— 给预览列表和执行共用，无副作用、可单测。
enum BatchRename {

    /// 对 `paths`（归档内完整路径）套用变换。返回**有变化**的条目（含冲突标记，按输入顺序）。
    /// `allEntryPaths` = 包内全部条目路径，用于检测「撞上没被改名的既有条目」。
    nonisolated static func plan(paths: [String], operation: BatchRenameOperation, allEntryPaths: [String]) -> [BatchRenameChange] {
        let selectedSet = Set(paths)
        // 未参与改名的既有条目 —— 新名撞上它们 = 冲突。
        let untouched = Set(allEntryPaths.filter { !selectedSet.contains($0) })

        var proposals: [(from: String, to: String, invalidName: Bool)] = []
        for (index, path) in paths.enumerated() {
            let directory = path.contains("/") ? String(path[..<path.range(of: "/", options: .backwards)!.upperBound]) : ""
            let leaf = String(path.split(separator: "/").last ?? Substring(path))
            let newLeaf = transform(leaf, operation: operation, index: index)
            guard newLeaf != leaf else { continue }
            // 合法性必须在拼回路径**之前**用变换后的 leaf 判 —— 替换引入的 `/` 拼进路径后就看不出来了。
            let invalidName = newLeaf.isEmpty || newLeaf.contains("/") || newLeaf.contains("\\")
                || newLeaf == "." || newLeaf == ".."
            proposals.append((from: path, to: directory + newLeaf, invalidName: invalidName))
        }

        // 组内新名出现次数（>1 = 互撞）。
        var newPathCounts: [String: Int] = [:]
        for proposal in proposals { newPathCounts[proposal.to, default: 0] += 1 }

        return proposals.map { proposal in
            let collides = (newPathCounts[proposal.to] ?? 0) > 1 || untouched.contains(proposal.to)
            return BatchRenameChange(fromPath: proposal.from, toPath: proposal.to, isConflicting: proposal.invalidName || collides)
        }
    }

    nonisolated private static func transform(_ leaf: String, operation: BatchRenameOperation, index: Int) -> String {
        switch operation {
        case .replaceText(let find, let replacement):
            guard !find.isEmpty else { return leaf }
            return leaf.replacingOccurrences(of: find, with: replacement)
        case .addPrefix(let prefix):
            return prefix + leaf
        case .addSuffix(let suffix):
            guard !suffix.isEmpty else { return leaf }
            let ext = (leaf as NSString).pathExtension
            let stem = (leaf as NSString).deletingPathExtension
            return ext.isEmpty ? leaf + suffix : "\(stem)\(suffix).\(ext)"
        case .lowercased:
            return leaf.lowercased()
        case .uppercased:
            return leaf.uppercased()
        case .sequence(let baseName, let start, let digits):
            guard !baseName.isEmpty else { return leaf }
            let number = String(format: "%0\(max(1, digits))d", start + index)
            let ext = (leaf as NSString).pathExtension
            return ext.isEmpty ? baseName + number : "\(baseName)\(number).\(ext)"
        }
    }
}
