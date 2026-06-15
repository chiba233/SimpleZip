//
//  AIWorkspaceModel.swift
//  SimpleZip
//
//  0.4.5 #80:AI 工作区 / 虚拟文件夹的**纯值数据模型**(白皮书建议四 + 工程补充十一)。侧栏「AI 文件夹」与
//  主内容区的虚拟树直接渲染这些类型 —— UI 不自己拼逻辑。
//
//  安全边界(v1 硬约束):
//  - 动作只允许**打开 / 定位 / 搜索 / 解释**,绝不直接删 / 移 / 覆盖 / 解压 / 改权限 / 改设置(那些回原生确认流)。
//  - 每个节点带 `AISuggestionSafety`,`destructive` / `touchesEncryptedContent` 必须 false,否则被清洗丢弃。
//  - `archiveEntry` 节点只能来自非加密清单缓存;所有节点引用的 source ref 必须经 `AIContextSourceRefValidator`
//    校验在候选集内 —— 模型不能发明路径 / 任务 id / 条目 id。
//
//  纯 Codable 值类型 + 确定性清洗,SwiftPM 可断言。
//

import Foundation

/// 受控动作枚举 —— AI 不能产任意 Swift 动作,只能从这里选,且引用必经候选集校验。白皮书建议四扩写后,
/// 它要覆盖 SimpleZip 原生工具入口(哈希 / 创建 / 测试 / 转换 / 发布检查 / 用某 App 打开)和 AI 文件夹的
/// 虚拟管理(合并 / 拆分 / 移除引用 / 移动虚拟节点),**也包含真实硬盘的复制 / 删除** —— 但这些写盘 /
/// 删除动作一律 `requiresConfirmation`,只能打开现有确认流程,绝不自动执行、绝不当 primary(见 `safety`)。
nonisolated enum AISuggestionAction: Codable, Equatable, Sendable {
    // 只读 / 导航 / 解释(直接安全)。
    case openTask(UUID)
    case openFolder(path: String)
    case revealFile(path: String)
    case openArchive(path: String, revealEntry: String?)
    case applyArchiveSearch(archiveID: String?, query: String)
    case openReport(taskID: UUID)
    case explainFailure(taskID: UUID)
    case openActivityCenter
    case applySelection(paths: [String])
    case revealSourceRefsInFinder(sourceRefs: [AIContextSourceRef])
    case openWithApplication(sourceRefs: [AIContextSourceRef], bundleIdentifier: String)

    // AI 文件夹 / 推荐主题虚拟管理(不碰硬盘文件)。
    case pinRecommendedWorkspace(UUID)
    case dismissRecommendedWorkspace(UUID)
    case setWorkspacePreferredOpenApp(workspaceID: UUID, bundleIdentifier: String?)
    case mergeAIWorkspaces(sourceWorkspaceIDs: [UUID], title: String)
    case splitAIWorkspace(workspaceID: UUID, groups: [AIWorkspaceSplitGroup])
    case removeSourceRefsFromAIWorkspace(workspaceID: UUID, sourceRefs: [AIContextSourceRef])
    case moveVirtualNodes(workspaceID: UUID, nodeIDs: [String], destinationVirtualFolderID: String)
    case addSourceRefsToAIWorkspace(workspaceID: UUID, sourceRefs: [AIContextSourceRef])
    case addThemePromptToAIWorkspace(workspaceID: UUID, prompt: String)
    case deleteAIWorkspace(workspaceID: UUID)

    // 工具入口 / 只读增强(打开现有确认 / 表单 / 任务流程,不自动执行)。
    case calculateHash(paths: [String], algorithms: [String])
    case calculateHashForEvidence(sourceRefs: [AIContextSourceRef], algorithms: [String])
    case createArchive(paths: [String])
    case createArchiveFromSuggestion(paths: [String], suggestedFormat: String?, suggestedPresetID: String?)
    case testArchive(path: String)
    case testArchiveForEvidence(sourceRef: AIContextSourceRef)
    case convertArchive(path: String)
    case inspectRelease(path: String)
    case refreshArchiveListingForEvidence(sourceRef: AIContextSourceRef)
    case copySourceRefsToFolder(sourceRefs: [AIContextSourceRef], destination: String)

    // 真实硬盘删除 —— 最高危。destructive + requiresConfirmation,绝不自动 / 绝不当 primary。
    case deleteSourceRefsFromDisk(sourceRefs: [AIContextSourceRef])

    /// 按 case 的安全姿态。写盘 / 启动后端任务的动作 `requiresConfirmation`;删盘动作额外 `destructive`。
    var safety: AISuggestionSafety {
        switch self {
        // 只读 / 导航 / 虚拟管理 —— 直接安全。
        case .openTask, .openFolder, .revealFile, .openArchive, .applyArchiveSearch, .openReport,
             .explainFailure, .openActivityCenter, .applySelection, .revealSourceRefsInFinder,
             .openWithApplication, .pinRecommendedWorkspace, .dismissRecommendedWorkspace,
             .setWorkspacePreferredOpenApp, .mergeAIWorkspaces, .splitAIWorkspace,
             .removeSourceRefsFromAIWorkspace, .moveVirtualNodes, .addSourceRefsToAIWorkspace,
             .addThemePromptToAIWorkspace:
            return .safe
        // 启动后端任务 / 打开写盘表单 / 复制真实文件 / 删工作区 —— 需确认,只能打开现有流程。
        case .calculateHash, .calculateHashForEvidence, .createArchive, .createArchiveFromSuggestion,
             .testArchive, .testArchiveForEvidence, .convertArchive, .inspectRelease,
             .refreshArchiveListingForEvidence, .copySourceRefsToFolder, .deleteAIWorkspace:
            return AISuggestionSafety(requiresConfirmation: true,
                                      reason: "opens an existing confirm/sheet/task flow")
        // 真实硬盘删除 —— 破坏性 + 强确认。
        case .deleteSourceRefsFromDisk:
            return AISuggestionSafety(destructive: true, requiresConfirmation: true,
                                      reason: "deletes real files; user must confirm explicitly")
        }
    }

    /// 直接安全 = 不破坏、不碰加密内容、不需确认(只读 / 导航 / 虚拟管理)。
    var isDirectlySafe: Bool {
        !safety.destructive && !safety.touchesEncryptedContent && !safety.requiresConfirmation
    }

    /// 破坏性(删盘)—— 绝不能当 primaryAction,绝不自动执行。
    var isDestructive: Bool { safety.destructive }

    /// 需要用户确认(写盘 / 启动任务 / 删工作区 / 删盘)。
    var requiresConfirmation: Bool { safety.requiresConfirmation }
}

