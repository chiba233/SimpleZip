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
/// service 这边没有 UI 副作用，方便后续单测和复用（例如未来 Finder 扩展也可直接调）。
///
/// 没有内部状态（除了注入的 `fileManager`），命令式调用风格 —— 不像 ArchiveSession
/// 那种「记着当前是哪个压缩包」。
@MainActor
final class FileBrowserService {
    private let fileManager: FileManager

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
    private func directoryContents(
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
    func contents(
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
    func makeFileItems(
        from urls: [URL],
        showSymbolicLinks: Bool,
        hiddenSuffixes: [String],
        includeMacOSHidden: Bool,
        folderFirst: Bool
    ) -> [FileItem] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
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
        return urls.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let isSymbolicLink = values.isSymbolicLink == true
            if isSymbolicLink && !showSymbolicLinks {
                return nil
            }
            let isDirectory = isSymbolicLink ? Self.isDirectorySymbolicLinkTarget(fileURL, fileManager: fileManager) : values.isDirectory == true
            let isPackage = isDirectory && Self.isLocalFilePackage(fileURL)
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

            return FileItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                displayName: displayName,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink,
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
                applicationName: applicationName
            )
        }
        .sorted { lhs, rhs in
            // folderFirst=false 时，标签搜索结果按纯名称排序而不区分类型 ——
            // 标签结果跨多个目录，目录混在前面没意义。
            if folderFirst, Self.isNavigableDirectory(lhs) != Self.isNavigableDirectory(rhs) { return Self.isNavigableDirectory(lhs) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
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
    static func isNavigableDirectory(_ item: FileItem) -> Bool {
        item.isDirectory && !isLocalFilePackage(item.url)
    }

    /// `NSWorkspace` 判定 path 是不是 macOS 意义上的「包」。
    static func isLocalFilePackage(_ url: URL) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// 符号链接指向的目标是否是目录 —— 用来决定 link 应该按文件还是目录展示。
    static func isDirectorySymbolicLinkTarget(_ url: URL, fileManager: FileManager) -> Bool {
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
    static func displayedName(for rawName: String, hiddenSuffixes: [String]) -> String {
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
    static func preferredApplicationName(for url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory, !isLocalFilePackage(url) {
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
