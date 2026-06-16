//
//  AIWorkspaceDynamicTheme.swift
//  SimpleZip
//
//  0.4.5 #80:后台动态主题刷新契约(白皮书建议四 §「对应的数据结构」1022-1058 + §「主题边界」1184-1216)。
//
//  三件事：
//  ① `AIThemeRefreshBudget` / `AIWorkspaceDynamicThemeJob` — 描述「这次刷新该探索多少 candidates / 最多产出
//     几个 upsert / 为什么触发」(调用方按后台档位选 .normal / .aggressive)；
//  ② `AIWorkspaceDynamicThemeResult` / `AIWorkspaceThemeUpsert` — 刷新结果(新增 / 更新哪些工作区)；
//  ③ `AIWorkspaceThemeSeed` / `AIWorkspaceThemeBoundary` — 记录主题起源和 AI 持续学习边界
//     (positive / negative examples + preferred locations / types)；后台刷新可自动 add，不可自动 remove。
//
//  ⚠️ 规则：
//  - `AIWorkspaceThemeUpsert.workspaceID == nil` → 新推荐主题；有值 → 刷新已有主题。
//  - `dismissedFingerprints` 必须进 `AIWorkspaceDynamicThemeJob`，避免用户刚点不感兴趣、下轮又推同款。
//  - `AIWorkspaceThemeBoundary` 里 AI 可以自动加入 `autoAddedRefs`，但 **绝不** 自动移除 `pinnedRefs`。
//  - `AIWorkspaceThemeSeed` 区分 proactive / userPrompt / userAddedSources / interactionDerived，
//    `.migratedLegacy` 只用于历史数据迁移，不能作为新功能入口。
//
//  纯值类型 + 确定性，SwiftPM 可断言。
//

import Foundation

// MARK: - Budget + Reason

/// 触发后台主题刷新的原因(白皮书注释)。
nonisolated enum AIThemeRefreshReason: String, Codable, Equatable, Sendable {
    /// 低负载空闲刷新。
    case idleRefresh
    /// 当前目录发生变化。
    case currentFolderChanged
    /// 活动中心任务完成。
    case taskFinished
    /// 用户点「不感兴趣」/ 手动添加 / 移除后触发。
    case userFeedback
    /// 文件索引或归档缓存更新后触发。
    case indexUpdated
}

/// 单次后台动态主题刷新的资源预算。
nonisolated struct AIThemeRefreshBudget: Codable, Equatable, Sendable {
    /// 本轮最多评估的主题候选数。
    let maxCandidates: Int
    /// 本轮最多产出的 workspace upserts(新增 + 更新合计)。
    let maxUpserts: Int
    /// 进入 job 的历史 dismiss 指纹上限(超出的旧指纹剪裁)。
    let maxDismissedFingerprints: Int

    init(maxCandidates: Int, maxUpserts: Int, maxDismissedFingerprints: Int = 50) {
        self.maxCandidates = max(1, maxCandidates)
        self.maxUpserts = max(1, maxUpserts)
        self.maxDismissedFingerprints = max(1, maxDismissedFingerprints)
    }

    /// 正常后台活跃度(balanced)。
    static let normal = AIThemeRefreshBudget(maxCandidates: 20, maxUpserts: 5)
    /// 高后台活跃度(aggressive，充电 + 空闲)。
    static let aggressive = AIThemeRefreshBudget(maxCandidates: 40, maxUpserts: 10,
                                                  maxDismissedFingerprints: 100)
}

// MARK: - Job + Result