/// 一条建议 / 节点的安全姿态。v1 要求 `destructive == false && touchesEncryptedContent == false`。
nonisolated struct AISuggestionSafety: Codable, Equatable, Sendable {
    let destructive: Bool
    let touchesEncryptedContent: Bool
    let requiresConfirmation: Bool
    let reason: String?

    init(destructive: Bool = false, touchesEncryptedContent: Bool = false,
         requiresConfirmation: Bool = false, reason: String? = nil) {
        self.destructive = destructive
        self.touchesEncryptedContent = touchesEncryptedContent
        self.requiresConfirmation = requiresConfirmation
        self.reason = reason
    }

    /// 默认安全(只读建议)。
    static let safe = AISuggestionSafety()

    /// v1 是否允许:不破坏、不碰加密内容。
    var isAllowedInV1: Bool { !destructive && !touchesEncryptedContent }
}

/// 虚拟树节点。混合展示真实文件 / 归档 / 归档内条目 / 任务 / 报告 / 动作 —— 但都是只读虚拟结果集,
/// 不是真实 `FileItem`(避免误触发真实文件操作)。
nonisolated struct AIVirtualNode: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Equatable, Sendable {
        case group
        case file
        case folder
        case archive
        case archiveEntry
        case task
        case report
        case action
        case automation
        case note

        /// 指针类节点(指向一个真实对象)必须带至少一个合法 source ref —— 空 ref 的指针节点指向不到任何东西,
        /// 清洗时丢弃(白皮书工程补充一·边界二:默认拒绝空 ref)。容器(group)/ 注解(note)/ 动作
        /// (action/automation,目标在动作负载里)可无 node 级 ref。
        var requiresSourceRef: Bool {
            switch self {
            case .file, .folder, .archive, .archiveEntry, .task, .report:
                return true
            case .group, .action, .automation, .note:
                return false
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String?
    let reason: String?
    let confidence: Double
    let sourceRefs: [AIContextSourceRef]
    let children: [AIVirtualNode]
    let primaryAction: AISuggestionAction?
    /// 次级动作(白皮书建议四扩写:一个节点除主动作外可挂若干次级动作,如「在 Finder 显示 / 复制到… / 不感兴趣」)。
    let secondaryActions: [AISuggestionAction]
    let safety: AISuggestionSafety

    init(id: UUID, kind: Kind, title: String, subtitle: String? = nil, reason: String? = nil,
         confidence: Double = 1.0, sourceRefs: [AIContextSourceRef] = [], children: [AIVirtualNode] = [],
         primaryAction: AISuggestionAction? = nil, secondaryActions: [AISuggestionAction] = [],
         safety: AISuggestionSafety = .safe) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.reason = reason
        self.confidence = confidence
        self.sourceRefs = sourceRefs
        self.children = children
        self.primaryAction = primaryAction
        self.secondaryActions = secondaryActions
        self.safety = safety
    }

    func replacingChildren(_ newChildren: [AIVirtualNode]) -> AIVirtualNode {
        AIVirtualNode(id: id, kind: kind, title: title, subtitle: subtitle, reason: reason,
                      confidence: confidence, sourceRefs: sourceRefs, children: newChildren,
                      primaryAction: primaryAction, secondaryActions: secondaryActions, safety: safety)
    }

    func withPrimaryAction(_ action: AISuggestionAction?) -> AIVirtualNode {
        AIVirtualNode(id: id, kind: kind, title: title, subtitle: subtitle, reason: reason,
                      confidence: confidence, sourceRefs: sourceRefs, children: children,
                      primaryAction: action, secondaryActions: secondaryActions, safety: safety)
    }
}

/// 一个工作区打开后加载 / 缓存的虚拟文件夹树(白皮书建议四:`AIVirtualFolderTree`)。内容区直接渲染
/// 它的 `nodes`,不再用私有扁平 `Node`。是可持久化 / 可缓存的派生结果(工程补充三「虚拟树缓存」)——
/// 只缓存 source refs 和展示文案,迁移失败可丢弃重建。
nonisolated struct AIVirtualFolderTree: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let title: String
    let prompt: String?
    /// 生成时间(由 App 传入,Core 不取 wall-clock)。
    let generatedAt: Date
    /// 生成方式 —— `deterministic`(确定性整理,UI 须如实标注)/ `modelAssisted`(模型命名分组)。
    /// 旧缓存解码默认 `deterministic`(白皮书建议四:不能把 fallback 伪装成 AI 生成)。
    let generationMode: AIVirtualTreeGenerationMode
    let nodes: [AIVirtualNode]
    /// 本树提供的全部可回查引用集合 —— 节点引用必须落在这里(经 `AIVirtualTreeSanitizer` 校验)。
    let sourceRefs: [AIContextSourceRef]
    let omissions: [AIContextOmission]

    init(id: UUID, workspaceID: UUID, title: String, prompt: String? = nil, generatedAt: Date,
         generationMode: AIVirtualTreeGenerationMode = .deterministic,
         nodes: [AIVirtualNode] = [], sourceRefs: [AIContextSourceRef] = [],
         omissions: [AIContextOmission] = []) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.prompt = prompt
        self.generatedAt = generatedAt
        self.generationMode = generationMode
        self.nodes = nodes
        self.sourceRefs = sourceRefs
        self.omissions = omissions
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, title, prompt, generatedAt, generationMode, nodes, sourceRefs, omissions
    }

    /// 旧缓存(无 `generationMode` 字段)解码兼容 —— 缺字段默认 `deterministic`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.workspaceID = try c.decode(UUID.self, forKey: .workspaceID)
        self.title = try c.decode(String.self, forKey: .title)
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.generationMode = try c.decodeIfPresent(AIVirtualTreeGenerationMode.self, forKey: .generationMode) ?? .deterministic
        self.nodes = try c.decodeIfPresent([AIVirtualNode].self, forKey: .nodes) ?? []
        self.sourceRefs = try c.decodeIfPresent([AIContextSourceRef].self, forKey: .sourceRefs) ?? []
        self.omissions = try c.decodeIfPresent([AIContextOmission].self, forKey: .omissions) ?? []
    }

    /// 显示前清洗:用本树自带的 `sourceRefs` 作为候选集过 `AIVirtualTreeSanitizer`,丢弃发明引用 /
    /// 不安全 / 空组节点。返回清洗后的新树(安全 > 完整)。
    func sanitized() -> AIVirtualFolderTree {
        let cleaned = AIVirtualTreeSanitizer.sanitize(nodes, allowed: Set(sourceRefs))
        return AIVirtualFolderTree(id: id, workspaceID: workspaceID, title: title, prompt: prompt,
                                   generatedAt: generatedAt, generationMode: generationMode,
                                   nodes: cleaned, sourceRefs: sourceRefs, omissions: omissions)
    }

    /// 树里(含子树)节点总数 —— 首屏预算 / 「显示更多」判断用。
    var totalNodeCount: Int {
        func count(_ ns: [AIVirtualNode]) -> Int { ns.reduce(0) { $0 + 1 + count($1.children) } }
        return count(nodes)
    }

    var isEmpty: Bool { nodes.isEmpty }
}

