//
//  ArchiveListingCache.swift
//  SimpleZip
//
//  0.4.4 #34:归档清单缓存。用户打开过的归档,把它的**非加密**条目名 + 少量元数据记下来,
//  供之后「文件 X 在哪个压缩包里」式的 Spotlight / Siri / 自然语言搜索(#35)直接定位并打开那个包。
//
//  **隐私红线**(见仓库隐私口径):只缓存**非加密**条目名;加密条目(item.isEncrypted)整条排除,
//  其名字 / 内容绝不入缓存。全加密包(没有任何非加密条目)根本不记。缓存只在本机 UserDefaults,不外发。
//
//  容量治理:单包条目数封顶(maxEntriesPerArchive,超出截断并标记)、缓存归档数上限(可在设置调,默认 50)、
//  TTL 过期(可在设置调,默认 30 天;0 = 永不过期)。读写都顺手清过期项,缓存不会无限留旧。
//  存取走 ReleaseLedgerStore 同款 UserDefaults JSON 习语。
//

import Foundation

/// 单个归档的缓存记录。`archivePath`(规范化后的磁盘路径)作主键 —— 同一个包再打开就替换、移到最前。
nonisolated struct ArchiveListingCacheEntry: Codable, Identifiable, Equatable {
    var id: String { archivePath }
    /// 规范化磁盘路径(resolvingSymlinks + standardized),作去重主键。
    let archivePath: String
    let archiveName: String
    /// 最近一次记录(打开)时间 —— TTL 与「越新越靠前」都看它。
    let recordedAt: Date
    let archiveByteSize: Int64?
    let archiveModified: Date?
    /// 列表里的总条目数(含被隐私排除的加密条目)。
    let totalEntryCount: Int
    /// 因加密被排除、未入缓存的条目数(隐私统计,不含名字)。
    let encryptedEntryCount: Int
    /// 条目数超过单包上限、缓存被截断 → true(搜索可能漏掉尾部条目)。
    let truncated: Bool
    /// 缓存下来的**非加密**条目(名字 + 是否目录 + 大小)。
    let entries: [CachedEntry]

    nonisolated struct CachedEntry: Codable, Equatable {
        /// 归档内完整路径(如 "Resources/zh-Hans.lproj/Localizable.strings")。
        let name: String
        let isDirectory: Bool
        let size: Int64?
    }
}

/// 跨缓存归档搜索条目名的命中。
nonisolated struct ArchiveListingSearchHit: Equatable {
    let archivePath: String
    let archiveName: String
    let entryName: String
    let isDirectory: Bool
    let recordedAt: Date
}

/// 缓存的治理策略(主开关 / 归档数上限 / TTL 天数)。默认从 `AppPreferences` 实时读取;测试可注入定值,
/// 避免污染 `UserDefaults.standard`。
nonisolated struct ArchiveListingCachePolicy: Equatable {
    var enabled: Bool
    var maxArchives: Int
    var ttlDays: Int

    static var current: ArchiveListingCachePolicy {
        ArchiveListingCachePolicy(
            enabled: AppPreferences.archiveListingCacheEnabled,
            maxArchives: AppPreferences.archiveListingCacheMaxArchives,
            ttlDays: AppPreferences.archiveListingCacheTTLDays
        )
    }
}

