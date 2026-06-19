//
//  FinderFavoritesReader.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// 从 macOS Finder 的「个人收藏」侧栏读出当前用户收藏的目录列表。
///
/// 设计动机：用户在 Finder 里精心调过的「个人收藏」（侧栏顶部一栏），
/// SimpleZip 应该镜像它，而不是硬编码 5 个固定位置。
///
/// 存储位置：
/// - macOS 11+：`~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl4`
/// - 老版本回落：同目录的 `.sfl3`
/// 二者都是 NSKeyedArchiver 序列化的 binary plist。sfl4 顶层是 NSDictionary：
///   `{ "items": [ { "Bookmark": <bookmark Data>, "uuid": ..., "visibility": ... }, ... ], "properties": ... }`
/// sfl3 老版本用 `SFLListItem` 私有类装条目；目前用户已升级到 sfl4，本实现仅覆盖 sfl4 格式。
///
/// 限制：
/// - 私有格式，新 macOS 大版本可能改 schema；解析失败应回退到内置默认项，而不是让侧栏空着；
/// - 只读：永远不写回 sfl4，避免把 Finder 收藏弄崩；
/// - 没有变化通知：调用方在主窗口聚焦时重读即可。
enum FinderFavoritesReader {
    struct Item: Equatable {
        let url: URL
        let displayName: String
    }

    /// UserDefaults key —— 持久化最近一次成功读到的路径列表。
    /// 形态：`[String]`（路径，按 sfl4 顺序）。重建 Item 时再从 URL 取本地化名 / 图标。
    private nonisolated static let cacheKey = "finderFavoritesCachedPaths"

    /// 读取 + 缓存：用户明确开启同步后，sfl4 成功 → 顺手写缓存；失败（被锁 / TCC / 文件不存在）→ 读上次缓存。
    /// 两边都空时返回空数组，让调用方走 hardcoded fallback。
    /// 缓存里的路径会再过一次「目录是否存在」过滤 —— 用户外接盘没接、上次的 /Volumes/xxx 没了，
    /// 不能错误地让 UI 显示一个跳到不存在路径的入口。
    nonisolated static func readWithCache() -> [Item] {
        guard AppPreferences.finderFavoritesSyncEnabled else {
            return []
        }
        let fresh = read()
        if !fresh.isEmpty {
            let paths = fresh.map { $0.url.path }
            UserDefaults.standard.set(paths, forKey: cacheKey)
            return fresh
        }
        guard let cachedPaths = UserDefaults.standard.array(forKey: cacheKey) as? [String], !cachedPaths.isEmpty else {
            return []
        }
        return existingDeduplicatedDirectories(from: cachedPaths)
    }

    /// 纯逻辑（Q4 可测）：把一串候选路径过滤成「真实存在的目录」，并按规范化路径去重（保留首个出现）。
    /// 缓存路径重建走这套统一口径 —— 与 read() 对 bookmark 解出 URL 的「存在即目录 + 去重」过滤一致。
    nonisolated static func existingDeduplicatedDirectories(from paths: [String]) -> [Item] {
        var seenPaths: Set<String> = []
        var results: [Item] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let canonicalPath = url.standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else { continue }
            results.append(Item(url: url, displayName: displayName(for: url)))
        }
        return results
    }

    /// 读出当前所有 Finder 收藏目录。读不到或一条都没解析出来 → 返回空数组，让调用方走回退。
    nonisolated static func read() -> [Item] {
        guard let data = loadDatabaseData() else { return [] }
        guard let root = unarchive(data) as? [String: Any] else { return [] }
        guard let rawItems = root["items"] as? [[String: Any]] else { return [] }

        var seenPaths: Set<String> = []
        var results: [Item] = []
        for raw in rawItems {
            guard let bookmarkData = raw["Bookmark"] as? Data else { continue }
            var stale = false
            // resolvingBookmarkData 在非 sandbox 进程里能直接解出 URL 本身，不需要 startAccessingSecurityScopedResource。
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }

            // 只接受真实存在的目录：AirDrop / Recents / Tags 这些 Finder 虚拟项的 bookmark
            // 要么解不出 URL，要么 URL 不指向具体文件夹，全部被这步滤掉。
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            // 同一物理路径只保留第一条 —— Finder 收藏里多次出现同一文件夹很罕见，但防御一下。
            let canonicalPath = url.standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else { continue }

            results.append(Item(
                url: url,
                displayName: displayName(for: url)
            ))
        }
        return results
    }

    /// 找出当前 macOS 实际使用的 sfl 数据库文件，按 sfl4 → sfl3 顺序尝试。
    private nonisolated static func loadDatabaseData() -> Data? {
        guard let authorizedRoot = authorizedSharedFileListRoot() else {
            return nil
        }
        let didAccess = authorizedRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                authorizedRoot.stopAccessingSecurityScopedResource()
            }
        }
        guard let dir = sharedFileListDirectory(from: authorizedRoot) else {
            return nil
        }
        let candidates = [
            "com.apple.LSSharedFileList.FavoriteItems.sfl4",
            "com.apple.LSSharedFileList.FavoriteItems.sfl3"
        ]
        for filename in candidates {
            let url = dir.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// 用户可在权限面板里选择 `com.apple.sharedfilelist` 本身，也可以选择它的父级 Application Support。
    nonisolated static func sharedFileListDirectory(from authorizedDirectory: URL) -> URL? {
        let url = authorizedDirectory.standardizedFileURL
        if url.lastPathComponent == "com.apple.sharedfilelist", isDirectory(url) {
            return url
        }
        let child = url.appendingPathComponent("com.apple.sharedfilelist", isDirectory: true)
        if isDirectory(child) {
            return child
        }
        return nil
    }

    private nonisolated static func authorizedSharedFileListRoot() -> URL? {
        guard let bookmarkData = AppPreferences.finderFavoritesDirectoryBookmarkData else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `requiresSecureCoding = false` 是必须的：sfl4 里的 dict / array 不是 SecureCoding 的预期序列化产物。
    private nonisolated static func unarchive(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        let value = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return value
    }

    /// 显示名优先取 `.localizedNameKey`（Finder 用的本地化名 —— 比如「下载」而不是 "Downloads"），
    /// 拿不到回退到 FileManager 的 displayName，最后回退到 URL 的最后一段。
    private nonisolated static func displayName(for url: URL) -> String {
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localized.isEmpty {
            return localized
        }
        let fmName = FileManager.default.displayName(atPath: url.path)
        if !fmName.isEmpty {
            return fmName
        }
        return url.lastPathComponent
    }

}