/// 一个工作区(系统 / 用户创建 / 推荐)。打开后加载一棵虚拟树。保存稳定的 query plan(Feat 6),
/// 而非每次重生成的树。
nonisolated struct AIWorkspace: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum Origin: String, Codable, Equatable, Sendable {
        case system        // App 默认内置,可隐藏不可彻底删
        case userCreated   // 用户 prompt 创建,可删 / 重命名 / 刷新
        case recommended   // 后台推荐,可关闭(不感兴趣)
    }

    nonisolated enum Visibility: String, Codable, Equatable, Sendable {
        case visible
        case hidden
        case dismissed
    }

    let id: UUID
    let origin: Origin
    var title: String
    var prompt: String?
    var queryPlan: AIWorkspaceQueryPlan
    let iconSystemName: String
    var visibility: Visibility
    var pinned: Bool
    let generatedAt: Date
    var lastOpenedAt: Date?
    var negativeFeedbackCount: Int
    /// 推荐工作区的主题指纹(`.recommended` 才有)—— 用户「不感兴趣」时据此写衰减抑制账本,随工作区一起持久化。
    var fingerprint: AIWorkspaceThemeFingerprint?
    /// 打开次数(频率信号)—— AI 加权排序用,打开一次只 +1 不直接置顶(见 `AIWorkspaceRanking`)。
    var openCount: Int
    /// 主题强度 [0,1](发现时的 cluster 信号丰富度)—— 强主题即使没打开也排得高,避免「点一下就僵硬置顶」。
    var relevanceScore: Double

    init(id: UUID, origin: Origin, title: String, prompt: String? = nil,
         queryPlan: AIWorkspaceQueryPlan, iconSystemName: String, visibility: Visibility = .visible,
         pinned: Bool = false, generatedAt: Date, lastOpenedAt: Date? = nil, negativeFeedbackCount: Int = 0,
         fingerprint: AIWorkspaceThemeFingerprint? = nil, openCount: Int = 0, relevanceScore: Double = 0) {
        self.id = id
        self.origin = origin
        self.title = title
        self.prompt = prompt
        self.queryPlan = queryPlan
        self.iconSystemName = iconSystemName
        self.visibility = visibility
        self.pinned = pinned
        self.generatedAt = generatedAt
        self.lastOpenedAt = lastOpenedAt
        self.negativeFeedbackCount = negativeFeedbackCount
        self.fingerprint = fingerprint
        self.openCount = openCount
        self.relevanceScore = relevanceScore
    }

    private enum CodingKeys: String, CodingKey {
        case id, origin, title, prompt, queryPlan, iconSystemName, visibility, pinned, generatedAt
        case lastOpenedAt, negativeFeedbackCount, fingerprint, openCount, relevanceScore
    }

    /// 旧持久化(无 openCount / relevanceScore / fingerprint)解码兼容 —— 缺字段给默认,**不丢用户工作区**。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.origin = try c.decode(Origin.self, forKey: .origin)
        self.title = try c.decode(String.self, forKey: .title)
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        self.queryPlan = try c.decode(AIWorkspaceQueryPlan.self, forKey: .queryPlan)
        self.iconSystemName = try c.decode(String.self, forKey: .iconSystemName)
        self.visibility = try c.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .visible
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        self.negativeFeedbackCount = try c.decodeIfPresent(Int.self, forKey: .negativeFeedbackCount) ?? 0
        self.fingerprint = try c.decodeIfPresent(AIWorkspaceThemeFingerprint.self, forKey: .fingerprint)
        self.openCount = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        self.relevanceScore = try c.decodeIfPresent(Double.self, forKey: .relevanceScore) ?? 0
    }
}

