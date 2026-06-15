//
//  AISuggestionBus.swift
//  SimpleZip
//
//  0.4.5 #80:全局 AI Suggestion Bus 契约(白皮书工程补充十)。把「哪里需要建议」和「怎么生成建议」分开:
//  每个 surface 提供上下文,统一拿回可验证、可解释、可忽略的建议卡 —— 而不是每个 view 各自直连模型。
//
//  这里只放纯值**契约** + 渲染前的确定性安全闸:① surface 标识;② 请求(surface + 用途 + 候选动作 + 预算 +
//  上下文强度);③ 建议卡(标题 / 正文 / 动作 / 证据 / 忽略行为 / 安全姿态);④ `sanitize` —— 丢不合 v1
//  安全规则的卡、去重、按优先级排序。Provider 注册表、模型增强、各 surface 接线在 App 层(分阶段迁移)。
//
//  安全规则(补十):Bus 只能输出 App 预定义 action 枚举(`AISuggestionAction`,全只读);每卡须有 sourceRefs
//  或明确来自全局设置 / 习惯摘要;destructive 动作只能「打开确认流」。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 可以接 AI 建议的界面位置(稳定英文 token)。
nonisolated enum AISuggestionSurfaceID: String, Codable, Equatable, CaseIterable, Sendable {
    case mainToolbar
    /// 主窗口「AI 建议层」(白皮书建议五):当前窗口上下文上的临时建议,和 AI 文件夹分开,**完全依赖模型输出**。
    case mainWindowSuggestion
    case sidebar
    case locationBar
    case folderTableEmptyState
    case folderSelection
    case archiveTableEmptyState
    case archiveSelection
    case contextMenu
    case statusBar
    case activityCenter
    case activityTaskRow
    case settingsPane
    case createDialog
    case extractDialog
    case reportView
    case archiveFinder
    case spotlightOpen
    case welcome

    /// 是否允许在模型不可用时用确定性规则卡兜底。`mainWindowSuggestion` 例外(白皮书建议五):它必须完全依赖
    /// AI 输出 —— 没有模型输出就不显示 AI 建议卡,绝不用规则卡冒充「AI 建议」。其余 surface 都可确定性兜底。
    var allowsDeterministicFallback: Bool { self != .mainWindowSuggestion }
}

/// 一个 surface 发起的建议请求:提供上下文,不直连模型。
nonisolated struct AISuggestionRequest: Codable, Equatable, Sendable {
    let surfaceID: AISuggestionSurfaceID
    let purpose: AIContextPurpose
    /// 当前浏览模式(folder / archive / tag / aiWorkspace),稳定英文 token。
    let currentMode: String
    let sourceRefs: [AIContextSourceRef]
    /// 当前可见的低敏事实(键值都是稳定英文 token / 已脱敏值)。
    let visibleFacts: [String: String]
    /// App 枚举的合法候选动作(模型不能发明动作)。
    let candidateActions: [AISuggestionAction]
    let budget: AIBudget
    let contextMode: AIContextMode

    init(surfaceID: AISuggestionSurfaceID, purpose: AIContextPurpose, currentMode: String,
         sourceRefs: [AIContextSourceRef] = [], visibleFacts: [String: String] = [:],
         candidateActions: [AISuggestionAction] = [], budget: AIBudget,
         contextMode: AIContextMode = .standardLocalContext) {
        self.surfaceID = surfaceID
        self.purpose = purpose
        self.currentMode = currentMode
        self.sourceRefs = sourceRefs
        self.visibleFacts = visibleFacts
        self.candidateActions = candidateActions
        self.budget = budget
        self.contextMode = contextMode
    }
}

/// 一张返回给 surface 的建议卡。可点动作只能来自 `AISuggestionAction`(全只读);忽略行为决定反馈强度。
nonisolated struct AISuggestionCard: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum DismissBehavior: String, Codable, Equatable, Sendable {
        case sessionOnly       // 本会话不再显示
        case notInterested     // 写负反馈
        case neverForThisTarget // 对该对象永久不再提示
    }

    let id: String
    let surfaceID: AISuggestionSurfaceID
    let title: String
    let body: String
    let priority: Int
    let action: AISuggestionAction?
    let secondaryActions: [AISuggestionAction]
    let evidence: [AIEvidenceCard]
    let dismissBehavior: DismissBehavior
    let safety: AISuggestionSafety

    init(id: String, surfaceID: AISuggestionSurfaceID, title: String, body: String, priority: Int,
         action: AISuggestionAction? = nil, secondaryActions: [AISuggestionAction] = [],
         evidence: [AIEvidenceCard] = [], dismissBehavior: DismissBehavior = .sessionOnly,
         safety: AISuggestionSafety = .safe) {
        self.id = id
        self.surfaceID = surfaceID
        self.title = title
        self.body = body
        self.priority = priority
        self.action = action
        self.secondaryActions = secondaryActions
        self.evidence = evidence
        self.dismissBehavior = dismissBehavior
        self.safety = safety
    }
}

nonisolated enum AISuggestionBus {
    /// 渲染前安全闸:① 丢弃不合 v1 安全规则的卡(destructive / 碰加密内容);② 按 id 去重(保留首个);
    /// ③ 按 priority 降序、同优先级按 id 升序(确定性)。
    static func sanitize(_ cards: [AISuggestionCard]) -> [AISuggestionCard] {
        var seen = Set<String>()
        let deduped = cards.filter { $0.safety.isAllowedInV1 && seen.insert($0.id).inserted }
        return deduped.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
    }
}
