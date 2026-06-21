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

// 派生缓存值类型(CachedFolderGroup / CachedChipRanking / CachedExplanation / CachedClusterChip(s))
// 已下沉 Core → SimpleZip/Core/AI/AIDerivedCaches.swift,供 App 前台 + 后台 agent 共用同一布局。

// `AIDerivedDataStore`(派生数据独立文件存储)已下沉 Core → SimpleZip/Core/AI/AIDerivedDataStore.swift,
// 供 App 与 agent 共用同一布局(阶段2 后台索引迁 agent 后 agent 也按同一份读写派生数据)。

@MainActor
final class AIBackgroundIndexStore: ObservableObject {
    static let shared = AIBackgroundIndexStore()

    /// 白名单目录(用户确认后加入)。
    @Published private(set) var scopes: [AIArchivePrefetchScope]
    /// 持久文件预索引(体量可能大,不 `@Published`;变更后手动发 `objectWillChange`)。
    private(set) var fileIndex: AIFileMemoryIndex {
        // path→记录 缓存随索引变更重建(浏览器按 path O(1) 查建议)。
        // 不再维护全局「文件索引世代」:文件表的 reload 指纹只看**当前可见行**的建议内容(见 FileTable.syncContent),
        // 后台心跳每轮 ingest 重写 scope 元数据 / 给别处烤建议都不该 reload 用户正看的文件夹(否则闪烁,A17)。
        didSet { rebuildPathIndex() }
    }

    /// `path → 记录` 缓存(文件浏览器每行 O(1) 查模型建议用)。fileIndex 变更后由 `didSet` 自动重建。
    private var recordByPath: [String: AIFileMemoryRecord] = [:]

    /// 用户对 AI 建议「我不喜欢」的抑制 key 集合(右键「我不喜欢」加入)。文件浏览器抽屉据此过滤掉被嫌弃的建议。
    /// 持久(派生数据,不进偏好备份)。
    @Published private(set) var dislikedSuggestionKeys: Set<String>
    /// 文件夹批量分组建议缓存。key = 文件夹真实路径;空数组也表示「已评估,无建议」。
    private(set) var folderGroupsByPath: [String: [CachedFolderGroup]]
    /// 文件夹分组缓存内容世代。FileTable 纳入内容指纹,让后台 pass 写缓存后追加组行,但不把字典设成 @Published。
    private(set) var folderGroupsGeneration = 0
    /// Task 7「整理进新文件夹」建议缓存。key = 文件夹真实路径;每个文件夹**至多一条**(成员空的哨兵 = 已评估但无
    /// 建议,区分「键缺失」= 未评估)。`title` 承载模型起的主题文件夹名,`actionToken` = "organize"。
    private(set) var organizeByPath: [String: CachedFolderGroup]
    /// 整理建议缓存世代(ContentView 顶部建议条据此 + objectWillChange 重算;不把字典设成 @Published)。
    private(set) var organizeGeneration = 0
    /// 建议六 v2 模块⑤:活动中心「建议筛选」chip 的模型排序缓存。key = 任务分类 rawValue(archive / fileOperation /
    /// undoRedo);后台预烘焙、幂等(指纹没变不重排)、前台只读。
    private(set) var workbenchChipRankingByCategory: [String: CachedChipRanking]
    /// 排序缓存世代(活动中心工作台据此 + objectWillChange 重算;不把字典设成 @Published)。
    private(set) var workbenchChipRankingGeneration = 0
    /// 建议六 v2 模块1:活动中心「需要处理」卡的 AI 解读缓存。key = 任务分类 rawValue;后台预烘焙、幂等(未读失败集
    /// 没变不重生成)、前台只读。
    private(set) var workbenchNeedsAttentionByCategory: [String: CachedExplanation]
    /// 建议六 v2 模块①:活动中心失败任务的「失败解释」缓存。key = 任务 id(UUID string);后台预烘焙、幂等(失败诊断
    /// 没变不重生成)、随活失败任务集修剪(历史不无限累积)、前台只读。
    private(set) var workbenchFailureExplanationByTask: [String: CachedExplanation]
    /// 模块1 / ① 解读缓存世代(活动中心工作台据此 + objectWillChange 重算;不把字典设成 @Published)。
    private(set) var workbenchExplanationGeneration = 0
    /// 建议六 v2「真建议」chip 缓存。key = 任务分类 rawValue;后台预烘焙、幂等(真实聚集指纹没变不重命名)、前台只读。
    private(set) var workbenchClusterChipsByCategory: [String: CachedClusterChips]
    private(set) var workbenchClusterChipsGeneration = 0