/// AI 加权工作区排序(白皮书:不是「点一下就僵硬置顶」,而是软加权 —— 主题强度 + 打开频率 + 最近打开(衰减)
/// 综合;随时间连续重排,不是重启才变)。`now` 由 App 传入(最近度衰减),确定性可测。
nonisolated enum AIWorkspaceRanking {
    static let recencyHalfLifeDays = 7.0
    static let wRecency = 2.5
    static let wFrequency = 1.5
    static let wRelevance = 5.0
    static let userBaseline = 2.5
    static let feedbackPenalty = 3.0

    /// 一个工作区的加权分。固定置顶用大常量;否则 = 主题强度×5 + 打开频率(log)×1.5 + 最近打开衰减×2.5
    /// (+ 用户工作区基线) − 负反馈惩罚。**单次打开只给会衰减的最近度 + 频率小步,不盖过强主题。**
    static func score(_ ws: AIWorkspace, now: Date) -> Double {
        if ws.pinned { return 1_000 }
        var s = wRelevance * max(0, min(1, ws.relevanceScore))
        s += wFrequency * log2(Double(max(0, ws.openCount)) + 1)
        if let last = ws.lastOpenedAt {
            let days = max(0, now.timeIntervalSince(last)) / 86_400
            s += wRecency * pow(0.5, days / recencyHalfLifeDays)
        }
        if ws.origin == .userCreated { s += userBaseline }
        s -= feedbackPenalty * Double(max(0, ws.negativeFeedbackCount))
        return s
    }

    /// 过滤可见 + 按加权分降序(同分按生成时间新→旧、标题)。
    static func rank(_ workspaces: [AIWorkspace], now: Date) -> [AIWorkspace] {
        workspaces
            .filter { $0.visibility == .visible }
            .sorted { a, b in
                let sa = score(a, now: now), sb = score(b, now: now)
                if sa != sb { return sa > sb }
                if a.generatedAt != b.generatedAt { return a.generatedAt > b.generatedAt }
                return a.title < b.title
            }
    }
}