/// 归档清单缓存的 UserDefaults JSON 存取。最新记录插最前,超 TTL 清过期,超归档数上限裁最旧。
nonisolated final class ArchiveListingCacheStore {
    /// 单个归档最多缓存这么多条目名,封顶单包存储体积。超出则截断并把 `truncated` 标 true。
    static let maxEntriesPerArchive = 10_000

    private let defaults: UserDefaults
    private let storageKey = AppPreferences.Key.archiveListingCache
    private let policyProvider: @Sendable () -> ArchiveListingCachePolicy

    init(defaults: UserDefaults = .standard,
         policyProvider: @escaping @Sendable () -> ArchiveListingCachePolicy = { .current }) {
        self.defaults = defaults
        self.policyProvider = policyProvider
    }

    func loadAll() -> [ArchiveListingCacheEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([ArchiveListingCacheEntry].self, from: data) else { return [] }
        return entries
    }

    /// 记录一次成功打开。**只缓存非加密条目名**(隐私)。已存在同路径则替换并移到最前;
    /// 顺手清 TTL 过期项、按归档数上限裁最旧。返回是否真的写入了内容(全加密 / 空包 / 关了开关 → false)。
    @discardableResult
    func record(archiveURL: URL, items: [ArchiveItem], now: Date = Date()) -> Bool {
        let policy = policyProvider()
        guard policy.enabled else { return false }

        let nonEncrypted = items.filter { !$0.isEncrypted }
        // 全加密(条目名同属敏感面)/ 空包:没有可搜的非加密名,不占缓存槽,也不留痕。
        guard !nonEncrypted.isEmpty else { return false }

        let path = canonicalPath(for: archiveURL)
        let truncated = nonEncrypted.count > Self.maxEntriesPerArchive
        let cached = nonEncrypted.prefix(Self.maxEntriesPerArchive).map {
            ArchiveListingCacheEntry.CachedEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.int64Value
        let modified = attrs?[.modificationDate] as? Date

        let entry = ArchiveListingCacheEntry(
            archivePath: path,
            archiveName: archiveURL.lastPathComponent,
            recordedAt: now,
            archiveByteSize: byteSize,
            archiveModified: modified,
            totalEntryCount: items.count,
            encryptedEntryCount: items.count - nonEncrypted.count,
            truncated: truncated,
            entries: Array(cached)
        )

        var all = loadAll().filter { $0.archivePath != path }
        all.insert(entry, at: 0)
        all = pruneExpired(all, ttlDays: policy.ttlDays, now: now)
        let cap = max(1, policy.maxArchives)
        if all.count > cap { all.removeLast(all.count - cap) }
        persist(all)
        return true
    }

    /// 跨所有缓存归档按条目名子串搜索(忽略大小写),只返回文件(跳过目录条目)。
    /// 结果继承缓存的「越新越靠前」顺序;超 `limit` 即止。供 #35 的 Spotlight/Siri/自然语言搜索复用。
    func search(_ query: String, limit: Int = 200, now: Date = Date()) -> [ArchiveListingSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [ArchiveListingSearchHit] = []
        for archive in pruneExpired(loadAll(), ttlDays: policyProvider().ttlDays, now: now) {
            for entry in archive.entries where !entry.isDirectory {
                guard entry.name.lowercased().contains(needle) else { continue }
                hits.append(ArchiveListingSearchHit(
                    archivePath: archive.archivePath,
                    archiveName: archive.archiveName,
                    entryName: entry.name,
                    isDirectory: entry.isDirectory,
                    recordedAt: archive.recordedAt
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// 移除某个归档的缓存(例:文件已不在 / 用户在设置里单独清)。
    func remove(archivePath: String) {
        let target = canonicalPath(for: URL(fileURLWithPath: archivePath))
        persist(loadAll().filter { $0.archivePath != target })
    }

    /// 清空整个缓存(设置「清空」按钮 / 关闭开关 / 恢复出厂时调)。
    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    func count() -> Int { loadAll().count }

    /// 当前缓存占用的近似字节数(设置页展示用)。
    func storageByteSize() -> Int {
        defaults.data(forKey: storageKey)?.count ?? 0
    }

    /// 把已过 TTL 的项落地清掉。读取入口顺手调,避免缓存无限留旧。
    func pruneExpiredInPlace(now: Date = Date()) {
        let all = loadAll()
        let kept = pruneExpired(all, ttlDays: policyProvider().ttlDays, now: now)
        if kept.count != all.count { persist(kept) }
    }

    /// 设置里调小了归档数上限 / TTL 后立刻生效:清过期 + 裁到当前归档数上限,而不是等下次打开才收缩。
    func applyCurrentLimits(now: Date = Date()) {
        let policy = policyProvider()
        var all = pruneExpired(loadAll(), ttlDays: policy.ttlDays, now: now)
        let cap = max(1, policy.maxArchives)
        if all.count > cap { all.removeLast(all.count - cap) }
        persist(all)
    }

    // MARK: - Private

    private func pruneExpired(_ all: [ArchiveListingCacheEntry], ttlDays: Int, now: Date) -> [ArchiveListingCacheEntry] {
        guard ttlDays > 0 else { return all } // 0 = 永不过期
        let cutoff = now.addingTimeInterval(-Double(ttlDays) * 86_400)
        return all.filter { $0.recordedAt >= cutoff }
    }

    private func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func persist(_ all: [ArchiveListingCacheEntry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
