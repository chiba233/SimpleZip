//
//  ArchiveSafety.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/18.
//

import CryptoKit
import Foundation

enum ArchiveSafety {
    nonisolated static func validateForExtraction(_ items: [ArchiveItem]) throws {
        try validateEntryNames(items.map(\.name))
    }

    nonisolated static func validateEntryNames(_ names: [String]) throws {
        let unsafeNames = unsafeEntryNames(in: names)
        guard unsafeNames.isEmpty else {
            throw ArchiveError.unsafeArchiveEntries(Array(unsafeNames.prefix(5)))
        }
    }

    nonisolated static func unsafeEntryNames(in items: [ArchiveItem]) -> [String] {
        unsafeEntryNames(in: items.map(\.name))
    }

    nonisolated static func unsafeEntryNames(in names: [String]) -> [String] {
        names.filter(isUnsafeEntryName)
    }

    nonisolated static func isUnsafeEntryName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return true }
        if trimmedName.hasPrefix("/") || trimmedName.hasPrefix("\\") || trimmedName.hasPrefix("~") {
            return true
        }
        if trimmedName.hasPrefix("//") || trimmedName.hasPrefix("\\\\") {
            return true
        }
        if trimmedName.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return true
        }

        let normalizedSeparators = trimmedName.replacingOccurrences(of: "\\", with: "/")
        return normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    nonisolated static func validateExtractedTree(at root: URL, fileManager: FileManager = .default) throws {
        let unsafeLinks = try unsafeLinks(in: root, fileManager: fileManager)
        guard unsafeLinks.isEmpty else {
            throw ArchiveError.unsafeArchiveLinks(Array(unsafeLinks.prefix(5)))
        }
    }

    nonisolated static func unsafeLinks(in root: URL, fileManager: FileManager = .default) throws -> [String] {
        var links: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath == rootPath || standardizedPath.hasPrefix(rootPath + "/") else {
                throw ArchiveError.unsafeArchiveEntries([url.path])
            }

            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                links.append(url.lastPathComponent)
            }
        }
        return links
    }

    nonisolated static func requiresExternalOpenConfirmation(_ item: ArchiveItem) -> Bool {
        guard !item.isDirectory else { return true }
        let trimmedName = item.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let displayName = trimmedName.split(separator: "/").last.map(String.init) ?? item.name
        let ext = URL(fileURLWithPath: displayName).pathExtension.lowercased()
        let riskyExtensions: Set<String> = [
            "app", "pkg", "mpkg", "dmg", "command", "tool", "sh", "bash", "zsh",
            "scpt", "applescript", "terminal", "workflow", "js", "html", "htm"
        ]
        return riskyExtensions.contains(ext)
    }
}

// MARK: - 路径安全报告（0.4.2 #7）

/// 报告级安全发现的类别。比 `isUnsafeEntryName` 的硬拦截更宽：这里是**告知**，
/// 不改变任何拦截行为 —— 解压 / 打开时的既有安全确认照旧。rawValue 拼 L10n key。
enum ArchiveSecurityFindingKind: String, CaseIterable {
    case absolutePath        // `/` 或 `~` 开头 —— 解出来可能落到任意位置
    case parentTraversal     // `..` 上跳段
    case windowsDrivePath    // `C:\` 盘符
    case uncPath             // `\\server` / `//server` 网络共享
    case backslashPath       // 含反斜杠（Windows 分隔，解出来文件名怪异 / 混淆视线）
    case controlCharacters   // 控制字符 / Unicode 双向覆盖（终端与文件名混淆）
    case overlongPath        // 路径超长（整条 >1024 字节或单段 >255 字节）
    case setuidExecutable    // setuid / setgid 权限位
    case externalSymlink     // 符号链接指向归档外（绝对路径 / `..`）
    case caseCollision       // 大小写不同的重名 —— 大小写不敏感卷上互相覆盖
    // 0.4.3 #14:跨平台文件名风险(Windows/Linux 来的 zip 在 macOS 上的经典雷区,反之亦然)。
    case normalizationCollision // NFC/NFD 字节不同但显示相同 —— 跨平台解出两个「同名」文件或互覆
    case windowsReservedName    // CON / NUL / PRN / COM1… —— Windows 上无法创建,解压直接失败
    case trailingSpaceOrDot     // 段尾空格 / 点 —— Windows 会剥掉,造成改名或冲突
}

