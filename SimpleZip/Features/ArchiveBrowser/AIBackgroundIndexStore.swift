//
//  AIBackgroundIndexStore.swift
//  SimpleZip
//
//  0.4.5 #80 #89:后台 AI 预索引的 **opt-in 白名单 + 持久文件索引** store(白皮书工程补充六)。
//
//  ⚠️ 全程 **opt-in、白名单、只读、可清空**:活跃度默认 `off`、两个开关默认 false —— 不开则后台**完全不扫**任何
//  目录。用户从「推荐安全目录」确认后才把目录加入白名单(`AIArchivePrefetchScope`)。本 store 只持有白名单 +
//  持久文件索引(`AIFileMemoryIndex`)+ 清空;真正的只读扫描由 `AIBackgroundIndexer` 做(security-sensitive)。
//
//  持久:白名单(用户配置)+ 文件索引(派生数据,**只元数据 / 无绝对路径内容**,恢复出厂 / 清空时清掉)。
//

import Combine
import Foundation

@MainActor
final class AIBackgroundIndexStore: ObservableObject {
    static let shared = AIBackgroundIndexStore()

    /// 白名单目录(用户确认后加入)。
    @Published private(set) var scopes: [AIArchivePrefetchScope]
    /// 持久文件预索引(体量可能大,不 `@Published`;变更后手动发 `objectWillChange`)。
    private(set) var fileIndex: AIFileMemoryIndex

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scopes = AIBackgroundIndexStore.loadScopes(from: defaults)
        self.fileIndex = AIBackgroundIndexStore.loadIndex(from: defaults)
    }

    // MARK: - opt-in 门控(白皮书:不开则完全不跑)

    /// AI 主开关 + 活跃度非 off。
    var backgroundEnabled: Bool {
        AppPreferences.aiAssistantEnabled && AppPreferences.aiBackgroundActivityLevel != .off
    }
    /// 是否允许后台预索引文件夹**元数据**(主开关 + 活跃度 + 该子开关 + 有白名单目录)。只元数据,绝不读内容。
    var folderPreindexEnabled: Bool {
        backgroundEnabled && AppPreferences.aiAllowFolderPreindex && !scopes.isEmpty
    }
    /// 是否允许后台**预读内容**(文档内容摘要 + 压缩包内条目清单)。比元数据预索引**更高隐私等级**,独立 opt-in。
    var contentPrereadEnabled: Bool {
        backgroundEnabled && AppPreferences.aiAllowContentPreread && !scopes.isEmpty
    }
    /// 后台扫描总闸:开了元数据预索引**或**内容预读任一就扫白名单(内容预读需要先扫到文件才能读其内容)。
    var indexingEnabled: Bool {
        backgroundEnabled && !scopes.isEmpty
            && (AppPreferences.aiAllowFolderPreindex || AppPreferences.aiAllowContentPreread)
    }
    /// 是否允许后台预读归档清单 —— 归并进「预读内容」这一更高隐私等级开关(文件内容 + 压缩包内容同一档)。
    var archivePrefetchEnabled: Bool { contentPrereadEnabled }
    /// 当前活跃度对应的预算(off → nil)。
    var budget: AIArchivePrefetchBudget? {
        AIArchivePrefetchBudget.forLevel(AppPreferences.aiBackgroundActivityLevel)
    }

    // MARK: - 白名单 CRUD

    func contains(directory: URL) -> Bool {
        let std = directory.standardizedFileURL.path
        return scopes.contains { $0.directoryPath == std }
    }

    /// 加入白名单(去重;路径标准化)。`origin` 标明来源(建议安全目录 / 用户添加 / 固定 / 项目)。
    func addScope(directory: URL, origin: AIArchivePrefetchScope.Origin,
                  recursive: Bool = true, maxDepth: Int = 4) {
        let std = directory.standardizedFileURL
        guard !contains(directory: std) else { return }
        let scope = AIArchivePrefetchScope(
            id: UUID(), directoryPath: std.path, origin: origin, recursive: recursive,
            maxDepth: max(1, maxDepth), includeExternalVolumes: false, includeNetworkVolumes: false,
            createdAt: Date(), lastScannedAt: nil)
        scopes.append(scope)
        persistScopes()
    }

    /// 移除白名单目录 —— **同时清掉该 scope 的所有预索引记录**(白皮书:清空不删真实文件)。
    func removeScope(_ id: UUID) {
        guard scopes.contains(where: { $0.id == id }) else { return }
        scopes.removeAll { $0.id == id }
        fileIndex = fileIndex.clearingScope(id)
        persistScopes()
        persistIndex()
        objectWillChange.send()
    }

    /// 记录某 scope 扫完的时间。
    func markScanned(_ id: UUID, at date: Date) {
        guard let i = scopes.firstIndex(where: { $0.id == id }) else { return }
        let s = scopes[i]
        scopes[i] = AIArchivePrefetchScope(
            id: s.id, directoryPath: s.directoryPath, origin: s.origin, recursive: s.recursive,
            maxDepth: s.maxDepth, includeExternalVolumes: s.includeExternalVolumes,
            includeNetworkVolumes: s.includeNetworkVolumes, createdAt: s.createdAt, lastScannedAt: date)
        persistScopes()
    }

    // MARK: - 索引写入(扫描器调用)/ 读取(发现编排者调用)

    /// 扫描器把一批文件记录 + 文件夹画像写入索引(替换该 scope 上一轮的记录前先清,再 upsert）。
    func ingest(records: [AIFileMemoryRecord], folders: [AIFolderProfile], scopeID: UUID, at date: Date) {
        fileIndex = fileIndex
            .clearingScope(scopeID)
            .upserting(records, scopeID: scopeID, at: date)
            .upsertingFolders(folders)
        persistIndex()
        objectWillChange.send()
    }

    /// 供发现编排者组装候选(最近索引的 N 条文件记录)。
    func recentFileRecords(limit: Int = 2_000) -> [AIFileMemoryRecord] {
        fileIndex.recentRecords(limit: limit)
    }

    /// 已有内容摘要的记录(id → 记录),给渐进式预读做「指纹(大小+修改时间)没变就沿用旧摘要、不重读」判断。
    func summarizedRecordsByID() -> [String: AIFileMemoryRecord] {
        var out: [String: AIFileMemoryRecord] = [:]
        for rec in fileIndex.records where rec.contentSummary != nil { out[rec.id] = rec }
        return out
    }

    /// source ref → 真实路径(给 AI 文件夹节点动作 + 显示来源目录用)。直接读持久记录的 `path`(非加密路径不是
    /// 风险,可落盘)→ 启动即可用,不必等重扫。ref 由记录的 `contextSourceRef` 派生 → 与候选 ref 一致。
    func pathsBySourceRef(limit: Int = 4_000) -> [AIContextSourceRef: String] {
        var map: [AIContextSourceRef: String] = [:]
        for record in fileIndex.recentRecords(limit: limit) {
            if let path = record.path { map[record.contextSourceRef] = path }
        }
        return map
    }

    // MARK: - 清空(白皮书 4533)

    /// 清空后台文件预索引(文件夹画像 / 文件元数据 / 摘要),不删任何真实文件。
    func clearFileIndex() {
        fileIndex = fileIndex.cleared()
        persistIndex()
        objectWillChange.send()
    }

    // MARK: - 持久化

    private func persistScopes() {
        if let data = try? JSONEncoder().encode(scopes) {
            defaults.set(data, forKey: AppPreferences.Key.aiBackgroundIndexScopes)
        }
    }

    private func persistIndex() {
        if let data = try? JSONEncoder().encode(fileIndex) {
            defaults.set(data, forKey: AppPreferences.Key.aiFileMemoryIndexData)
        }
    }

    private static func loadScopes(from defaults: UserDefaults) -> [AIArchivePrefetchScope] {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiBackgroundIndexScopes),
              let decoded = try? JSONDecoder().decode([AIArchivePrefetchScope].self, from: data)
        else { return [] }
        return decoded
    }

    private static func loadIndex(from defaults: UserDefaults) -> AIFileMemoryIndex {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiFileMemoryIndexData),
              let decoded = try? JSONDecoder().decode(AIFileMemoryIndex.self, from: data)
        else { return AIFileMemoryIndex() }
        return decoded
    }
}
