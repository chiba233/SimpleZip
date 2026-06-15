//
//  AIDataGap.swift
//  SimpleZip
//
//  0.4.5 #80:通用数据缺口模型(白皮书工程补充一·加固 3 / acceptance)。
//
//  `AIWorkspaceEvidenceGap` 只服务 AI 文件夹。Core 还需一个**跨 surface** 的通用缺口结构,让 activity、
//  mainWindowSuggestion、workspace、archiveSearch、settings 都能表达「这里缺哪块数据、怎么补、有多急」——
//  不只在有建议时工作,也能解释「为什么暂时没推荐(缺证据)」。
//
//  **additive**:`AIWorkspaceEvidenceGap` 保留不变(工作区专用,带 workspaceID);本类型是它的通用上位,
//  并提供 `from(workspaceGap:)` 桥接,让通用消费者也能读工作区缺口。纯值类型 + 确定性,SwiftPM 可断言。
//

import Foundation

nonisolated struct AIDataGap: Codable, Equatable, Sendable {
    /// 缺口类型(稳定英文 token)。覆盖白皮书点名的 6 类 + 工作区缺口的 archiveHealth / recentOpenSignal,
    /// 凑成 `AIWorkspaceEvidenceGap.Kind` 的上位集合,便于桥接。
    nonisolated enum Kind: String, Codable, Equatable, CaseIterable, Sendable {
        case missingTime              // 缺时间事实(startedAt/finishedAt/age 没进时间语义)
        case missingHash
        case missingArchiveListing
        case missingArchiveHealth
        case missingDefaultOpenApp
        case missingRecentOpenSignal
        case missingPermissionFacts
        case missingActivityOutcome   // 缺任务终局(完成/失败/撤销)信号
    }

    nonisolated enum Urgency: String, Codable, Equatable, Sendable {
        case low, normal, high
    }

    let id: String
    /// 哪个 surface 缺这块数据。
    let surface: AISuggestionSurfaceID
    let kind: Kind
    let affectedSourceRefs: [AIContextSourceRef]
    let reason: String
    /// 可选只读补救动作(对照候选回查后执行,产派生信号)。
    let suggestedEnrichmentAction: AIReadOnlyEnrichmentAction?
    let urgency: Urgency

    init(id: String, surface: AISuggestionSurfaceID, kind: Kind,
         affectedSourceRefs: [AIContextSourceRef] = [], reason: String,
         suggestedEnrichmentAction: AIReadOnlyEnrichmentAction? = nil, urgency: Urgency = .normal) {
        self.id = id
        self.surface = surface
        self.kind = kind
        self.affectedSourceRefs = affectedSourceRefs
        self.reason = reason
        self.suggestedEnrichmentAction = suggestedEnrichmentAction
        self.urgency = urgency
    }

    /// 缺哈希 —— 自动绑「算 SHA256」补救动作(缺口与补救绑在一起,避免各处手拼)。
    static func missingHash(id: String, surface: AISuggestionSurfaceID, refs: [AIContextSourceRef],
                            reason: String, urgency: Urgency = .normal) -> AIDataGap {
        AIDataGap(id: id, surface: surface, kind: .missingHash, affectedSourceRefs: refs, reason: reason,
                  suggestedEnrichmentAction: .calculateHashes(sourceRefs: refs, algorithms: [.sha256]),
                  urgency: urgency)
    }

    /// 缺归档清单 —— 自动绑「刷新清单」补救动作。
    static func missingArchiveListing(id: String, surface: AISuggestionSurfaceID, refs: [AIContextSourceRef],
                                      reason: String, urgency: Urgency = .normal) -> AIDataGap {
        AIDataGap(id: id, surface: surface, kind: .missingArchiveListing, affectedSourceRefs: refs,
                  reason: reason, suggestedEnrichmentAction: .refreshArchiveListing(sourceRefs: refs),
                  urgency: urgency)
    }

    /// 从工作区证据缺口桥接成通用缺口(让通用消费者也能读工作区缺口)。kind / urgency rawValue 一一对应。
    static func from(workspaceGap gap: AIWorkspaceEvidenceGap,
                     surface: AISuggestionSurfaceID = .sidebar) -> AIDataGap {
        let kind: Kind
        switch gap.kind {
        case .missingHash: kind = .missingHash
        case .missingArchiveListing: kind = .missingArchiveListing
        case .missingArchiveHealth: kind = .missingArchiveHealth
        case .missingDefaultOpenApp: kind = .missingDefaultOpenApp
        case .missingRecentOpenSignal: kind = .missingRecentOpenSignal
        case .missingPermissionFacts: kind = .missingPermissionFacts
        }
        let urgency: Urgency
        switch gap.urgency {
        case .low: urgency = .low
        case .normal: urgency = .normal
        case .high: urgency = .high
        }
        return AIDataGap(id: gap.id, surface: surface, kind: kind,
                         affectedSourceRefs: gap.affectedSourceRefs, reason: gap.reason,
                         suggestedEnrichmentAction: gap.suggestedEnrichmentAction, urgency: urgency)
    }
}