struct ArchiveSecurityFinding: Equatable, Identifiable {
    let kind: ArchiveSecurityFindingKind
    /// 命中的条目（externalSymlink 形如 `name → target`，caseCollision 形如 `a ↔ A`）。
    let entryPaths: [String]
    var id: String { kind.rawValue }
}

/// 打开归档时的静态路径分析。纯函数、只读条目元数据，不碰文件系统。
enum ArchiveSecurityReport {

    nonisolated static func analyze(_ items: [ArchiveItem]) -> [ArchiveSecurityFinding] {
        var byKind: [ArchiveSecurityFindingKind: [String]] = [:]
        func record(_ kind: ArchiveSecurityFindingKind, _ path: String) {
            byKind[kind, default: []].append(path)
        }
        // 大小写冲突：lower(归一路径) → 首次出现的原文。再次出现且原文不同 = 冲突。
        var firstSpellingByLowercased: [String: String] = [:]

        for item in items {
            let name = item.name
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { record(.absolutePath, name) }
            let separatorNormalized = trimmed.replacingOccurrences(of: "\\", with: "/")
            if separatorNormalized.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                record(.parentTraversal, name)
            }
            if trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
                record(.windowsDrivePath, name)
            }
            if trimmed.hasPrefix("\\\\") || trimmed.hasPrefix("//") {
                record(.uncPath, name)
            } else if trimmed.contains("\\") {
                record(.backslashPath, name)
            }
            if name.unicodeScalars.contains(where: isSuspiciousScalar) { record(.controlCharacters, name) }
            if isOverlongPath(trimmed) { record(.overlongPath, name) }
            // 0.4.3 #14:Windows 保留名 / 段尾空格点 —— 按段检查(目录段同样致命)。
            for segment in trimmed.split(separator: "/") {
                if isWindowsReservedName(String(segment)) {
                    record(.windowsReservedName, name)
                    break
                }
            }
            for segment in trimmed.split(separator: "/") {
                if segment.hasSuffix(" ") || segment.hasSuffix(".") {
                    record(.trailingSpaceOrDot, name)
                    break
                }
            }
            if hasSetuidMode(item.attributes) { record(.setuidExecutable, name) }
            if !item.symlinkTarget.isEmpty, isExternalLinkTarget(item.symlinkTarget) {
                record(.externalSymlink, "\(name) → \(item.symlinkTarget)")
            }