/// 后台动态主题刷新的输入 job(白皮书 `simplezip.ai.workspaceThemeRefresh.input.v1`)。
///
/// 触发时机：低负载、当前目录变化、任务完成、用户反馈、索引更新。
/// 侧边栏打开时只读最近结果，不从零临时生成。
nonisolated struct AIWorkspaceDynamicThemeJob: Codable, Equatable, Sendable {
    let schema: String
    let reason: AIThemeRefreshReason
    let currentLocation: AILocationContext?
    /// 当前选中 / 正在浏览的 source refs(作为注意力 boost，不作内容边界)。
    let selectedSourceRefs: [AIContextSourceRef]
    /// App 从全局候选池聚类得到的主题候选(按 `AIWorkspaceThemeEngine.discoverThemes`)。
    let themeCandidates: [AIWorkspaceThemeCandidate]
    /// 已存在的工作区投影(给模型知道「已经有哪些主题了」以避免重复)。
    let existingWorkspaces: [AIWorkspacePromptFact]
    /// 用户点「不感兴趣」累积的指纹(本轮必须避开)。
    let dismissedFingerprints: [AIWorkspaceThemeFingerprint]
    let interactionSummary: AIInteractionCounterSummary?
    let budget: AIThemeRefreshBudget

    init(reason: AIThemeRefreshReason,
         currentLocation: AILocationContext? = nil,
         selectedSourceRefs: [AIContextSourceRef] = [],
         themeCandidates: [AIWorkspaceThemeCandidate],
         existingWorkspaces: [AIWorkspacePromptFact] = [],
         dismissedFingerprints: [AIWorkspaceThemeFingerprint] = [],
         interactionSummary: AIInteractionCounterSummary? = nil,
         budget: AIThemeRefreshBudget = .normal) {
        self.schema = "simplezip.ai.workspaceThemeRefresh.input.v1"
        self.reason = reason
        self.currentLocation = currentLocation
        self.selectedSourceRefs = selectedSourceRefs
        self.themeCandidates = Array(themeCandidates.prefix(budget.maxCandidates))
        self.existingWorkspaces = existingWorkspaces
        self.dismissedFingerprints = Array(dismissedFingerprints.prefix(budget.maxDismissedFingerprints))
        self.interactionSummary = interactionSummary
        self.budget = budget
    }
}

/// 单个工作区 upsert(白皮书 `AIWorkspaceThemeUpsert`)。
///
/// `workspaceID == nil` → 新推荐主题；有值 → 刷新已有主题标题 / queryPlan / sourceRefs。
nonisolated struct AIWorkspaceThemeUpsert: Codable, Equatable, Sendable {
    let workspaceID: UUID?
    let title: String
    let subtitle: String?
    let fingerprint: AIWorkspaceThemeFingerprint
    let queryPlan: AIWorkspaceQueryPlan
    let sourceRefs: [AIContextSourceRef]
    /// 模型给的选题理由(仅供调试/用户解释，不影响业务判断)。
    let reason: String
    /// 0…1 置信度(确定性路径恒为 1.0，模型路径由输出校验后传入)。
    let confidence: Double

    init(workspaceID: UUID? = nil, title: String, subtitle: String? = nil,
         fingerprint: AIWorkspaceThemeFingerprint, queryPlan: AIWorkspaceQueryPlan,
         sourceRefs: [AIContextSourceRef], reason: String, confidence: Double) {
        self.workspaceID = workspaceID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "—" : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fingerprint = fingerprint
        self.queryPlan = queryPlan
        self.sourceRefs = sourceRefs
        self.reason = reason
        self.confidence = min(max(confidence, 0), 1)
    }

    var isNewWorkspace: Bool { workspaceID == nil }
}

/// 后台动态主题刷新的输出(白皮书 `simplezip.ai.workspaceThemeRefresh.output.v1`)。
///
/// - `upserts`：本轮要新增或更新的工作区(由 `AIWorkspaceStore` 应用)。
/// - `dismissals`：本轮认为应关闭的已有推荐工作区 UUID。
/// - `suppressions`：本轮未能生成主题的原因(调试 / AI 中心显示)。
nonisolated struct AIWorkspaceDynamicThemeResult: Codable, Equatable, Sendable {
    let schema: String
    let upserts: [AIWorkspaceThemeUpsert]
    /// 本轮要关闭的已有推荐工作区(`.origin == .recommended` 的才能被 dismiss)。
    let dismissals: [UUID]
    let suppressions: [AIRecommendationSuppressionReason]

    init(upserts: [AIWorkspaceThemeUpsert] = [],
         dismissals: [UUID] = [],
         suppressions: [AIRecommendationSuppressionReason] = []) {
        self.schema = "simplezip.ai.workspaceThemeRefresh.output.v1"
        self.upserts = upserts
        self.dismissals = dismissals
        self.suppressions = suppressions
    }

    var isEmpty: Bool { upserts.isEmpty && dismissals.isEmpty }
}

// MARK: - ThemeSeed + ThemeBoundary

