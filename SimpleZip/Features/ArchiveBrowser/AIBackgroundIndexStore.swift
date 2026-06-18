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

nonisolated struct CachedFolderGroup: Codable, Equatable, Sendable {
    let title: String?
    let memberPaths: [String]
    let actionToken: String
}

@MainActor
final class AIBackgroundIndexStore: ObservableObject {
    static let shared = AIBackgroundIndexStore()

    /// 白名单目录(用户确认后加入)。
    @Published private(set) var scopes: [AIArchivePrefetchScope]
    /// 持久文件预索引(体量可能大,不 `@Published`;变更后手动发 `objectWillChange`)。
    private(set) var fileIndex: AIFileMemoryIndex {
        didSet {
            fileIndexGeneration += 1
            rebuildPathIndex()
        }
    }
    /// 文件索引内容世代。文件表把它纳入内容指纹,让按需回填能重建已展开抽屉。
    private(set) var fileIndexGeneration = 0

    /// `path → 记录` 缓存(文件浏览器每行 O(1) 查模型建议用)。fileIndex 变更后由 `didSet` 自动重建。
    private var recordByPath: [String: AIFileMemoryRecord] = [:]

    /// 用户对 AI 建议「我不喜欢」的抑制 key 集合(右键「我不喜欢」加入)。文件浏览器抽屉据此过滤掉被嫌弃的建议。
    /// 持久(派生数据,不进偏好备份)。
    @Published private(set) var dislikedSuggestionKeys: Set<String>
    /// 文件夹批量分组建议缓存。key = 文件夹真实路径;空数组也表示「已评估,无建议」。
    private(set) var folderGroupsByPath: [String: [CachedFolderGroup]]
    /// 文件夹分组缓存内容世代。FileTable 纳入内容指纹,让后台 pass 写缓存后追加组行,但不把字典设成 @Published。
    private(set) var folderGroupsGeneration = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scopes = AIBackgroundIndexStore.loadScopes(from: defaults)
        self.fileIndex = AIBackgroundIndexStore.loadIndex(from: defaults)
        self.dislikedSuggestionKeys = AIBackgroundIndexStore.loadDislikedKeys(from: defaults)
        self.folderGroupsByPath = AIBackgroundIndexStore.loadFolderGroups(from: defaults)
        rebuildPathIndex()   // init 里的 fileIndex 赋值不触发 didSet,手动建一次
    }

    // MARK: - AI 建议「我不喜欢」抑制(右键反馈)

    /// 一条建议的抑制 key:`recordID \n token \n payload`(payload 区分同 token 多条,如归档多个 revealArchiveEntry)。
    nonisolated static func dislikeKey(recordID: String, token: String, payload: String?) -> String {
        "\(recordID)\n\(token)\n\(payload ?? "")"
    }

    /// 一句话摘要行的抑制 key(整条摘要,不分 token)。
    nonisolated static func summaryDislikeKey(recordID: String) -> String { "\(recordID)\n__summary__" }

    /// 文件夹级 AI 组建议的抑制 key:只压这一组(同一目录 + 同一动作 + 同一成员集合),不全局封掉动作 token。
    nonisolated static func folderGroupDislikeKey(folderPath: String, actionToken: String, memberPaths: [String]) -> String {
        let folder = normalizedFolderPath(folderPath)
        let members = memberPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
        return "\(folder)\n__folderGroup__\n\(actionToken)\n\(members)"
    }

    func isSuggestionDisliked(_ key: String) -> Bool { dislikedSuggestionKeys.contains(key) }

    /// 记一条「我不喜欢」→ 加入抑制集 + 落盘 + 通知(文件浏览器下次 reload 过滤掉它)。
    func dislikeSuggestion(_ key: String) {
        guard dislikedSuggestionKeys.insert(key).inserted else { return }
        persistDislikedKeys()
        objectWillChange.send()
    }

    /// 从当前 fileIndex 重建 `path → 记录` 缓存(只收带路径的记录;同路径取最近索引那条)。
    private func rebuildPathIndex() {
        var map: [String: AIFileMemoryRecord] = [:]
        for record in fileIndex.records { if let path = record.path { map[path] = record } }
        recordByPath = map
    }

    /// 按真实路径查一条预索引记录(文件浏览器 AI 抽屉读模型建议用)。O(1)。
    func record(forPath path: String) -> AIFileMemoryRecord? { recordByPath[path] }

    func folderGroups(forPath folderPath: String) -> [CachedFolderGroup] {
        folderGroupsByPath[Self.normalizedFolderPath(folderPath)] ?? []
    }

    func setFolderGroups(_ groups: [CachedFolderGroup], forPath folderPath: String) {
        let key = Self.normalizedFolderPath(folderPath)
        folderGroupsByPath[key] = groups
        folderGroupsGeneration += 1
        persistFolderGroups()
        objectWillChange.send()
    }

    private nonisolated static func normalizedFolderPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

    /// ②b/②c:后台模型对一条已预读记录产出**一句话摘要 + 建议动作 token** 后回填进它的 `contentSummary`。
    /// 仅当该记录已有结构摘要(预读过)才写;`摘要为空且无动作` 不写(避免把「模型啥也没说」当结果缓存)。
    /// scopeID / indexedAt 不变(`updatingRecord`),不扰渐进覆盖指纹。落盘 + 通知(文件浏览器下次 reload 显示)。
    func applyModelSuggestion(recordID: String, summary: String?, actions: [AIFileSuggestedAction]) {
        let cleanSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = cleanSummary?.isEmpty == false
        guard hasSummary || !actions.isEmpty else { return }
        guard let existing = fileIndex.records.first(where: { $0.id == recordID })?.contentSummary else { return }
        let updated = existing.withModelSuggestion(summary: hasSummary ? cleanSummary : nil, actions: actions)
        fileIndex = fileIndex.updatingRecord(id: recordID) { $0.withContentSummary(updated) }
        persistIndex()
        objectWillChange.send()
    }

    /// **磁盘镜像安装建议**回填(推荐打开方式 backlog 第2项)。dmg 从不内容预读 → 记录本无 `contentSummary`,这里
    /// **新建一条** `disk-image` 摘要承载结果:`appName` 非空 → 加一条 `dragToApplications` 动作(payload/label = App 名);
    /// 都为空 = 「评估过、没建议」(标记已评估,下轮 `selectDiskImagesForSuggestion` 不再选,指纹变了阶段一清回才重选)。
    /// 落盘 + 通知。**不碰磁盘镜像本体**。
    func setDiskImageSuggestion(recordID: String, summary: String?, appName: String?) {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = clean?.isEmpty == false
        var actions: [AIFileSuggestedAction] = []
        if let appName, !appName.isEmpty {
            actions.append(AIFileSuggestedAction(token: "dragToApplications", payload: appName, label: appName))
        }
        let content = AIFileContentSummary(mode: "disk-image",
                                           shortSummary: hasSummary ? clean : nil, suggestedActions: actions)
        fileIndex = fileIndex.updatingRecord(id: recordID) { $0.withContentSummary(content) }
        persistIndex()
        objectWillChange.send()
    }

    /// **「文件有活动」建议**回填(backlog 第3项)。把「查看活动:〔模型措辞〕」动作(token `openTask`,
    /// payload = 任务 UUID,label = 模型一句话措辞)**合并**进记录的 contentSummary —— 不动摘要 / 其它 pass 写的动作;
    /// 记录没 contentSummary(归档等没预读)→ 建一条最小 `activity` 摘要承载。`taskID` 为 nil = 清掉活动动作。
    /// 导航复用现成 `.openTask` 路由(Spotlight 同款),零新代码。落盘 + 通知。
    func applyActivitySuggestion(recordID: String, taskID: UUID?, phrasing: String?) {
        let clean = phrasing?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhrasing = clean?.isEmpty == false
        let action: AIFileSuggestedAction? = taskID.map {
            AIFileSuggestedAction(token: "openTask", payload: $0.uuidString, label: hasPhrasing ? clean : nil)
        }
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "activity")
            return rec.withContentSummary(
                base.mergingSingletonAction(action, replacingToken: "openTask",
                                            shortSummaryIfEmpty: hasPhrasing ? clean : nil))
        }
        persistIndex()
        objectWillChange.send()
    }

    /// **压缩包「你可能需要的文件」**回填(backlog 第4项)。归档从不内容预读 → 记录本无 `contentSummary`,这里**新建一条**
    /// `archive-entries` 摘要承载模型挑的 `revealArchiveEntry` 动作(payload = 包内条目相对路径,label = 文件名)。
    /// **总是建一条**(actions 可空)以标记「已评估」,下轮不再选(归档变了阶段一清回才重选)。落盘 + 通知。**不解压**。
    func applyArchiveEntrySuggestion(recordID: String, actions: [AIFileSuggestedAction]) {
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "archive-entries")
            return rec.withContentSummary(base.mergingArchiveEntryActions(actions))
        }
        persistIndex()
        objectWillChange.send()
    }

    /// **归档行内定性**回填:模型据归档清单给一句「这看起来是什么包」。`archiveKind` 是不可见 marker,
    /// 用于 DevTools 计数 / 避免重复评估;UI 显示走 `shortSummary` 摘要行,没有额外按钮。
    func applyArchiveKindGuess(recordID: String, summary: String?) {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = clean?.isEmpty == false
        let marker = AIFileSuggestedAction(token: "archiveKind")
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "archive-kind")
            return rec.withContentSummary(
                base.mergingSingletonAction(marker, replacingToken: "archiveKind",
                                            shortSummaryIfEmpty: hasSummary ? clean : nil))
        }
        persistIndex()
        objectWillChange.send()
    }

    /// **文本 URL 打开建议**回填:URL 来自 App 从已脱敏预读文本正则抽取的真实 http(s) URL;模型只选编号。
    /// payload 保存真实 URL,label 保存展示名。没有模型选择就不调用本方法,保持空抽屉/无假建议。
    func applyURLOpenSuggestion(recordID: String, url: String, label: String?) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = AIFileSuggestedAction(token: "urlOpen", payload: cleanURL,
                                           label: cleanLabel?.isEmpty == false ? cleanLabel : nil)
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "url-open")
            return rec.withContentSummary(base.mergingSingletonAction(action, replacingToken: "urlOpen"))
        }
        persistIndex()
        objectWillChange.send()
    }

    /// 把用户触发的只读按需结果回填到记录里(`hash` / 后续 `test` / `inspect` 复用同一机制)。
    func applyInlineResult(recordID: String, token: String, text: String) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanText.isEmpty else { return }
        guard let record = fileIndex.records.first(where: { $0.id == recordID }) else { return }
        let base = record.contentSummary ?? AIFileContentSummary(mode: "inline-result")
        guard base.inlineResults[cleanToken] != cleanText else { return }
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            rec.withContentSummary(base.withInlineResult(token: cleanToken, text: cleanText))
        }
        persistIndex()
        objectWillChange.send()
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
    /// #8:跨表面反馈 / 兴趣信号也是后台 AI 派生学习数据 → 一并抹掉(隐私:可清空)。
    func clearFileIndex() {
        fileIndex = fileIndex.cleared()
        folderGroupsByPath = [:]
        folderGroupsGeneration += 1
        persistIndex()
        persistFolderGroups()
        AIFeedbackStore.shared.clearAll()
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

    private func persistDislikedKeys() {
        if let data = try? JSONEncoder().encode(Array(dislikedSuggestionKeys)) {
            defaults.set(data, forKey: AppPreferences.Key.aiSuggestionDislikedKeys)
        }
    }

    private func persistFolderGroups() {
        if let data = try? JSONEncoder().encode(folderGroupsByPath) {
            defaults.set(data, forKey: AppPreferences.Key.aiFolderGroupsData)
        }
    }

    private static func loadDislikedKeys(from defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiSuggestionDislikedKeys),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    private static func loadFolderGroups(from defaults: UserDefaults) -> [String: [CachedFolderGroup]] {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiFolderGroupsData),
              let decoded = try? JSONDecoder().decode([String: [CachedFolderGroup]].self, from: data)
        else { return [:] }
        return decoded
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