            let normalized = normalizedEntryPath(name)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            if let first = firstSpellingByLowercased[key] {
                if first != normalized {
                    record(.caseCollision, "\(first) ↔ \(normalized)")
                } else if Array(first.utf8) != Array(normalized.utf8) {
                    // 0.4.3 #14:Swift 字符串比较是**规范等价**的 —— first == normalized 但字节不同,
                    // 就是 NFC/NFD 混用(显示完全一样)。跨平台解压会变成两个文件或静默互覆。
                    record(.normalizationCollision, "\(normalized) (NFC ↔ NFD)")
                }
            } else {
                firstSpellingByLowercased[key] = normalized
            }
        }

        // 按枚举声明序输出，结果确定（测试 + 展示稳定）。
        return ArchiveSecurityFindingKind.allCases.compactMap { kind in
            guard let paths = byKind[kind], !paths.isEmpty else { return nil }
            return ArchiveSecurityFinding(kind: kind, entryPaths: paths)
        }
    }

    /// 控制字符（C0 / DEL）+ Unicode 双向覆盖（RLO 等文件名伪装）。
    nonisolated private static func isSuspiciousScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 || scalar.value == 0x7F { return true }
        return (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// Windows 保留设备名(整段或「保留名.扩展名」形态都无法在 Windows 上创建)。
    nonisolated private static let windowsReservedBaseNames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul"]
        for n in 1...9 {
            names.insert("com\(n)")
            names.insert("lpt\(n)")
        }
        return names
    }()

    nonisolated private static func isWindowsReservedName(_ segment: String) -> Bool {
        let base = segment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return windowsReservedBaseNames.contains(base.lowercased())
    }

    nonisolated private static func isOverlongPath(_ path: String) -> Bool {
        if path.utf8.count > 1024 { return true }
        return path.split(separator: "/").contains { $0.utf8.count > 255 }
    }

    /// 7zz `-slt` 的 Attributes 模式串里出现 setuid/setgid 位（`rws` / `rwS` 形态）。
    nonisolated private static func hasSetuidMode(_ attributes: String) -> Bool {
        attributes.range(of: #"[rwx-]{2}[sS][rwx-]"#, options: .regularExpression) != nil
    }

    nonisolated private static func isExternalLinkTarget(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return true }
        return trimmed.split(separator: "/").contains("..")
    }

    nonisolated private static func normalizedEntryPath(_ name: String) -> String {
        var path = name
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - 解压前预检（0.4.2 #8）

/// 解压前的「这包会干什么」概要 —— 安装器式预告。纯统计，不碰文件系统；
/// 覆盖风险（目标已有同名项）等文件系统事实由 UI 层用 `topLevelNames` 自查。
struct ArchiveExtractPreflight: Equatable {
    let fileCount: Int
    let folderCount: Int
    /// 原始（解压后）字节总和。后端没报大小的条目按 0 计 —— 是下限不是精确值。
    let totalBytes: Int64
    let symlinkCount: Int
    /// `ArchiveSecurityReport` 命中的条目总数（横幅同源）。
    let suspiciousEntryCount: Int
    let encryptedEntryCount: Int

    nonisolated static func analyze(_ items: [ArchiveItem]) -> ArchiveExtractPreflight {
        var files = 0
        var folders = 0
        var symlinks = 0
        var encrypted = 0
        var bytes: Int64 = 0
        for item in items {
            if item.isDirectory {
                folders += 1
            } else {
                files += 1
                bytes += item.size ?? 0
            }
            if !item.symlinkTarget.isEmpty { symlinks += 1 }
            if item.isEncrypted { encrypted += 1 }
        }
        let suspicious = ArchiveSecurityReport.analyze(items).reduce(0) { $0 + $1.entryPaths.count }
        return ArchiveExtractPreflight(
            fileCount: files,
            folderCount: folders,
            totalBytes: bytes,
            symlinkCount: symlinks,
            suspiciousEntryCount: suspicious,
            encryptedEntryCount: encrypted
        )
    }

    /// 解压会在目标目录落下的**顶层**名字（去重、升序）—— UI 拿去查覆盖风险。
    nonisolated static func topLevelNames(of items: [ArchiveItem]) -> [String] {
        var names = Set<String>()
        for item in items {
            var path = item.name
            while path.hasPrefix("./") { path.removeFirst(2) }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let first = trimmed.split(separator: "/").first, !first.isEmpty else { continue }
            names.insert(String(first))
        }
        return names.sorted()
    }
}

// MARK: - macOS 元数据垃圾（0.4.2 #16）

/// 压缩包里经典的 macOS / Windows 元数据垃圾的识别。创建侧已有「跳过 .DS_Store」排除；
/// 这里服务读侧：右键「清理 macOS 元数据」与归档比较的「忽略垃圾」过滤。
enum ArchiveJunkFiles {

    /// `.DS_Store` / `__MACOSX/…` / AppleDouble `._*` / `Thumbs.db` / `desktop.ini`。
    nonisolated static func isJunkPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return false }
        if components.contains("__MACOSX") { return true }
        if leaf == ".DS_Store" || leaf == "Thumbs.db" || leaf == "desktop.ini" { return true }
        if leaf.hasPrefix("._"), leaf.count > 2 { return true }   // AppleDouble 资源叉
        return false
    }

    nonisolated static func junkEntries(in items: [ArchiveItem]) -> [ArchiveItem] {
        items.filter { isJunkPath($0.name) }
    }

    /// 0.4.3 #15:解压「跳过符号链接」—— 合并前在 **staging 树**上删掉所有符号链接(含失效链接)。
    /// 与 removeJunk 同位同口径:目标目录原有文件零接触;链接删干净后,符号链接安全策略自然无须再问。
    @discardableResult
    nonisolated static func removeSymlinks(in root: URL, fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return 0 }
        var removed = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                try? fileManager.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    /// 0.4.2：解压「跳过 macOS 元数据垃圾」—— 在 **staging 树**上删垃圾（解压先进 staging 再合并，
    /// 所以这里删的全是本次解压产物，绝不会碰目标目录原有文件）。返回删除条目数。
    ///
    /// **必须走 POSIX `readdir`**：实测 Foundation 的目录枚举（enumerator / contentsOfDirectory）
    /// 会把 AppleDouble `._*` 文件**整个藏起来**（盘上存在、`ls`/`fileExists` 可见，枚举就是不吐）——
    /// 清垃圾恰恰要看见这些文件。`__MACOSX` 整目录删；目录判定用 lstat 语义（不跟符号链接下钻）。
    @discardableResult
    nonisolated static func removeJunk(in root: URL, fileManager: FileManager = .default) -> Int {
        var removed = 0
        func walk(_ directory: URL) {
            for name in posixChildren(of: directory.path) {
                let child = directory.appendingPathComponent(name)
                if name == "__MACOSX" || isJunkPath(name) {
                    if (try? fileManager.removeItem(at: child)) != nil {
                        removed += 1
                    }
                    continue
                }
                // lstat 语义判目录（attributesOfItem 不跟符号链接）：symlink 指向外部目录时绝不下钻。
                let type = (try? fileManager.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType
                if type == .typeDirectory {
                    walk(child)
                }
            }
        }
        walk(root)
        return removed
    }

    /// POSIX 目录列举（readdir）—— 不经 Foundation 的 AppleDouble 过滤。
    nonisolated private static func posixChildren(of directoryPath: String) -> [String] {
        guard let dir = opendir(directoryPath) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if !name.isEmpty, name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }
}