/// 一个主题候选 / 工作区的「起源种子」(白皮书 `AIWorkspaceThemeSeed`)。
///
/// 区分后台主动发现 vs 用户 prompt vs 用户手动添加 vs 交互派生，让学习层知道「这个主题从哪来」。
/// `migratedLegacy` 仅用于旧数据迁移，不能作为新功能入口。
nonisolated struct AIWorkspaceThemeSeed: Codable, Equatable, Sendable {
    nonisolated enum Origin: String, Codable, Equatable, Sendable {
        case proactive          // 后台低负载主动发现
        case userPrompt         // 用户输入一句话创建
        case userAddedSources   // 用户手动添加文件/任务/报告
        case interactionDerived // 从 interaction summary 派生
        case migratedLegacy     // 历史数据迁移（只用于兼容，不扩展）
    }

    let origin: Origin
    /// 用户输入的主题描述（仅 `.userPrompt` / `.userAddedSources` 时非空）。
    let prompt: String?
    /// 起源时的 source refs（候选集子集，由 App 校验）。
    let sourceRefs: [AIContextSourceRef]
    /// 用户明确表示「这个属于这个主题」的 source refs（手动添加时设置）。
    let positiveExampleRefs: [AIContextSourceRef]
    /// 用户明确表示「这个不属于这个主题」的 source refs（手动移除时设置）。
    let negativeExampleRefs: [AIContextSourceRef]
    /// 低敏语义 token（脱敏后；不含路径）。
    let evidenceTokens: [String]
    let createdAt: Date

    init(origin: Origin, prompt: String? = nil, sourceRefs: [AIContextSourceRef] = [],
         positiveExampleRefs: [AIContextSourceRef] = [], negativeExampleRefs: [AIContextSourceRef] = [],
         evidenceTokens: [String] = [], createdAt: Date) {
        self.origin = origin
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sourceRefs = sourceRefs
        self.positiveExampleRefs = positiveExampleRefs
        self.negativeExampleRefs = negativeExampleRefs
        self.evidenceTokens = evidenceTokens
        self.createdAt = createdAt
    }
}