    /// 建议七 Phase2:工具栏动作的 AI 预烘焙排序(后台 agent 写派生缓存,前台 init 载入只读;in-memory 查,不每渲染读盘)。
    private(set) var toolbarRanking: AIToolbarRanking

    private let defaults: UserDefaults
    /// 阶段0a:派生数据(索引本体 + 下游预烘焙缓存)的独立文件存储。白名单 `scopes` + 反馈 `dislikedKeys` 仍留 `defaults`。
    private let derived: AIDerivedDataStore

    init(defaults: UserDefaults = .standard, derived: AIDerivedDataStore = AIDerivedDataStore()) {
        self.defaults = defaults
        self.derived = derived
        // 阶段0a:把派生缓存从 UserDefaults 一次性安全迁到独立文件存储(写盘确认后才清偏好,绝不丢用户索引)。
        AIBackgroundIndexStore.migrateDerivedDataIfNeeded(from: defaults, to: derived)
        self.scopes = AIBackgroundIndexStore.loadScopes(from: defaults)
        self.fileIndex = AIBackgroundIndexStore.loadIndex(from: derived)
        self.dislikedSuggestionKeys = AIBackgroundIndexStore.loadDislikedKeys(from: defaults)
        self.folderGroupsByPath = AIBackgroundIndexStore.loadFolderGroups(from: derived)
        self.organizeByPath = AIBackgroundIndexStore.loadOrganize(from: derived)
        self.workbenchChipRankingByCategory = AIBackgroundIndexStore.loadWorkbenchChipRanking(from: derived)
        self.workbenchNeedsAttentionByCategory = AIBackgroundIndexStore.loadExplanations(
            from: derived, key: AppPreferences.Key.aiWorkbenchNeedsAttentionData)
        self.workbenchFailureExplanationByTask = AIBackgroundIndexStore.loadExplanations(
            from: derived, key: AppPreferences.Key.aiWorkbenchFailureExplanationData)
        self.workbenchClusterChipsByCategory = AIBackgroundIndexStore.loadClusterChips(from: derived)
        self.toolbarRanking = AIBackgroundIndexStore.loadToolbarRanking(from: derived)
        rebuildPathIndex()   // init 里的 fileIndex 赋值不触发 didSet,手动建一次
    }

