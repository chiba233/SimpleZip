//
//  FileBrowserService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// 本地文件浏览相关的纯逻辑：列目录、加载 Finder 标签、把 URL 转成 `FileItem`、
/// 地址栏自动补全。
///
/// 设计动机：ArchiveBrowserModel 之前一个人持有这些操作 + UI 状态 + 命令路由，
/// 把「读文件 / 计算显示属性」抽到 service 后，model 只用专心管 @Published 状态，
/// service 这边没有 UI 副作用，方便后续单测和复用。
///
/// 没有内部状态（除了注入的 `fileManager`），命令式调用风格 —— 不像 ArchiveSession
/// 那种「记着当前是哪个压缩包」。
@MainActor
final class FileBrowserService {
    // FileManager 按 Apple 文档线程安全(委托除外,这里不用委托);SDK 未标 Sendable → unsafe 注记。
    private nonisolated(unsafe) let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - 列目录

    /// 列目录的底层封装：直接列失败时，退一步用 `resolvingSymlinksInPath()` 再列一次。
    ///
    /// 动机：`/home` 这类 autofs 触发挂载点本身是 symlink，直接 `contentsOfDirectory(at:)`
    /// 会抛 POSIX 20「Not a directory」；但解析到真实挂载路径（`/System/Volumes/Data/home`）
    /// 后能正常列出。普通 symlink（`/etc`、`/var`、`/tmp`）直接列就成功，走不到 fallback，
    /// 因此条目 URL 仍保持原路径、地址栏不会突然跳成 `/private/...`。
    private nonisolated func directoryContents(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        } catch {
            let resolved = url.resolvingSymlinksInPath()
            guard resolved != url else { throw error }
            return try fileManager.contentsOfDirectory(at: resolved, includingPropertiesForKeys: keys, options: options)
        }
    }

    /// 列出 `url` 下应展示的条目。
    ///
    /// `followFinderStructure=true` 时会把 `/Applications`、`/System/Applications`、
    /// `/System/Cryptexes/App/...` 合并成 Finder 视图里看到的同一份「应用」列表，
    /// 并补上 `/System/Library/CoreServices/Finder.app` 这类 Finder 显式列出的条目。
    /// 同名条目按大小写不敏感去重。
    nonisolated func contents(
        of url: URL,
        showHiddenFiles: Bool,
        followFinderStructure: Bool,
        resourceKeys: Set<URLResourceKey>
    ) throws -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard followFinderStructure else {
            return try directoryContents(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: options
            )
        }

        let standardizedURL = url.standardizedFileURL
        let finderDisplayRoots: [URL]
        let finderDisplayExtraEntries: [URL]
        switch standardizedURL.path {
        case "/Applications":
            finderDisplayRoots = [
                standardizedURL,
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")
            ]
            finderDisplayExtraEntries = [
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            ]
        case "/Applications/Utilities":
            finderDisplayRoots = [
                standardizedURL,
                URL(fileURLWithPath: "/System/Applications/Utilities")
            ]
            finderDisplayExtraEntries = []
        default:
            finderDisplayRoots = [standardizedURL]
            finderDisplayExtraEntries = []
        }

        // 单根目录走快路径，省一次合并去重的开销。
        guard finderDisplayRoots.count > 1 || !finderDisplayExtraEntries.isEmpty else {
            return try directoryContents(
                at: standardizedURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: options
            )
        }

        var mergedURLs: [URL] = []
        var seenNames = Set<String>()
        let mergedResourceKeys = resourceKeys.union([.isHiddenKey])

        func appendEntry(_ entry: URL) {
            guard fileManager.fileExists(atPath: entry.path) else { return }
            if options.contains(.skipsHiddenFiles),
               let values = try? entry.resourceValues(forKeys: mergedResourceKeys),
               values.isHidden == true {
                return
            }

            let dedupeKey = entry.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenNames.insert(dedupeKey).inserted else { return }
            mergedURLs.append(entry)
        }

        for root in finderDisplayRoots where fileManager.fileExists(atPath: root.path) {
            let entries = try directoryContents(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: options
            )
            for entry in entries {
                appendEntry(entry)
            }
        }

        for entry in finderDisplayExtraEntries {
            appendEntry(entry)
        }

        return mergedURLs
    }

    /// 用 `mdfind` 搜出贴了某个 Finder 标签的所有用户文件。
    ///
    /// 跑在 global queue 上以免 mdfind 阻塞 main actor；
    /// 结果会按 home 目录做范围限定，避免扫到系统目录里贴了同名标签的项目。
    nonisolated func taggedFileURLs(named tag: String) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let output = Pipe()
                    let escapedTag = tag.replacingOccurrences(of: "\"", with: "\\\"")
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                    process.arguments = [
                        "-onlyin",
                        FileManager.default.homeDirectoryForCurrentUser.path,
                        "kMDItemUserTags == \"\(escapedTag)\""
                    ]
                    process.standardOutput = output
                    try process.run()
                    process.waitUntilExit()

                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self)
                    let urls = text
                        .split(separator: "\n")
                        .map { URL(fileURLWithPath: String($0)) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    continuation.resume(returning: urls)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 把一组 URL 转成 UI 用的 `FileItem`，并按「文件夹优先 / 名称自然排序」展示。
    ///
    /// applicationName 在循环里通过 cache 命中重复后缀，避免对 Documents 这种几十万文件的目录
    /// 做几十万次 LaunchServices 查询。
    nonisolated func makeFileItems(
        from urls: [URL],
        showSymbolicLinks: Bool,
        hiddenSuffixes: [String],
        includeMacOSHidden: Bool,
        folderFirst: Bool
    ) -> [FileItem] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey,
            .localizedTypeDescriptionKey
        ]
        var applicationNameCache: [String: String] = [:]
        // 仅当「权限 / 属主」列至少有一个启用时,才逐项 stat 取 POSIX 元数据。
        // attributesOfItem 会对 ~/Desktop、~/Downloads 这类 TCC 受保护目录发起一次带属主 / ACL 属性的
        // getattrlist,从而触发系统权限弹窗;两列默认都关,默认情况下不该平白申请这些目录的访问权限。
        let wantsPosixMetadata = AppPreferences.showFilePermissionsColumn || AppPreferences.showFileOwnerColumn
        // uid → 用户名只解析一次：getpwuid 可能走 OpenDirectory（网络账户下是真网络请求），
        // 同一文件夹里属主通常就一两个，按 uid 缓存把几万次解析压成几次。
        var ownerNameByUID: [uid_t: String] = [:]
        return urls.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let isSymbolicLink = values.isSymbolicLink == true
            if isSymbolicLink && !showSymbolicLinks {
                return nil
            }
            let isDirectory = isSymbolicLink ? Self.isDirectorySymbolicLinkTarget(fileURL, fileManager: fileManager) : values.isDirectory == true
            // 包判定**就在这里做一次、存进 FileItem**：普通目录直接用批量取来的 isPackageKey（零额外 IO），
            // 只有符号链接才走 NSWorkspace + 解析目标（isPackageKey 看链接本身,对 symlink→.app 会误判 false）。
            // 下游(排序 / 可进入判断 / 显示包内容 / 拖拽校验)一律读字段,不准再现场查文件系统。
            let isPackage = isDirectory && (isSymbolicLink ? Self.isLocalFilePackage(fileURL) : values.isPackage == true)
            let typeDescription = isDirectory && !isPackage
                ? L10n.text("type.folder")
                : (values.localizedTypeDescription ?? (isDirectory ? L10n.text("type.folder") : L10n.text("type.file")))
            let displayName = Self.displayedName(for: fileURL.lastPathComponent, hiddenSuffixes: hiddenSuffixes)
            // 同目录所有同后缀文件共享 application name 查询结果；
            // 真正按 URL 查询的只有 package 类型（每个 bundle 都不一样）。
            let applicationKey = if isDirectory && !isPackage {
                "__folder__"
            } else if isPackage {
                "__package__:\(fileURL.path)"
            } else {
                fileURL.pathExtension.lowercased()
            }
            let applicationName = applicationNameCache[applicationKey] ?? Self.preferredApplicationName(for: fileURL, isDirectory: isDirectory, isPackage: isPackage)
            applicationNameCache[applicationKey] = applicationName

            // Unix 权限 / 属主 —— lstat 语义（不跟随符号链接,显示链接自身的权限与属主）。取不到就留空 / 退回 uid。
            // 只在列启用时 stat,避免对受保护目录平白触发 TCC 弹窗（见上方 wantsPosixMetadata）。
            // 用裸 lstat 而不是 attributesOfItem：后者每项一次 getattrlist **加一次属主用户名解析**，
            // 大目录在主线程直接卡死（实测挂在这行被 SIGTERM 强杀）；lstat 是微秒级 syscall，
            // 用户名走上面的 uid 缓存。语义不变 —— attributesOfItem 本身就是 lstat 语义。
            var permissions = ""
            var owner = ""
            if wantsPosixMetadata {
                var status = stat()
                if lstat(fileURL.path, &status) == 0 {
                    permissions = Self.posixModeString(
                        mode: UInt16(status.st_mode & 0o7777),
                        isDirectory: isDirectory,
                        isSymbolicLink: isSymbolicLink
                    )
                    if let cached = ownerNameByUID[status.st_uid] {
                        owner = cached
                    } else {
                        let name = getpwuid(status.st_uid).map { String(cString: $0.pointee.pw_name) }
                            ?? String(status.st_uid)
                        ownerNameByUID[status.st_uid] = name
                        owner = name
                    }
                }
            }

            return FileItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                displayName: displayName,
                isDirectory: isDirectory,
                isPackage: isPackage,
                isSymbolicLink: isSymbolicLink,
                symlinkTarget: isSymbolicLink
                    ? ((try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) ?? "")
                    : "",
                // 「隐藏」判定按用户选的模式：
                // - dotfilesOnly（默认）：仅名字以 . 开头的 dotfile（Unix 习惯）；
                // - macOSHidden：再算上带 macOS UF_HIDDEN 标志的项（/etc、~/Library 等）。
                // 之所以可选：macOS 把一些非 dotfile（含 /etc、/var 这类符号链接）也标隐藏，
                // 但不少用户按 Unix 直觉只认 dotfile。
                isHidden: fileURL.lastPathComponent.hasPrefix(".") || (includeMacOSHidden && values.isHidden == true),
                size: isDirectory ? nil : Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                created: values.creationDate,
                dateAdded: values.addedToDirectoryDate,
                lastOpened: values.contentAccessDate,
                typeDescription: typeDescription,
                applicationName: applicationName,
                permissions: permissions,
                owner: owner
            )
        }
        .sorted { lhs, rhs in
            // folderFirst=false 时，标签搜索结果按纯名称排序而不区分类型 ——
            // 标签结果跨多个目录，目录混在前面没意义。
            if folderFirst, Self.isNavigableDirectory(lhs) != Self.isNavigableDirectory(rhs) { return Self.isNavigableDirectory(lhs) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// 把 POSIX 权限位格式化成 `ls -l` 风格的 10 字符串（`-rw-r--r--` / `drwxr-xr-x` / `lrwxr-xr-x`）。
    /// `mode` 为 `st_mode & 07777`（含 setuid/setgid/sticky）。首字符按目录 / 符号链接 / 普通文件区分。
    nonisolated static func posixModeString(mode: UInt16, isDirectory: Bool, isSymbolicLink: Bool) -> String {
        let m = Int(mode)
        var chars: [Character] = [isSymbolicLink ? "l" : (isDirectory ? "d" : "-")]
        let bits = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        let letters: [Character] = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        for (bit, letter) in zip(bits, letters) {
            chars.append((m & bit) != 0 ? letter : "-")
        }
        // setuid / setgid / sticky 落在各自的 execute 位上：有 x 用小写 s/t，无 x 用大写 S/T。
        if m & 0o4000 != 0 { chars[3] = (m & 0o100 != 0) ? "s" : "S" }
        if m & 0o2000 != 0 { chars[6] = (m & 0o010 != 0) ? "s" : "S" }
        if m & 0o1000 != 0 { chars[9] = (m & 0o001 != 0) ? "t" : "T" }
        return String(chars)
    }

    /// 地址栏输入补全：在 directoryURL 中列出名字以 prefix 开头的子目录。
    ///
    /// 一定排除「包」（.app、.bundle 这类）—— 双击进入包是 Finder 也避免的行为。
    func directoryCompletions(
        in directoryURL: URL,
        matching prefix: String,
        showHiddenFiles: Bool,
        showSymbolicLinks: Bool
    ) -> [LocationCompletion] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard let urls = try? directoryContents(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            return []
        }

        let lowercasedPrefix = prefix.lowercased()
        let fileManager = self.fileManager
        return urls.compactMap { url -> LocationCompletion? in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  (values.isSymbolicLink != true || showSymbolicLinks),
                  ((values.isSymbolicLink == true && Self.isDirectorySymbolicLinkTarget(url, fileManager: fileManager)) || values.isDirectory == true),
                  !Self.isLocalFilePackage(url)
            else {
                return nil
            }

            let displayName = fileManager.displayName(atPath: url.path).isEmpty ? url.lastPathComponent : fileManager.displayName(atPath: url.path)
            if !lowercasedPrefix.isEmpty, !displayName.lowercased().hasPrefix(lowercasedPrefix), !url.lastPathComponent.lowercased().hasPrefix(lowercasedPrefix) {
                return nil
            }
            return LocationCompletion(url: url, displayName: displayName, path: url.path)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - 纯静态辅助

    /// 「可点进去」的目录 —— 普通目录是的，.app / .pkg 这类「包」不是。
    /// 读列目录时存好的字段,**零 IO** —— 它在排序比较器里被 O(n log n) 次调用,
    /// 以前每次现场 resolvingSymlinksInPath + LaunchServices,大目录列表直接卡死。
    nonisolated static func isNavigableDirectory(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isPackage
    }

    /// `NSWorkspace` 判定 path 是不是 macOS 意义上的「包」。
    ///
    /// 必须先 `resolvingSymlinksInPath()` 再判：`isFilePackage(atPath:)` 对「指向 .app/.bundle 的
    /// 符号链接」会返回 false（它看的是链接本身，不是目标），导致 symlink→Safari.app 被当成可进入
    /// 目录、双击进目录而不是启动 App（用户反馈）。解析到真实目标后就能正确识别为包。
    nonisolated static func isLocalFilePackage(_ url: URL) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: url.resolvingSymlinksInPath().path)
    }

    /// 符号链接指向的目标是否是目录 —— 用来决定 link 应该按文件还是目录展示。
    nonisolated static func isDirectorySymbolicLinkTarget(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// 根据「设置 - 浏览 - 隐藏后缀」配置去掉用户选择不再显示的后缀。
    ///
    /// 按后缀长度倒序匹配，先尝试 `.tar.gz` 这类多段后缀；
    /// `rawName.count > suffix.count + 1` 避免把全名就是后缀的文件（罕见）变成空字符串。
    nonisolated static func displayedName(for rawName: String, hiddenSuffixes: [String]) -> String {
        let lowercasedName = rawName.lowercased()
        guard let suffix = hiddenSuffixes
            .sorted(by: { $0.count > $1.count })
            .first(where: { lowercasedName.hasSuffix(".\($0.lowercased())") && rawName.count > $0.count + 1 }) else {
            return rawName
        }
        return String(rawName.dropLast(suffix.count + 1))
    }

    /// 在「应用程序」列里显示的「会用什么 App 打开」。
    ///
    /// 三段查找优先级：
    /// 1. 文件夹（非包）—— 一律「Finder」；
    /// 2. 包 —— 读包自己的 Info.plist，优先 CFBundleDisplayName，再 CFBundleName，再去后缀名；
    /// 3. 普通文件 —— LaunchServices 给出的默认 app，仍按 Display/Name/去后缀名顺序取标签。
    nonisolated static func preferredApplicationName(for url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        // 调用方已算好 isPackage,不准再查一遍文件系统（以前这里冗余地又 resolvingSymlinks + LaunchServices）。
        if isDirectory, !isPackage {
            return "Finder"
        }
        if isPackage,
           let bundle = Bundle(url: url) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
            return url.deletingPathExtension().lastPathComponent
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return ""
        }
        if let bundle = Bundle(url: appURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}