/// 主题的 AI 学习边界(白皮书 `AIWorkspaceThemeBoundary`)。
///
/// 随用户操作（手动添加/移除、合并/拆分、重命名）持续更新。规则：
/// - 后台刷新可自动加入 `autoAddedRefs`（新发现的相关 source refs）。
/// - **绝不** 自动移除 `pinnedRefs`（用户手动固定的）。
/// - `userRemovedRefs` 中的 source refs 后续召回权重降低，不再自动加入。
nonisolated struct AIWorkspaceThemeBoundary: Codable, Equatable, Sendable {
    let workspaceID: UUID
    /// 命中率高的语义信号 token（用于召回相关候选；不含路径）。
    let includeSignals: [String]
    /// 负例信号 token（降低这些 token 的召回权重）。
    let excludeSignals: [String]
    /// 用户偏好的来源位置 kind（AILocationKind rawValue）。
    let preferredLocations: [String]
    /// 用户偏好的文件类型（UTType identifier 或扩展名）。
    let preferredFileTypes: [String]
    /// 工作区内偏好的打开 App bundle ID（不改系统 LaunchServices 默认值）。
    let preferredOpenApps: [String]
    /// 用户手动加入后确认保留的 source refs（作为 positive examples 影响后续召回）。
    let positiveExampleRefs: [AIContextSourceRef]
    /// 用户明确移除的 source refs（作为 negative examples 降低同类误召回）。
    let negativeExampleRefs: [AIContextSourceRef]
    /// AI 后台自动发现并加入的 source refs（用户没有手动操作，但 AI 认为相关）。
    let autoAddedRefs: [AIContextSourceRef]
    /// 用户手动固定的 source refs（永远显示，AI 绝不自动移除）。
    let pinnedRefs: [AIContextSourceRef]
    /// 用户主动从工作区移除的 source refs（虚拟移除，不碰硬盘）。
    let userRemovedRefs: [AIContextSourceRef]

    init(workspaceID: UUID,
         includeSignals: [String] = [], excludeSignals: [String] = [],
         preferredLocations: [String] = [], preferredFileTypes: [String] = [],
         preferredOpenApps: [String] = [],
         positiveExampleRefs: [AIContextSourceRef] = [],
         negativeExampleRefs: [AIContextSourceRef] = [],
         autoAddedRefs: [AIContextSourceRef] = [],
         pinnedRefs: [AIContextSourceRef] = [],
         userRemovedRefs: [AIContextSourceRef] = []) {
        self.workspaceID = workspaceID
        self.includeSignals = includeSignals
        self.excludeSignals = excludeSignals
        self.preferredLocations = preferredLocations
        self.preferredFileTypes = preferredFileTypes
        self.preferredOpenApps = preferredOpenApps
        self.positiveExampleRefs = positiveExampleRefs
        self.negativeExampleRefs = negativeExampleRefs
        self.autoAddedRefs = autoAddedRefs
        self.pinnedRefs = pinnedRefs
        self.userRemovedRefs = userRemovedRefs
    }

    /// 用户手动添加了 `refs`：加入 positive examples + autoAdded（去重），从 userRemoved 移除（恢复）。
    func addingRefs(_ refs: [AIContextSourceRef]) -> AIWorkspaceThemeBoundary {
        var pos = positiveExampleRefs
        var auto = autoAddedRefs
        var removed = userRemovedRefs
        for ref in refs {
            if !pos.contains(ref) { pos.append(ref) }
            if !auto.contains(ref) { auto.append(ref) }
            removed.removeAll { $0 == ref }
        }
        return AIWorkspaceThemeBoundary(workspaceID: workspaceID,
            includeSignals: includeSignals, excludeSignals: excludeSignals,
            preferredLocations: preferredLocations, preferredFileTypes: preferredFileTypes,
            preferredOpenApps: preferredOpenApps,
            positiveExampleRefs: pos, negativeExampleRefs: negativeExampleRefs,
            autoAddedRefs: auto, pinnedRefs: pinnedRefs, userRemovedRefs: removed)
    }

    /// 用户从工作区移除了 `refs`：加入 negative examples + userRemoved（去重），从 positive + auto 移除。
    func removingRefs(_ refs: [AIContextSourceRef]) -> AIWorkspaceThemeBoundary {
        var neg = negativeExampleRefs
        var removed = userRemovedRefs
        var pos = positiveExampleRefs
        var auto = autoAddedRefs
        var pinned = pinnedRefs
        for ref in refs {
            if !neg.contains(ref) { neg.append(ref) }
            if !removed.contains(ref) { removed.append(ref) }
            pos.removeAll { $0 == ref }
            auto.removeAll { $0 == ref }
            pinned.removeAll { $0 == ref }
        }
        return AIWorkspaceThemeBoundary(workspaceID: workspaceID,
            includeSignals: includeSignals, excludeSignals: excludeSignals,
            preferredLocations: preferredLocations, preferredFileTypes: preferredFileTypes,
            preferredOpenApps: preferredOpenApps,
            positiveExampleRefs: pos, negativeExampleRefs: neg,
            autoAddedRefs: auto, pinnedRefs: pinned, userRemovedRefs: removed)
    }

    /// AI 后台自动发现了 `refs`（不在 userRemoved 里才能加入）。
    func autoAddingRefs(_ refs: [AIContextSourceRef]) -> AIWorkspaceThemeBoundary {
        let allowed = refs.filter { !userRemovedRefs.contains($0) }
        var auto = autoAddedRefs
        for ref in allowed where !auto.contains(ref) { auto.append(ref) }
        return AIWorkspaceThemeBoundary(workspaceID: workspaceID,
            includeSignals: includeSignals, excludeSignals: excludeSignals,
            preferredLocations: preferredLocations, preferredFileTypes: preferredFileTypes,
            preferredOpenApps: preferredOpenApps,
            positiveExampleRefs: positiveExampleRefs, negativeExampleRefs: negativeExampleRefs,
            autoAddedRefs: auto, pinnedRefs: pinnedRefs, userRemovedRefs: userRemovedRefs)
    }

    /// 一个 source ref 是否应该显示（不在 userRemoved 里）。
    func isVisible(_ ref: AIContextSourceRef) -> Bool { !userRemovedRefs.contains(ref) }

    /// 一个 source ref 是否被用户固定（不允许 AI 自动移除）。
    func isPinned(_ ref: AIContextSourceRef) -> Bool { pinnedRefs.contains(ref) }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