// MARK: - 发布包检查（0.4.2 #15）

/// 「发布前检查」的条目侧统计 —— 纯函数。测试结果 / SHA-256 / 签名归属由调用方异步补齐。
struct ReleaseInspectionStats: Equatable {
    let fileCount: Int
    let folderCount: Int
    let totalBytes: Int64
    let junkCount: Int
    let emptyDirectoryCount: Int
    let executableCount: Int
    let symlinkCount: Int
}

enum ReleaseInspection {

    nonisolated static func stats(for items: [ArchiveItem]) -> ReleaseInspectionStats {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
        var executables = 0
        var symlinks = 0
        var directoryPaths: [String] = []
        var allPaths: [String] = []

        for item in items {
            let normalized = normalizedPath(item.name)
            allPaths.append(normalized)
            if item.isDirectory {
                folders += 1
                directoryPaths.append(normalized)
            } else {
                files += 1
                bytes += item.size ?? 0
                if isExecutableMode(item.attributes) { executables += 1 }
            }
            if !item.symlinkTarget.isEmpty { symlinks += 1 }
        }

        // 空目录：没有任何条目以它为前缀。O(d×n) 在发布包尺度可接受；大包用前缀集合优化。
        let pathSet = Set(allPaths)
        var prefixSet = Set<String>()
        for path in pathSet {
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                prefixSet.insert(prefix)
            }
        }
        let emptyDirectories = directoryPaths.filter { !$0.isEmpty && !prefixSet.contains($0) }.count

