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

/// 受控动作枚举 —— AI 不能产任意 Swift 动作。全部是只读「打开 / 定位 / 搜索 / 解释」级别。
nonisolated enum AISuggestionAction: Codable, Equatable, Sendable {
    case openTask(UUID)
    case openFolder(path: String)
    case revealFile(path: String)
    case openArchive(path: String, revealEntry: String?)
    case applyArchiveSearch(archiveID: String?, query: String)
    case openReport(taskID: UUID)
    case explainFailure(taskID: UUID)
    case openActivityCenter
    case pinRecommendedWorkspace(UUID)
    case dismissRecommendedWorkspace(UUID)

    /// 全部直接安全(只读 / 导航 / 搜索 / 解释)。没有任何写文件 / 改设置的 case —— 那些动作不进这个枚举。
    var isDirectlySafe: Bool { true }
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
        case note
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
    let safety: AISuggestionSafety

    init(id: UUID, kind: Kind, title: String, subtitle: String? = nil, reason: String? = nil,
         confidence: Double = 1.0, sourceRefs: [AIContextSourceRef] = [], children: [AIVirtualNode] = [],
         primaryAction: AISuggestionAction? = nil, safety: AISuggestionSafety = .safe) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.reason = reason
        self.confidence = confidence
        self.sourceRefs = sourceRefs
        self.children = children
        self.primaryAction = primaryAction
        self.safety = safety
    }

    func replacingChildren(_ newChildren: [AIVirtualNode]) -> AIVirtualNode {
        AIVirtualNode(id: id, kind: kind, title: title, subtitle: subtitle, reason: reason,
                      confidence: confidence, sourceRefs: sourceRefs, children: newChildren,
                      primaryAction: primaryAction, safety: safety)
    }
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

    init(id: UUID, origin: Origin, title: String, prompt: String? = nil,
         queryPlan: AIWorkspaceQueryPlan, iconSystemName: String, visibility: Visibility = .visible,
         pinned: Bool = false, generatedAt: Date, lastOpenedAt: Date? = nil, negativeFeedbackCount: Int = 0) {
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
    }
}

/// 虚拟树清洗:把模型产出 / 候选拼出的树过一遍安全闸 —— 安全 > 完整。
nonisolated enum AIVirtualTreeSanitizer {
    /// 丢弃:① 安全标记不合 v1(destructive / touchesEncryptedContent)的节点;② 非 group 节点引用了候选集外
    /// source ref 的节点;③ 清洗后变空的 group(空组无意义)。递归处理子树。
    static func sanitize(_ nodes: [AIVirtualNode], allowed: Set<AIContextSourceRef>) -> [AIVirtualNode] {
        nodes.compactMap { node in
            guard node.safety.isAllowedInV1 else { return nil }
            if node.kind != .group {
                guard AIContextSourceRefValidator.allRefsValid(node.sourceRefs, allowed: allowed) else { return nil }
            }
            let children = sanitize(node.children, allowed: allowed)
            if node.kind == .group, children.isEmpty, node.sourceRefs.isEmpty { return nil }
            return node.replacingChildren(children)
        }
    }
}
