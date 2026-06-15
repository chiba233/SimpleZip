//
//  AIWorkspaceCandidate.swift
//  SimpleZip
//
//  0.4.5 #80:AI 工作区候选池模型(白皮书工程补充七)。后台预读 / 预索引得到的文件夹画像、普通文件记录、
//  归档画像、归档内条目、活动任务、报告都汇进**同一个候选池**:主题候选 + 虚拟节点候选。AI 工作区不是
//  只读活动中心,也不是只读归档缓存,而是读「本机工作空间图谱」。
//
//  分工:App 从预索引数据**确定性生成候选**并打分,模型只负责给主题命名 / 排序 / 写分组标题。这里给:
//  ① 两个候选值类型;② 主题候选确定性排序(按命中信号数);③ 虚拟节点候选 → `AIVirtualNode`(确定性 UUID,
//  可复现)。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 一个推荐工作区主题的候选。App 从预索引信号生成,模型只命名 / 排序。
nonisolated struct AIWorkspaceThemeCandidate: Codable, Equatable, Sendable {
    let id: String
    /// 给模型起名的种子(英文短语)。
    let titleSeed: String
    let themeTokens: [String]
    let sourceRefs: [AIContextSourceRef]
    /// 命中的评分信号(folderRole=release / marker=SHA256SUMS / archiveRole=release-package …)。
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]

    init(id: String, titleSeed: String, themeTokens: [String] = [], sourceRefs: [AIContextSourceRef] = [],
         scoreSignals: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.id = id
        self.titleSeed = titleSeed
        self.themeTokens = themeTokens
        self.sourceRefs = sourceRefs
        self.scoreSignals = scoreSignals
        self.evidence = evidence
    }
}

/// 一个虚拟树节点的候选。混合来源:普通文件 / 文件夹 / 归档 / 归档内条目 / 任务 / 报告 / 动作。
nonisolated struct AIVirtualNodeCandidate: Codable, Equatable, Sendable {
    let id: String
    let kind: AIVirtualNode.Kind
    let displayName: String
    let sourceRefs: [AIContextSourceRef]
    let roleTags: [String]
    let location: AILocationContext?
    let relatedTaskIDs: [String]
    let relatedArchiveIDs: [String]
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]

    init(id: String, kind: AIVirtualNode.Kind, displayName: String,
         sourceRefs: [AIContextSourceRef] = [], roleTags: [String] = [],
         location: AILocationContext? = nil, relatedTaskIDs: [String] = [],
         relatedArchiveIDs: [String] = [], scoreSignals: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceRefs = sourceRefs
        self.roleTags = roleTags
        self.location = location
        self.relatedTaskIDs = relatedTaskIDs
        self.relatedArchiveIDs = relatedArchiveIDs
        self.scoreSignals = scoreSignals
        self.evidence = evidence
    }

    /// 落成一个虚拟树叶子节点。节点 id 由候选 id 确定性派生(可复现),理由取命中信号。
    /// `primaryAction` 不在此层赋值 —— 由调用点按 kind + source ref 安全推导(模型不发明路径)。
    func toNode() -> AIVirtualNode {
        AIVirtualNode(
            id: AIStableHash.deterministicUUID(id),
            kind: kind,
            title: displayName,
            reason: scoreSignals.isEmpty ? nil : scoreSignals.joined(separator: ", "),
            sourceRefs: sourceRefs)
    }
}

/// 「补充证据」缺口(白皮书建议四扩写):候选池发现某节点/主题缺哈希、缺归档清单、缺默认打开方式等
/// 可补的事实时产出。每个缺口可携带一个**只读增强动作**(C2),用户点了 App 才执行,结果回派生索引。
nonisolated struct AIWorkspaceEvidenceGap: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Equatable, Sendable {
        case missingHash
        case missingArchiveListing
        case missingArchiveHealth
        case missingDefaultOpenApp
        case missingRecentOpenSignal
        case missingPermissionFacts
    }

    nonisolated enum Urgency: String, Codable, Equatable, Sendable {
        case low, normal, high
    }

    let id: String
    let workspaceID: UUID
    let kind: Kind
    let affectedSourceRefs: [AIContextSourceRef]
    let reason: String
    /// 可选的只读增强动作(哈希/测试/刷新清单…);App 回查 sourceRefs 后执行。
    let suggestedEnrichmentAction: AIReadOnlyEnrichmentAction?
    let urgency: Urgency

    init(id: String, workspaceID: UUID, kind: Kind, affectedSourceRefs: [AIContextSourceRef],
         reason: String, suggestedEnrichmentAction: AIReadOnlyEnrichmentAction? = nil,
         urgency: Urgency = .normal) {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.affectedSourceRefs = affectedSourceRefs
        self.reason = reason
        self.suggestedEnrichmentAction = suggestedEnrichmentAction
        self.urgency = urgency
    }

    /// 缺哈希缺口 —— 自动带上「算 SHA256」增强动作(把缺口和补救绑在一起,避免各处手拼)。
    static func missingHash(id: String, workspaceID: UUID, refs: [AIContextSourceRef],
                            reason: String, urgency: Urgency = .normal) -> AIWorkspaceEvidenceGap {
        AIWorkspaceEvidenceGap(
            id: id, workspaceID: workspaceID, kind: .missingHash, affectedSourceRefs: refs,
            reason: reason,
            suggestedEnrichmentAction: .calculateHashes(sourceRefs: refs, algorithms: [.sha256]),
            urgency: urgency)
    }

    /// 缺归档清单缺口 —— 自动带上「刷新归档清单」增强动作。
    static func missingArchiveListing(id: String, workspaceID: UUID, refs: [AIContextSourceRef],
                                      reason: String, urgency: Urgency = .normal) -> AIWorkspaceEvidenceGap {
        AIWorkspaceEvidenceGap(
            id: id, workspaceID: workspaceID, kind: .missingArchiveListing, affectedSourceRefs: refs,
            reason: reason,
            suggestedEnrichmentAction: .refreshArchiveListing(sourceRefs: refs),
            urgency: urgency)
    }
}

