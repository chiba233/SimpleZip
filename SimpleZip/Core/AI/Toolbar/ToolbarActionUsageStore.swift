//
//  ToolbarActionUsageStore.swift
//  SimpleZip
//
//  0.4.5 #80 建议七:工具栏动作的**本地习惯统计**。记用户在每种「选择上下文」里实际点过哪个工具栏推荐动作,
//  供「AI 关 → 习惯性排序」直接用,也作为「AI 开 → 预烘焙排序」的习惯权重输入(都喂 `AINextActionRanker`)。
//
//  隐私(见隐私口径):bucket 只含**模式 + 选择形态 + 主导扩展名**(如 `folder|2+|zip`),不含任何路径 / 文件名 /
//  内容;只计 actionID 的点击次数。全本地、不外发。受「允许使用统计」开关 gate。这是本地频率启发式(非模型)。
//
//  与 App 共享偏好域:App 用默认 `.standard`(= App bundle id 域);后台 agent 预烘焙时按
//  `UserDefaults(suiteName: AIAgentConfiguration.appBundleID)` 读同一份(A19)。App 内只在主线程触碰。
//

import Foundation

/// 工具栏动作点击统计:`contextBucket → actionID → 点击次数`。内存缓存一份,record / clear 同步更新并持久化。
nonisolated final class ToolbarActionUsageStore {
    typealias Counts = [String: [String: Int]]

    /// App 内共享一份(工具栏点击 + 右键菜单 catalog 动作点击都记进这里;后台 agent 预烘焙另起实例按 suiteName 读)。
    /// `@MainActor`:只在主线程触碰(SwiftUI body + 菜单 selector 都在主线程);测试 / agent 各用 init 自己的实例。
    @MainActor static let shared = ToolbarActionUsageStore()

    /// 桶数量上限 —— 超了丢点击总数最少的桶(冷上下文),避免无限增长。
    private static let maxBuckets = 240

    private let defaults: KeyValueDataStore
    private let storageKey: String
    private var cache: Counts?

    init(defaults: KeyValueDataStore = UserDefaults.standard,
         storageKey: String = AppPreferences.Key.toolbarActionUsageStats) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// 记一次工具栏推荐动作的点击(开关 gate 双查一次)。
    func record(actionID: String, in snapshot: ContextualToolbarSnapshot) {
        guard AppPreferences.toolbarActionUsageTrackingEnabled else { return }
        let bucket = Self.contextBucket(for: snapshot)
        var counts = load()
        counts[bucket, default: [:]][actionID, default: 0] += 1
        if counts.count > Self.maxBuckets {
            counts = Self.evictColdestBuckets(counts, keeping: Self.maxBuckets)
        }
        persist(counts)
    }

    /// 当前上下文的习惯信号(只填 `clicked`;完成 / 忽略 / 失败工具栏不可靠采集,留默认 0)。
    func usageSignals(for snapshot: ContextualToolbarSnapshot) -> [AIActionUsageSignal] {
        let bucket = Self.contextBucket(for: snapshot)
        guard let perAction = load()[bucket], !perAction.isEmpty else { return [] }
        return perAction.map { AIActionUsageSignal(actionID: $0.key, clicked: $0.value) }
    }

    func clear() {
        cache = [:]
        defaults.removeObject(forKey: storageKey)
    }

    /// 只读调试导出:全部 `桶 → 动作 → 次数`(DevTools 查「右键习惯有没有进数据」用)。
    func debugAllCounts() -> Counts { load() }

    // MARK: - 上下文桶

    /// 稳定的选择上下文 key:模式 + 选择数量档 + 主导类型(全本地、无路径)。同种选择形态聚到同一桶。
    static func contextBucket(for snapshot: ContextualToolbarSnapshot) -> String {
        switch snapshot.mode {
        case .archive:
            return "archive|\(countBucket(snapshot.selectedArchiveItemCount))"
        case .folder, .tag:
            let mode = snapshot.mode.rawValue
            if snapshot.selectedFiles.isEmpty { return "\(mode)|empty" }
            // 复选(≥2):统一一个桶,不按后缀细分(用户拍板:勾选很多文件即使同后缀也别那么细)。
            // 池子外的习惯信号会被白名单候选池自动忽略,所以共享桶不会让不支持的动作冒出灰按钮。
            if snapshot.selectedFiles.count >= 2 { return "\(mode)|multi" }
            // 单选:按类型 / 后缀细分(配合 AI 文件级 / 类型级烘焙颗粒度)。
            return "\(mode)|1|\(dominantKind(snapshot.selectedFiles))"
        case .aiWorkspace:
            return "aiWorkspace"
        }
    }

    private static func countBucket(_ n: Int) -> String {
        n <= 0 ? "0" : (n == 1 ? "1" : "2+")
    }

    /// 主导类型:全目录 → `dir`;全部同一扩展名 → 该扩展名;否则 `mixed`。
    private static func dominantKind(_ files: [ContextualToolbarSnapshot.SelectedFile]) -> String {
        if files.allSatisfy({ $0.isDirectory }) { return "dir" }
        let exts = Set(files.filter { !$0.isDirectory }.map { $0.pathExtension })
        if exts.count == 1, let only = exts.first { return only.isEmpty ? "noext" : only }
        return "mixed"
    }

    private static func evictColdestBuckets(_ counts: Counts, keeping limit: Int) -> Counts {
        let ranked = counts.sorted { lhs, rhs in
            let l = lhs.value.values.reduce(0, +)
            let r = rhs.value.values.reduce(0, +)
            return l != r ? l > r : lhs.key < rhs.key
        }
        return Counts(uniqueKeysWithValues: ranked.prefix(limit).map { ($0.key, $0.value) })
    }

    // MARK: - 持久化

    private func load() -> Counts {
        if let cache { return cache }
        guard let data = defaults.data(forKey: storageKey),
              let counts = try? JSONDecoder().decode(Counts.self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = counts
        return counts
    }

    private func persist(_ counts: Counts) {
        cache = counts
        guard let data = try? JSONEncoder().encode(counts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
