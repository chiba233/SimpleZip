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

    /// 去重的非加密**文件名**(仅 basename,跳过目录条目),封顶 `limit` 条。供 #35 Spotlight 关键词等使用 ——
    /// 让用户搜一个文件名就能命中含它的归档。纯逻辑,可单测。
    func fileBaseNames(limit: Int = 1000) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for cached in entries where !cached.isDirectory {
            let base = (cached.name as NSString).lastPathComponent
            guard !base.isEmpty, seen.insert(base).inserted else { continue }
            result.append(base)
            if result.count >= limit { break }
        }
        return result
    }

    /// 非加密文件条目的**完整相对路径**(保留目录结构、**不去重**,跳过目录条目),封顶 `limit` 条。
    /// 给 Spotlight 结果描述用 —— 直接列出包里有哪些文件、各在什么路径,比去重 basename 的颗粒度更细。
    func filePaths(limit: Int = 24) -> [String] {
        var result: [String] = []
        for cached in entries where !cached.isDirectory {
            let path = cached.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }
            result.append(path)
            if result.count >= limit { break }
        }
        return result
    }

    /// 非加密文件条目总数(跳过目录)—— 描述里判断是否还有更多没列出。
    var fileEntryCount: Int {
        entries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
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

    /// 持久化体积上限(字节)。清单缓存改存独立文件后已无 CFPreferences 的 4 MB 单值硬上限,但仍设上限防单个缓存
    /// 文件无限膨胀(读 / 解码成本);persist 超限即从最旧归档起驱逐。
    static let maxPersistedByteCount = 2_500_000

    /// 清单缓存落盘的子目录(见 `AIDerivedDataStore` 的 `subdirectory`):与 AI 派生数据(`AIDerivedData`)分目录隔离。
    static let storeSubdirectory = "DerivedData"

    /// 持久化后端。**默认走文件存储**(`AIDerivedDataStore`,落盘 `Application Support/<bundle>/DerivedData/`),
    /// 绝不再进 `UserDefaults` 偏好域 —— 清单数据体量大(大包上万条目),进偏好会撑破 CFPreferences 的 4 MB 单值
    /// 硬上限、且整份 domain 随每次启动加载 / 每次写重序列化,拖垮启动(App Intents 后台 helper 因此连接超时 →
    /// Shortcuts 报「Couldn't communicate…」)。测试可注入内存 `UserDefaults`(也 conform
    /// `KeyValueDataStore`),无需碰盘。
    private let defaults: KeyValueDataStore
    private let storageKey = AppPreferences.Key.archiveListingCache
    private let policyProvider: @Sendable () -> ArchiveListingCachePolicy

    init(defaults: KeyValueDataStore = AIDerivedDataStore(subdirectory: ArchiveListingCacheStore.storeSubdirectory),
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

        let path = Self.canonicalPath(for: archiveURL)
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
        let target = Self.canonicalPath(for: URL(fileURLWithPath: archivePath))
        persist(loadAll().filter { $0.archivePath != target })
    }

    /// 清空整个缓存(设置「清空」按钮 / 关闭开关 / 恢复出厂时调)。
    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    /// 一次性迁移清理:历史版本把清单缓存写进了 `UserDefaults.standard`(无字节上限,撑到 4 MB+),撑爆
    /// CFPreferences 的 4 MB 单值硬上限后,主 domain 的任何写都 fault 并反复整体重序列化,拖垮每次启动 ——
    /// App Intents 后台 helper 因此没能在连接窗口内 ready,Shortcuts 报「Couldn't communicate with a helper
    /// application」(失败 helper 启动 0.9s 即被这坨拖到连接超时)。缓存现改存独立文件(见
    /// `defaults` 默认后端);**启动最早期**把遗留在 standard 的旧 key 删掉,主 domain plist 立刻缩回正常体积。
    /// 清单缓存可重建(下次打开归档自动重列),丢弃无害。幂等(无旧 key 则空操作)。
    static func purgeLegacyStandardStorage() {
        UserDefaults.standard.removeObject(forKey: AppPreferences.Key.archiveListingCache)
    }

    func count() -> Int { loadAll().count }

    /// 当前缓存占用的近似字节数(设置页展示用)。
    func storageByteSize() -> Int {
        defaults.data(forKey: storageKey)?.count ?? 0
    }

    /// Spotlight 索引「指纹没变就跳过」守卫的指纹源:文件后端里这份缓存的**原始持久化字节**。
    /// 清单缓存已迁出 `UserDefaults.standard`(见 `purgeLegacyStandardStorage`),且启动最早期就把遗留的
    /// standard key 删掉 —— 指纹必须读**文件后端**,否则永远 `"empty"`(缓存再怎么变 Spotlight 也不重建)。
    /// 对标活动历史指纹源 `TaskCenter.loadActivityHistoryData()`。
    func persistedFingerprintData() -> Data? {
        defaults.data(forKey: storageKey)
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

    /// 规范化磁盘路径(去符号链接 + standardized)—— 去重主键。indexer / 模型增量索引也要用同一口径定位条目。
    static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func persist(_ all: [ArchiveListingCacheEntry]) {
        // 字节上限治理:编码后若超 `maxPersistedByteCount`,从最旧归档(数组尾)起逐个驱逐再重编码,直到落在上限内
        // —— 归档「条数」上限管不住「一个上万条目的大包单独撑大」,这里补「字节」上限兜底。
        var entries = all
        while true {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            if data.count <= Self.maxPersistedByteCount || entries.count <= 1 {
                defaults.set(data, forKey: storageKey)
                return
            }
            entries.removeLast()
        }
    }
}