        return ReleaseInspectionStats(
            fileCount: files,
            folderCount: folders,
            totalBytes: bytes,
            junkCount: ArchiveJunkFiles.junkEntries(in: items).count,
            emptyDirectoryCount: emptyDirectories,
            executableCount: executables,
            symlinkCount: symlinks
        )
    }

    /// 7zz `-slt` Attributes 的模式串里 owner/group/other 任一执行位（x/s/t）置位。
    nonisolated static func isExecutableMode(_ attributes: String) -> Bool {
        guard let range = attributes.range(of: #"[-dlbcps][rwxsStT-]{9}"#, options: .regularExpression) else { return false }
        let mode = Array(attributes[range])
        let executableBits: Set<Character> = ["x", "s", "t"]
        return executableBits.contains(mode[3]) || executableBits.contains(mode[6]) || executableBits.contains(mode[9])
    }

    nonisolated private static func normalizedPath(_ name: String) -> String {
        var path = name
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - 结构指纹(队列 #9)

/// 归档「结构指纹」:对**条目结构**(归一化路径 + 类型 + 大小 + CRC)做 SHA-256,
/// 刻意忽略时间戳、注释、元数据垃圾条目与压缩参数 —— 同一份内容重新打包(哪怕换了压缩等级 /
/// 修改时间不同 / 多了 .DS_Store)指纹不变,快速回答「这两个包结构上是不是同一份东西」。
/// 纯函数、确定性(条目按归一化路径排序),SwiftPM 可测。
enum ArchiveStructuralFingerprint {

    /// 计算指纹(64 位十六进制 SHA-256)。空集合也有确定指纹(空输入哈希)。
    nonisolated static func compute(for items: [ArchiveItem]) -> String {
        let lines = normalizedLines(for: items)
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 参与哈希的归一化行(测试 / 调试可见)。`dir|path` 或 `file|path|size|crc`;
    /// 大小 / CRC 缺失记 `-`(zip 后备路径 / 目录条目没有 CRC);垃圾条目(.DS_Store / __MACOSX /
    /// AppleDouble / Thumbs.db / desktop.ini)整行剔除。
    nonisolated static func normalizedLines(for items: [ArchiveItem]) -> [String] {
        items.compactMap { item -> String? in
            let path = normalizedPath(item.name)
            guard !path.isEmpty, !ArchiveJunkFiles.isJunkPath(item.name) else { return nil }
            if item.isDirectory {
                return "dir|\(path)"
            }
            let size = item.size.map(String.init) ?? "-"
            let crc = item.crc.isEmpty ? "-" : item.crc.lowercased()
            return "file|\(path)|\(size)|\(crc)"
        }
        .sorted()
    }

    /// 与 ArchiveDiff 同口径的路径归一化:统一斜杠、去前导 `./`、去首尾 `/`。
    private nonisolated static func normalizedPath(_ raw: String) -> String {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

// MARK: - 智能去单层目录(队列 #13)

/// 「单层包装壳」检测与上提:`project-1.0/` 把所有内容包了一层(GitHub 源码包的常态)。
/// 解压对话框检测到后给开关,选中则在 **staging** 上把壳内内容上提一层再合并 ——
/// 与 skipJunk / skipSymlinks 同点位,目标目录零接触。
enum ArchiveSingleRootFolder {

    /// 全部条目都在同一个顶层目录下时返回该目录名;顶层有任何文件 / 多个顶层目录 → nil。
    /// 垃圾条目(.DS_Store / __MACOSX / AppleDouble…)不参与判定。
    nonisolated static func detect(in items: [ArchiveItem]) -> String? {
        var root: String?
        for item in items where !ArchiveJunkFiles.isJunkPath(item.name) {
            var path = item.name.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasPrefix("/") { path.removeFirst() }
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { continue }
            let top = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? path
            if path == top, !item.isDirectory {
                // 顶层直接有文件 → 没有统一的壳。
                return nil
            }
            if let existing = root {
                if existing != top { return nil }
            } else {
                root = top
            }
        }
        return root
    }

    /// staging 顶层恰好一个**真目录**(其余至多垃圾文件)时,把其内容上提一层、删掉空壳。
    /// 壳是符号链接时拒绝处理(不跟随,防越界)。`project/project` 同名嵌套安全:先把壳挪到
    /// 唯一临时名再上提,绝无覆盖。失败尽力回滚,staging 内容保持完整可合并。
    @discardableResult
    nonisolated static func lift(in stagingURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return false }
        let visible = entries.filter { !ArchiveJunkFiles.isJunkPath($0.lastPathComponent) }
        guard visible.count == 1, let wrapper = visible.first,
              let values = try? wrapper.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }

        let shell = stagingURL.appendingPathComponent(".simplezip-lift-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: wrapper, to: shell)
            for child in try fileManager.contentsOfDirectory(at: shell, includingPropertiesForKeys: nil) {
                try fileManager.moveItem(at: child, to: stagingURL.appendingPathComponent(child.lastPathComponent))
            }
            try fileManager.removeItem(at: shell)
            return true
        } catch {
            // 回滚尽力:壳还在临时名下就挪回原名(部分上提时保持现状 —— 内容一个不少,仍可合并)。
            if fileManager.fileExists(atPath: shell.path), !fileManager.fileExists(atPath: wrapper.path) {
                try? fileManager.moveItem(at: shell, to: wrapper)
            }
            return false
        }
    }
}