/// AI 工作区集合(白皮书建议四「`AIWorkspaceStore.visibleWorkspaces`」的纯值底座)。App 的 `AIWorkspaceStore`
/// 持有它 + 负责持久化 / `@Published`;这里只放**确定性**的可见性过滤与不可变变换,SwiftPM 可测。
/// 侧边栏 AI section 渲染 `visibleWorkspaces`,而不是写死的 `AISystemWorkspaceKind.allCases`。
nonisolated struct AIWorkspaceCollection: Codable, Equatable, Sendable {
    var workspaces: [AIWorkspace]

    init(_ workspaces: [AIWorkspace] = []) { self.workspaces = workspaces }

    /// 可见工作区(确定性过滤,排除 hidden / dismissed)。**排序交给 `ranked(now:)` 的 AI 加权** —— 这里只给
    /// 一个不依赖时间的稳定兜底序(固定优先 → 生成时间 → 标题),供不需要加权的场景 / 测试。
    var visibleWorkspaces: [AIWorkspace] {
        workspaces
            .filter { $0.visibility == .visible }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.generatedAt != b.generatedAt { return a.generatedAt > b.generatedAt }
                return a.title < b.title
            }
    }

    /// AI 加权排序(白皮书:不是「点一下就僵硬置顶」,而是主题强度 + 频率 + 最近度衰减综合)。`now` 由 App 传入。
    func ranked(now: Date) -> [AIWorkspace] { AIWorkspaceRanking.rank(workspaces, now: now) }

    func workspace(_ id: UUID) -> AIWorkspace? { workspaces.first { $0.id == id } }

    /// 加入 / 替换(按 id 去重)。
    func upserting(_ ws: AIWorkspace) -> AIWorkspaceCollection {
        var copy = workspaces
        if let i = copy.firstIndex(where: { $0.id == ws.id }) { copy[i] = ws } else { copy.append(ws) }
        return AIWorkspaceCollection(copy)
    }

    /// 「不感兴趣」:**仅推荐工作区** → dismissed + 负反馈计数 +1。系统 / 用户工作区不可 dismiss(改 hide / delete)。
    func dismissing(_ id: UUID) -> AIWorkspaceCollection {
        mapping(id) { ws in
            guard ws.origin == .recommended else { return ws }
            var c = ws; c.visibility = .dismissed; c.negativeFeedbackCount += 1; return c
        }
    }

    func pinning(_ id: UUID, _ pinned: Bool) -> AIWorkspaceCollection {
        mapping(id) { var c = $0; c.pinned = pinned; return c }
    }

    /// 隐藏(系统工作区可隐藏不可删)。
    func hiding(_ id: UUID) -> AIWorkspaceCollection {
        mapping(id) { var c = $0; c.visibility = .hidden; return c }
    }

    /// 删除 —— **仅用户创建的工作区**;系统 / 推荐不删(用 hide / dismiss)。
    func removingUserWorkspace(_ id: UUID) -> AIWorkspaceCollection {
        AIWorkspaceCollection(workspaces.filter { !($0.id == id && $0.origin == .userCreated) })
    }

    func renaming(_ id: UUID, to title: String) -> AIWorkspaceCollection {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        return mapping(id) { var c = $0; c.title = trimmed; return c }
    }

    /// 标记打开(最近度 + 频率信号;`date` 由 App 传入)。打开一次只 +1 频率 + 刷新最近度 —— **不直接置顶**,
    /// 排序由 AI 加权综合(见 `AIWorkspaceRanking`)。
    func markingOpened(_ id: UUID, at date: Date) -> AIWorkspaceCollection {
        mapping(id) { var c = $0; c.lastOpenedAt = date; c.openCount += 1; return c }
    }

    private func mapping(_ id: UUID, _ transform: (AIWorkspace) -> AIWorkspace) -> AIWorkspaceCollection {
        AIWorkspaceCollection(workspaces.map { $0.id == id ? transform($0) : $0 })
    }
}