    /// 阶段0a 一次性迁移:派生缓存从 UserDefaults 搬到 `AIDerivedDataStore`。幂等、防丢:文件已有则以文件为准
    /// (不拿旧偏好覆盖更新的数据);**确认文件确实落盘(读得回)后才清偏好**,写盘失败则保留偏好、下次启动重试。
    private static func migrateDerivedDataIfNeeded(from defaults: UserDefaults, to derived: AIDerivedDataStore) {
        let keys = [
            AppPreferences.Key.aiFileMemoryIndexData,
            AppPreferences.Key.aiFolderGroupsData,
            AppPreferences.Key.aiOrganizeSuggestionsData,
            AppPreferences.Key.aiWorkbenchChipRankingData,
            AppPreferences.Key.aiWorkbenchNeedsAttentionData,
            AppPreferences.Key.aiWorkbenchFailureExplanationData,
            AppPreferences.Key.aiWorkbenchClusterChipsData,
        ]
        for key in keys {
            guard let data = defaults.data(forKey: key) else { continue }
            if derived.data(forKey: key) == nil {
                derived.set(data, forKey: key)
            }
            // 只有文件确实读得回(落盘成功)才清偏好,杜绝写盘失败时丢用户派生数据。
            if derived.data(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
        }
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
        let key = Self.normalizedFolderPath(folderPath)
        var groups = folderGroupsByPath[key] ?? []
        // Task 7:整理建议(actionToken "organize",title=主题名)和批量组建议走**同一套折叠桶渲染**,这里合并返回。
        if let organize = organizeByPath[key], !organize.memberPaths.isEmpty { groups.append(organize) }
        return groups
    }

    func setFolderGroups(_ groups: [CachedFolderGroup], forPath folderPath: String) {
        let key = Self.normalizedFolderPath(folderPath)
        folderGroupsByPath[key] = groups
        folderGroupsGeneration += 1
        persistFolderGroups()
        objectWillChange.send()
    }

    // MARK: - Task 7 整理建议缓存(文件夹级:建新文件夹 + 把同类文件移进去)

    /// 该文件夹是否已被整理 pass 评估过(键缺失 = 未评估,下轮后台会跑)。
    func organizeEvaluated(forPath folderPath: String) -> Bool {
        organizeByPath[Self.normalizedFolderPath(folderPath)] != nil
    }

    /// 该文件夹的整理建议(仅当有成员时返回;空成员的「已评估无建议」哨兵返回 nil)。
    func organizeSuggestion(forPath folderPath: String) -> CachedFolderGroup? {
        guard let group = organizeByPath[Self.normalizedFolderPath(folderPath)],
              !group.memberPaths.isEmpty else { return nil }
        return group
    }

    /// 写入整理建议(nil = 已评估但无建议,落一个空成员哨兵,避免下轮重复评估同一文件夹)。
    func setOrganizeSuggestion(_ group: CachedFolderGroup?, forPath folderPath: String) {
        let key = Self.normalizedFolderPath(folderPath)
        organizeByPath[key] = group ?? CachedFolderGroup(title: nil, memberPaths: [], actionToken: "organize")
        organizeGeneration += 1
        persistOrganize()
        objectWillChange.send()
    }

    /// 用户接受 / 文件移走后清掉该文件夹的整理建议(删键 = 回到未评估,下轮后台据新内容重评,通常为空)。
    func clearOrganizeSuggestion(forPath folderPath: String) {
        let key = Self.normalizedFolderPath(folderPath)
        guard organizeByPath.removeValue(forKey: key) != nil else { return }
        organizeGeneration += 1
        persistOrganize()
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
    func applyArchiveKindGuess(recordID: String, summary: String?, toolTokens: [String] = []) {
        let clean = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = clean?.isEmpty == false
        // 模型挑的归档主动工具(inspect / test / hash / convert / security)。withModelSuggestion 整体替换
        // summaryOwned 的那几个、保留 revealArchiveEntry 等;再确保 archiveKind marker 在(标记已评估)。
        let allowed: Set<String> = ["inspect", "test", "hash", "convert", "security"]
        var seen = Set<String>()
        let toolActions = toolTokens
            .filter { allowed.contains($0) && seen.insert($0).inserted }
            .map { AIFileSuggestedAction(token: $0) }
        let marker = AIFileSuggestedAction(token: "archiveKind")
        fileIndex = fileIndex.updatingRecord(id: recordID) { rec in
            let base = rec.contentSummary ?? AIFileContentSummary(mode: "archive-kind")
            let withTools = base.withModelSuggestion(summary: hasSummary ? clean : nil, actions: toolActions)
            return rec.withContentSummary(
                withTools.mergingSingletonAction(marker, replacingToken: "archiveKind", shortSummaryIfEmpty: nil))
        }
        persistIndex()
        objectWillChange.send()
    }

    // MARK: - 建议六 v2 模块⑤:工作台「建议筛选」chip 排序缓存

    /// 读某分类的 chip 排序缓存(后台预烘焙产物;前台只读)。
    func workbenchChipRanking(forCategory category: String) -> CachedChipRanking? {
        workbenchChipRankingByCategory[category]
    }

    /// 后台 pass 写回某分类的 chip 排序(模型排好序的 chip id 子集 + 当时 chip 池指纹)。幂等由 pass 在调用前比指纹保证。
    func applyWorkbenchChipRanking(category: String, fingerprint: String, orderedIDs: [String]) {
        let ranking = CachedChipRanking(fingerprint: fingerprint, orderedIDs: orderedIDs)
        guard workbenchChipRankingByCategory[category] != ranking else { return }
        workbenchChipRankingByCategory[category] = ranking
        workbenchChipRankingGeneration += 1
        persistWorkbenchChipRanking()
        objectWillChange.send()
    }

    // MARK: - 建议六 v2 模块1「需要处理」解读 + 模块①「失败解释」缓存(后台预烘焙、前台只读)

    /// 读某分类的「需要处理」AI 解读缓存(后台预烘焙产物;前台只读)。
    func workbenchNeedsAttentionExplanation(forCategory category: String) -> CachedExplanation? {
        workbenchNeedsAttentionByCategory[category]
    }

    /// 后台 pass 写回某分类的「需要处理」解读(模型文案 + 当时未读失败集指纹)。幂等由 pass 在调用前比指纹保证。
    func applyWorkbenchNeedsAttentionExplanation(category: String, fingerprint: String, text: String) {
        let explanation = CachedExplanation(fingerprint: fingerprint, text: text)
        guard workbenchNeedsAttentionByCategory[category] != explanation else { return }
        workbenchNeedsAttentionByCategory[category] = explanation
        workbenchExplanationGeneration += 1
        persistWorkbenchNeedsAttention()
        objectWillChange.send()
    }

    /// 读某失败任务的「失败解释」缓存(后台预烘焙产物;前台展开失败任务时只读)。
    func workbenchFailureExplanation(forTask taskID: String) -> CachedExplanation? {
        workbenchFailureExplanationByTask[taskID]
    }

    /// 后台 pass 写回某失败任务的「失败解释」(模型文案 + 当时脱敏诊断指纹)。`liveTaskIDs` = 当前仍存在的失败任务 id 集,
    /// 据此修剪掉已不在列表里的历史条目(缓存规模 = 活失败任务子集,有界)。幂等由 pass 在调用前比指纹保证。
    func applyWorkbenchFailureExplanation(taskID: String, fingerprint: String, text: String, liveTaskIDs: Set<String>) {
        let explanation = CachedExplanation(fingerprint: fingerprint, text: text)
        var updated = workbenchFailureExplanationByTask.filter { liveTaskIDs.contains($0.key) }
        updated[taskID] = explanation
        guard updated != workbenchFailureExplanationByTask else { return }
        workbenchFailureExplanationByTask = updated
        workbenchExplanationGeneration += 1
        persistWorkbenchFailureExplanation()
        objectWillChange.send()
    }

    /// 读某分类的「真建议」chip 缓存(后台预烘焙产物;前台只读)。
    func workbenchClusterChips(forCategory category: String) -> CachedClusterChips? {
        workbenchClusterChipsByCategory[category]
    }

    /// 后台 pass 写回某分类的「真建议」chip(模型命名的真实聚集 + 当时聚集指纹)。幂等由 pass 在调用前比指纹保证。
    func applyWorkbenchClusterChips(category: String, fingerprint: String, chips: [CachedClusterChip]) {
        let value = CachedClusterChips(fingerprint: fingerprint, chips: chips)
        guard workbenchClusterChipsByCategory[category] != value else { return }
        workbenchClusterChipsByCategory[category] = value
        workbenchClusterChipsGeneration += 1
        persistWorkbenchClusterChips()
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

    /// 清空 SimpleZip AI 当前在 App 内持有的**全部派生数据**(独立进程化 坑14:旧名 `clearFileIndex` 名实不符 ——
    /// 它清的远不止 `AIFileMemoryIndex`)。三层一并抹掉,**绝不删任何真实文件**,**也绝不碰 Spotlight 捐献**
    /// (Spotlight 是另一条线,由 Automation/Spotlight 设置自己控制):
    ///   ① AI 索引本体:`AIFileMemoryIndex`(文件记录 `AIFileMemoryRecord` + 文件夹画像 `AIFolderProfile`,
    ///      含挂在记录上的 enrichment `contentSummary`)。
    ///   ② 下游预烘焙缓存:文件夹分组 / 整理建议 / 工作台 chip 排序·需要处理·失败解释·聚集 chip。
    ///   ③ 反馈与执行队列:跨表面交互信号(`AIFeedbackStore`)+ 自动检查队列(`AIPendingCheckStore`)。
    /// **不动用户显式偏好** `dislikedSuggestionKeys`(那是明确的「不感兴趣」反馈,不该被「清空」误删)。
    /// 独立进程化后,本动作将由 agent 清自己的库 + App 同步清本进程投影。
    func clearDerivedData() {
        // ① AI 索引本体(含 enrichment)
        fileIndex = fileIndex.cleared()
        // ② 下游预烘焙缓存
        folderGroupsByPath = [:]
        folderGroupsGeneration += 1
        organizeByPath = [:]
        organizeGeneration += 1
        workbenchChipRankingByCategory = [:]
        workbenchChipRankingGeneration += 1
        workbenchNeedsAttentionByCategory = [:]
        workbenchFailureExplanationByTask = [:]
        workbenchExplanationGeneration += 1
        workbenchClusterChipsByCategory = [:]
        workbenchClusterChipsGeneration += 1
        persistIndex()
        persistFolderGroups()
        persistOrganize()
        persistWorkbenchChipRanking()
        persistWorkbenchNeedsAttention()
        persistWorkbenchFailureExplanation()
        persistWorkbenchClusterChips()
        // ③ 反馈与执行队列
        AIFeedbackStore.shared.clearAll()
        AIPendingCheckStore.shared.clearAll()
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
            derived.set(data, forKey: AppPreferences.Key.aiFileMemoryIndexData)
        }
    }

    private func persistDislikedKeys() {
        if let data = try? JSONEncoder().encode(Array(dislikedSuggestionKeys)) {
            defaults.set(data, forKey: AppPreferences.Key.aiSuggestionDislikedKeys)
        }
    }

    private func persistFolderGroups() {
        if let data = try? JSONEncoder().encode(folderGroupsByPath) {
            derived.set(data, forKey: AppPreferences.Key.aiFolderGroupsData)
        }
    }

    private func persistOrganize() {
        if let data = try? JSONEncoder().encode(organizeByPath) {
            derived.set(data, forKey: AppPreferences.Key.aiOrganizeSuggestionsData)
        }
    }

    private func persistWorkbenchChipRanking() {
        if let data = try? JSONEncoder().encode(workbenchChipRankingByCategory) {
            derived.set(data, forKey: AppPreferences.Key.aiWorkbenchChipRankingData)
        }
    }

    private func persistWorkbenchNeedsAttention() {
        if let data = try? JSONEncoder().encode(workbenchNeedsAttentionByCategory) {
            derived.set(data, forKey: AppPreferences.Key.aiWorkbenchNeedsAttentionData)
        }
    }

    private func persistWorkbenchFailureExplanation() {
        if let data = try? JSONEncoder().encode(workbenchFailureExplanationByTask) {
            derived.set(data, forKey: AppPreferences.Key.aiWorkbenchFailureExplanationData)
        }
    }

    /// 通用解读缓存加载(模块1 / ① 共用,`[String: CachedExplanation]`)。
    private static func loadExplanations(from derived: AIDerivedDataStore, key: String) -> [String: CachedExplanation] {
        guard let data = derived.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CachedExplanation].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistWorkbenchClusterChips() {
        if let data = try? JSONEncoder().encode(workbenchClusterChipsByCategory) {
            derived.set(data, forKey: AppPreferences.Key.aiWorkbenchClusterChipsData)
        }
    }

    private static func loadClusterChips(from derived: AIDerivedDataStore) -> [String: CachedClusterChips] {
        guard let data = derived.data(forKey: AppPreferences.Key.aiWorkbenchClusterChipsData),
              let decoded = try? JSONDecoder().decode([String: CachedClusterChips].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadDislikedKeys(from defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiSuggestionDislikedKeys),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    private static func loadFolderGroups(from derived: AIDerivedDataStore) -> [String: [CachedFolderGroup]] {
        guard let data = derived.data(forKey: AppPreferences.Key.aiFolderGroupsData),
              let decoded = try? JSONDecoder().decode([String: [CachedFolderGroup]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadToolbarRanking(from derived: AIDerivedDataStore) -> AIToolbarRanking {
        guard let data = derived.data(forKey: AIToolbarRanking.derivedKey),
              let decoded = try? JSONDecoder().decode(AIToolbarRanking.self, from: data)
        else { return AIToolbarRanking() }
        return decoded
    }

    /// 建议七 Phase2:单选文件的工具栏 AI 烘焙序(命中文件级优先,否则扩展名类型级,无 → 空)。in-memory 查,渲染热路径安全。
    func toolbarOrder(forPath path: String, pathExtension ext: String) -> [String] {
        toolbarRanking.order(forPath: path, pathExtension: ext) ?? []
    }

    private static func loadOrganize(from derived: AIDerivedDataStore) -> [String: CachedFolderGroup] {
        guard let data = derived.data(forKey: AppPreferences.Key.aiOrganizeSuggestionsData),
              let decoded = try? JSONDecoder().decode([String: CachedFolderGroup].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadWorkbenchChipRanking(from derived: AIDerivedDataStore) -> [String: CachedChipRanking] {
        guard let data = derived.data(forKey: AppPreferences.Key.aiWorkbenchChipRankingData),
              let decoded = try? JSONDecoder().decode([String: CachedChipRanking].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func loadScopes(from defaults: UserDefaults) -> [AIArchivePrefetchScope] {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiBackgroundIndexScopes),
              let decoded = try? JSONDecoder().decode([AIArchivePrefetchScope].self, from: data)
        else { return [] }
        return decoded
    }

    private static func loadIndex(from derived: AIDerivedDataStore) -> AIFileMemoryIndex {
        guard let data = derived.data(forKey: AppPreferences.Key.aiFileMemoryIndexData),
              let decoded = try? JSONDecoder().decode(AIFileMemoryIndex.self, from: data)
        else { return AIFileMemoryIndex() }
        return decoded
    }
}