/// 「为什么没有推荐」—— 不能交给模型瞎编,必须由确定性 suppressor 生成。让空状态 / 低收益建议有据可查。
nonisolated struct AIRecommendationSuppressionReason: Codable, Equatable, Sendable {
    /// 被抑制的目标类别(storageSavingSuggestion / workspace / action …,跨多 surface,开放 token)。
    let targetKind: String
    let targetID: String?
    /// 抑制原因码(稳定 token,下面常用的有静态构造)。
    let reasonCode: String
    let facts: [String]
    let userVisibleSummary: String

    init(targetKind: String, targetID: String? = nil, reasonCode: String,
         facts: [String] = [], userVisibleSummary: String) {
        self.targetKind = targetKind
        self.targetID = targetID
        self.reasonCode = reasonCode
        self.facts = facts
        self.userVisibleSummary = userVisibleSummary
    }

    // 常用原因码(避免各处手写飘移,稳定可断言)。
    static let estimatedSavingTooLow = "estimatedSavingTooLow"
    static let permissionUnreadable = "permissionUnreadable"
    static let alreadyArchived = "alreadyArchived"
    static let dismissedByUser = "dismissedByUser"
    static let budgetExhausted = "budgetExhausted"
    static let modelUnavailable = "modelUnavailable"
    static let noCandidates = "noCandidates"
}

/// 主题合并候选 —— 由 source ref 重叠和路径关系**先确定性计算**,模型只负责给合并后的主题命名。
/// 合并只影响虚拟工作区列表和反馈聚合,绝不移动 / 重命名 / 删除任何真实文件。
nonisolated struct AIWorkspaceMergeCandidate: Codable, Equatable, Sendable {
    let sourceWorkspaceIDs: [UUID]
    /// 重叠度(Jaccard:交集 / 并集,[0,1])。
    let sharedSourceRefRatio: Double
    let sharedPathRoots: [String]
    let evidence: [String]
    /// 给模型起合并后主题名的输入(复用主题候选,不另造类型)。
    let suggestedTitleInput: AIWorkspaceThemeCandidate

    init(sourceWorkspaceIDs: [UUID], sharedSourceRefRatio: Double, sharedPathRoots: [String] = [],
         evidence: [String] = [], suggestedTitleInput: AIWorkspaceThemeCandidate) {
        self.sourceWorkspaceIDs = sourceWorkspaceIDs
        self.sharedSourceRefRatio = sharedSourceRefRatio
        self.sharedPathRoots = sharedPathRoots
        self.evidence = evidence
        self.suggestedTitleInput = suggestedTitleInput
    }

    /// 两组 source ref 的 Jaccard 重叠度(交集 / 并集)。两空集视为 0(无可合并依据)。
    static func overlapRatio(_ a: Set<AIContextSourceRef>, _ b: Set<AIContextSourceRef>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }
}

nonisolated enum AIWorkspaceCandidateRanker {
    /// 主题候选确定性排序:命中信号越多越强,同分按 id 稳定升序。
    static func rankThemes(_ candidates: [AIWorkspaceThemeCandidate]) -> [AIWorkspaceThemeCandidate] {
        candidates.sorted {
            $0.scoreSignals.count != $1.scoreSignals.count
                ? $0.scoreSignals.count > $1.scoreSignals.count
                : $0.id < $1.id
        }
    }

    /// 节点候选确定性排序(同主题分组内):命中信号数降序,同分按 displayName 再按 id。
    static func rankNodes(_ candidates: [AIVirtualNodeCandidate]) -> [AIVirtualNodeCandidate] {
        candidates.sorted {
            if $0.scoreSignals.count != $1.scoreSignals.count { return $0.scoreSignals.count > $1.scoreSignals.count }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.id < $1.id
        }
    }
}