/// 用户创建 / 调教 AI 文件夹的「种子」(白皮书建议四扩写)。用户从右键「添加到 AI 文件夹」加入的不是静态
/// 收藏夹,而是 seed —— AI 基于 seed + 合法候选池自动派生相关文件、旁路文件、归档内条目、补证据动作和虚拟分组。
/// 持久化的是这份 seed,不是派生出来的树。
nonisolated struct AIWorkspaceUserSeed: Codable, Equatable, Sendable {
    let workspaceID: UUID
    var userTitle: String?
    /// 用户输入过的主题提示词(`addThemePromptToAIWorkspace` 累加;AI 刷新只能在 seed + 合法候选内派生)。
    var themePrompts: [String]
    /// 用户固定进工作区的引用。
    var pinnedSourceRefs: [AIContextSourceRef]
    /// 「从此工作区移除」加入的排除引用(只移除虚拟引用,不碰硬盘)。
    var excludedSourceRefs: [AIContextSourceRef]
    /// 工作区限定的默认打开 App(只影响该工作区动作,不改系统 LaunchServices 默认值)。
    var preferredOpenAppBundleID: String?
    let createdAt: Date
    var updatedAt: Date

    init(workspaceID: UUID, userTitle: String? = nil, themePrompts: [String] = [],
         pinnedSourceRefs: [AIContextSourceRef] = [], excludedSourceRefs: [AIContextSourceRef] = [],
         preferredOpenAppBundleID: String? = nil, createdAt: Date, updatedAt: Date) {
        self.workspaceID = workspaceID
        self.userTitle = userTitle
        self.themePrompts = themePrompts
        self.pinnedSourceRefs = pinnedSourceRefs
        self.excludedSourceRefs = excludedSourceRefs
        self.preferredOpenAppBundleID = preferredOpenAppBundleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 追加一条主题提示词(去重),`updatedAt` 由 App 传入(Core 不取 wall-clock)。
    func addingThemePrompt(_ prompt: String, updatedAt: Date) -> AIWorkspaceUserSeed {
        var copy = self
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !copy.themePrompts.contains(trimmed) { copy.themePrompts.append(trimmed) }
        copy.updatedAt = updatedAt
        return copy
    }

    /// 把一组引用加入排除集(「从此工作区移除」,不碰硬盘),去重。
    func excluding(_ refs: [AIContextSourceRef], updatedAt: Date) -> AIWorkspaceUserSeed {
        var copy = self
        for ref in refs where !copy.excludedSourceRefs.contains(ref) { copy.excludedSourceRefs.append(ref) }
        // 排除即从固定集移除(语义一致)。
        copy.pinnedSourceRefs.removeAll { refs.contains($0) }
        copy.updatedAt = updatedAt
        return copy
    }

    /// 一个引用当前是否被排除。
    func isExcluded(_ ref: AIContextSourceRef) -> Bool { excludedSourceRefs.contains(ref) }
}

/// 工作区拆分的一组(白皮书建议四扩写:右键「按主题拆分」)。每组继承原工作区 source refs 的子集 +
/// 可选主题提示词,落成一个新 `AIWorkspace`;不复制 / 不移动真实文件。
nonisolated struct AIWorkspaceSplitGroup: Codable, Equatable, Sendable {
    let title: String
    let sourceRefs: [AIContextSourceRef]
    let themePrompt: String?

    init(title: String, sourceRefs: [AIContextSourceRef], themePrompt: String? = nil) {
        self.title = title
        self.sourceRefs = sourceRefs
        self.themePrompt = themePrompt
    }

    /// 校验拆分组:每组只保留候选集内的 source ref;清洗后变空的组丢弃。**模型不能把任意路径塞进拆分组。**
    /// 全部为空时返回 `[]` —— 调用点据此「不生成新工作区」(白皮书:拆分/校验失败不生成)。
    static func sanitized(_ groups: [AIWorkspaceSplitGroup],
                          allowed: Set<AIContextSourceRef>) -> [AIWorkspaceSplitGroup] {
        groups.compactMap { group in
            let valid = group.sourceRefs.filter { allowed.contains($0) }
            guard !valid.isEmpty else { return nil }
            return AIWorkspaceSplitGroup(title: group.title, sourceRefs: valid, themePrompt: group.themePrompt)
        }
    }
}

/// 虚拟树清洗:把模型产出 / 候选拼出的树过一遍安全闸 —— 安全 > 完整。
nonisolated enum AIVirtualTreeSanitizer {
    /// 丢弃:① 安全标记不合 v1(destructive / touchesEncryptedContent)的节点;② 非 group 节点引用了候选集外
    /// source ref 的节点;③ 清洗后变空的 group(空组无意义)。递归处理子树。
    /// **安全硬化(白皮书 1198)**:破坏性动作(删盘)绝不能当节点 primaryAction —— 若某节点 primaryAction
    /// 是 destructive,剥离它(节点保留,仍可在右键菜单作为带强确认的次级动作出现),防止「模型自动建议成
    /// primary 后被一键执行」。
    static func sanitize(_ nodes: [AIVirtualNode], allowed: Set<AIContextSourceRef>) -> [AIVirtualNode] {
        nodes.compactMap { node in
            guard node.safety.isAllowedInV1 else { return nil }
            if node.kind != .group {
                // 指针类节点强制带合法 ref(空 ref 拒绝);注解 / 动作类节点可无 node 级 ref。
                let emptyPolicy: AIEmptyRefPolicy = node.kind.requiresSourceRef ? .reject : .allow
                guard AIContextSourceRefValidator.allRefsValid(
                    node.sourceRefs, allowed: allowed, emptyPolicy: emptyPolicy) else { return nil }
            }
            let children = sanitize(node.children, allowed: allowed)
            if node.kind == .group, children.isEmpty, node.sourceRefs.isEmpty { return nil }
            let safePrimary = (node.primaryAction?.isDestructive == true) ? node.withPrimaryAction(nil) : node
            return safePrimary.replacingChildren(children)
        }
    }
}
