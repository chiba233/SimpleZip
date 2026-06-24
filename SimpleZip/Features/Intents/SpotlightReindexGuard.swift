//
//  SpotlightReindexGuard.swift
//  SimpleZip
//
//  0.4.5 启动卡顿修复:Spotlight 索引**持久化 + 指纹没变就整轮跳过**（启动冷启动卡顿主因）。
//
//  以前每次冷启动 6 个索引器各自 `Task.detached` 并发**全量删 + 全量写**(如 20 个归档 × 每包 400 文件 =
//  8000 条 CSSearchableItem),没有任何「上次已索引、数据没变就跳过」守卫 → 6 路 IPC 同时砸 `corespotlightd`,
//  和首帧渲染抢资源。
//
//  修法两件:① **指纹守卫**(本文件):每个索引器先算一个**廉价指纹**(源数据的原始 UserDefaults Data 哈希,
//  或静态目录的 app 版本)—— 指纹和上次落盘的一样就**直接返回**,不解码、不建项、不打 IPC。② **串行协调器**
//  (`SpotlightStartupCoordinator`):启动只起**一个** detached 任务,6 个索引器**顺序 await**,不再并发砸 daemon。
//

import Foundation

/// Spotlight 索引**电源档**(用户:不能这么激进,慢慢索引也没事,只求后台占用低)。控制「重查间隔(有效期)」+
/// 「是否实时增量」。**任何档位都不保证不漏更新 / 不及时** —— 优先级是低后台占用。从 `AppPreferences` 读 raw。
nonisolated enum SpotlightIndexingPower: String, Equatable, CaseIterable, Sendable {
    case saver        // 省电:索引存在就一天才查一次更新;不做实时增量(靠周期重查兜底)。
    case normal       // 普通:约一小时才重查一次;实时增量开。
    case highPower    // 高耗能:每次都查;文件 / 缓存一改近实时更新索引。

    static var current: SpotlightIndexingPower {
        SpotlightIndexingPower(rawValue: AppPreferences.spotlightIndexingPowerRaw) ?? .normal
    }

    /// 冷启动 / 重查的最小间隔(秒)。间隔内不重查(连指纹都不算)→ 省电模式后台几乎不动。
    var recheckInterval: TimeInterval {
        switch self {
        case .saver: return 24 * 60 * 60      // 一天
        case .normal: return 60 * 60          // 一小时
        case .highPower: return 0             // 每次都查
        }
    }

    /// 是否允许「文件 / 缓存一改就实时增量更新索引」。省电关掉 —— 靠周期重查兜底,后台不被频繁增量打扰。
    var allowsRealtimeIncremental: Bool { self != .saver }
}

/// Spotlight 索引的「指纹没变就跳过」持久化守卫。指纹存 `UserDefaults.standard`(轻量,跟随版本 / 数据变化)。
nonisolated enum SpotlightReindexGuard {
    private static let prefix = "SimpleZip.spotlight.indexedFingerprint."
    private static let checkedPrefix = "SimpleZip.spotlight.lastCheckedAt."

    /// **电源档时间闸**:距上次「查过有没有更新」还没到电源档的重查间隔 → 跳过(连指纹都不算)。
    /// 省电模式下一天才会真正去查一次,其余冷启动几乎零成本。`interval == 0`(高耗能)→ 每次都查。
    static func shouldCheckNow(key: String, interval: TimeInterval, now: Date = Date()) -> Bool {
        guard interval > 0 else { return true }
        let last = UserDefaults.standard.double(forKey: checkedPrefix + key)   // 0 = 从没查过
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    /// 记录「这一轮查过了」(无论数据变没变)—— 下次在间隔内就跳过。
    static func markChecked(key: String, now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: checkedPrefix + key)
    }

    /// 这个索引器的源数据指纹和上次成功索引时一样吗?一样 → 调用方应跳过整轮重建。
    static func isUpToDate(key: String, fingerprint: String) -> Bool {
        UserDefaults.standard.string(forKey: prefix + key) == fingerprint
    }

    /// 成功重建后记录本次指纹(下次冷启动据此跳过)。
    static func markIndexed(key: String, fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: prefix + key)
    }

    /// 清空记录(索引被清 / 开关关掉时调 —— 这样重新开启后下一轮一定会重建)。
    static func reset(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    /// 一段原始字节的**稳定**指纹(FNV-1a 64-bit,跨进程一致 —— 不能用 `Data.hashValue`,它每次启动加盐)。
    /// 给「源数据是 UserDefaults JSON」的索引器用:读原始 Data 直接哈希,不必先 JSON 解码。
    static func fingerprint(of data: Data?) -> String {
        guard let data, !data.isEmpty else { return "empty" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16) + "-" + String(data.count)
    }

    /// 某个 `UserDefaults.standard` JSON key 的源数据指纹(给数据驱动的索引器:归档缓存 / 发布账本 / 活动历史)。
    static func fingerprint(ofStandardKey key: String) -> String {
        fingerprint(of: UserDefaults.standard.data(forKey: key))
    }

    /// 静态目录(设置项 / 活动选项)的指纹 = app 构建版本 **+ 界面语言**。内容由代码生成、标题本地化,
    /// 所以版本更新(目录可能加项)或语言切换(标题变文案)都得重建,其余冷启动跳过。
    static var appVersionFingerprint: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?")-\(info?["CFBundleVersion"] as? String ?? "?")"
        let language = UserDefaults.standard.string(forKey: "appLanguage")
            ?? Bundle.main.preferredLocalizations.first ?? "en"
        return version + ":" + language
    }
}

/// 冷启动 Spotlight 重建的**串行协调器**(启动卡顿修复)。以前 AppDelegate 一口气起 6 个 `Task.detached` 并发砸
/// `corespotlightd`;改成**只起一个**后台任务,6 个索引器顺序 `await`。各索引器内部有「指纹没变就跳过」守卫,
/// 所以数据没变的冷启动几乎是空操作(每个只读一次 Data 哈希,不解码 / 不建项 / 不打 IPC)。
nonisolated enum SpotlightStartupCoordinator {
    static func reindexAllOnLaunch() {
        Task.detached(priority: .utility) {
            guard #available(macOS 15.0, *) else { return }
            // 顺序 await:一个跑完再跑下一个,daemon 不被并发 IPC 淹没。轻(账本/任务/设置/活动)在前、
            // 重(归档逐文件,可能上千条)在后,让便宜的先落地。
            await ReleasePackageSpotlightIndexer.reindexIfNeeded()
            await ArchiveTaskSpotlightIndexer.reindexIfNeeded()
            await SettingsSpotlightIndexer.reindexIfNeeded()
            await ActivitySpotlightIndexer.reindexIfNeeded()
            await CachedArchiveSpotlightIndexer.reindexIfNeeded()
            await ArchiveFileSpotlightIndexer.reindexIfNeeded()
        }
    }
}
