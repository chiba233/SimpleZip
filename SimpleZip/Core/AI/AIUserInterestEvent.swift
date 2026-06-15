//
//  AIUserInterestEvent.swift
//  SimpleZip
//
//  0.4.5 #80:用户兴趣事件(白皮书工程补充八)。AI 要更懂用户,不止「有什么文件」,还要「用户怎么接触它们」——
//  打开时间、停留时长、第一反应、后续动作、来源入口都是强兴趣信号,喂进 AI 工作区 / Lens / 动作推荐 /
//  后台预索引优先级。**不是监控文件内容**,只记 App 内部已发生的交互事实;全本地、可清空、可关闭。
//
//  纯值类型 + 确定性分类 / 聚合(SwiftPM 可断言)。
//  **app 接线红线**:在 `loadFolder` / `applyLoadedFolder` 记录文件夹访问时,FSEvents 每 ~120ms 重载,
//  记录绝不能走 @Published、且必须去重(只记真实导航,不记每次 reload),见 [[feedback_no_published_on_reload_path]]。
//

import Foundation

nonisolated struct AIUserInterestEvent: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum TargetKind: String, Codable, Equatable, Sendable {
        case folder, file, archive, archiveEntry, task, report, workspace, spotlightResult
    }
    nonisolated enum Source: String, Codable, Equatable, Sendable {
        case sidebar, locationBar, fileTable, archiveTable, dragDrop, finderOpen
        case spotlight, shortcuts, activityCenter, aiWorkspace, recentHistory
    }
    nonisolated enum FirstReaction: String, Codable, Equatable, Sendable {
        case stayed, closedQuickly, searched, openedArchive, openedArchiveEntry
        case extracted, tested, converted, inspectedRelease, viewedReport
        case usedAIExplanation, createdWorkspace, revealedInFinder, noAction
    }

    let id: UUID
    let targetKind: TargetKind
    let sourceRef: AIContextSourceRef
    let source: Source
    let openedAt: Date
    let closedAt: Date?
    let dwellSeconds: Int?
    let firstReaction: FirstReaction?
    let timeToFirstReactionSeconds: Int?
    let contextLocation: AILocationContext?
    let visibleRoleTags: [String]
    let evidenceTokens: [String]

    init(id: UUID, targetKind: TargetKind, sourceRef: AIContextSourceRef, source: Source,
         openedAt: Date, closedAt: Date? = nil, dwellSeconds: Int? = nil,
         firstReaction: FirstReaction? = nil, timeToFirstReactionSeconds: Int? = nil,
         contextLocation: AILocationContext? = nil, visibleRoleTags: [String] = [],
         evidenceTokens: [String] = []) {
        self.id = id
        self.targetKind = targetKind
        self.sourceRef = sourceRef
        self.source = source
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.dwellSeconds = dwellSeconds
        self.firstReaction = firstReaction
        self.timeToFirstReactionSeconds = timeToFirstReactionSeconds
        self.contextLocation = contextLocation
        self.visibleRoleTags = visibleRoleTags
        self.evidenceTokens = evidenceTokens
    }
}

nonisolated enum AIInterestClassifier {
    /// 打开后的「第一反应」分类(白皮书定义):有有意义动作 → 该动作;否则 ≤10s 离开 → closedQuickly、
    /// ≥30s 停留 → stayed、其余 → noAction。
    static func firstReaction(dwellSeconds: Int?, action: AIUserInterestEvent.FirstReaction?,
                              quickCloseSeconds: Int = 10, stayedSeconds: Int = 30)
        -> AIUserInterestEvent.FirstReaction {
        if let action, action != .noAction { return action }
        if let dwell = dwellSeconds {
            if dwell <= quickCloseSeconds { return .closedQuickly }
            if dwell >= stayedSeconds { return .stayed }
        }
        return .noAction
    }
}

nonisolated struct AIInterestSummary: Codable, Equatable, Sendable {
    /// 「从某来源打开某角色的包,第一反应通常是 X」—— 直接驱动工具栏 / 工作区推荐。
    struct ReactionPreference: Codable, Equatable, Sendable {
        let source: String
        let roleTag: String
        let topReaction: String
        let count: Int
    }
    /// 用户常打开的位置类别(Downloads / 项目目录 …)。
    struct LocationAffinity: Codable, Equatable, Sendable {
        let locationKind: String
        let openCount: Int
    }
    /// 「用户在哪个 surface 上对什么对象反复产生轻量兴趣」(白皮书工程补充八:由 `AIInteractionSignalEvent`
    /// 折叠而来)。比停留时长更干净 —— 展开某类失败任务、点某 chip、打开某类报告都计入。
    struct InteractionAffinity: Codable, Equatable, Sendable {
        let surface: String
        let interaction: String
        let targetKind: String
        let roleTag: String?
        let diagnosticTag: String?
        let count: Int
        let lastAt: Date?
    }

    let reactionPreferences: [ReactionPreference]
    let locationAffinities: [LocationAffinity]
    let interactionAffinities: [InteractionAffinity]

    init(reactionPreferences: [ReactionPreference], locationAffinities: [LocationAffinity],
         interactionAffinities: [InteractionAffinity] = []) {
        self.reactionPreferences = reactionPreferences
        self.locationAffinities = locationAffinities
        self.interactionAffinities = interactionAffinities
    }

    var isEmpty: Bool {
        reactionPreferences.isEmpty && locationAffinities.isEmpty && interactionAffinities.isEmpty
    }
}

nonisolated enum AIInterestAggregator {
    /// 把兴趣事件确定性聚合成偏好信号:(来源 × 角色标签)→ 最常见的第一反应 + 位置亲和度。
    static func summarize(_ events: [AIUserInterestEvent]) -> AIInterestSummary {
        var reactionCounts: [PrefKey: [String: Int]] = [:]
        var locationCounts: [String: Int] = [:]

        for event in events {
            if let reaction = event.firstReaction {
                let roles = event.visibleRoleTags.isEmpty ? ["any"] : event.visibleRoleTags
                for role in roles {
                    reactionCounts[PrefKey(source: event.source.rawValue, roleTag: role), default: [:]][reaction.rawValue, default: 0] += 1
                }
            }
            if let location = event.contextLocation {
                locationCounts[location.kind.rawValue, default: 0] += 1
            }
        }

        let preferences = reactionCounts.compactMap { key, counts -> AIInterestSummary.ReactionPreference? in
            guard let top = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first else { return nil }
            return AIInterestSummary.ReactionPreference(source: key.source, roleTag: key.roleTag,
                                                        topReaction: top.key, count: top.value)
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.roleTag < $1.roleTag
        }

        let affinities = locationCounts
            .map { AIInterestSummary.LocationAffinity(locationKind: $0.key, openCount: $0.value) }
            .sorted { $0.openCount != $1.openCount ? $0.openCount > $1.openCount : $0.locationKind < $1.locationKind }

        return AIInterestSummary(reactionPreferences: preferences, locationAffinities: affinities)
    }

    /// 同上,但额外把逐 surface 的信号事件折叠进 `interactionAffinities`(白皮书工程补充八:兴趣摘要不只
    /// reactionPreferences + locationAffinities,还要 interactionAffinities)。
    static func summarize(_ events: [AIUserInterestEvent],
                          signals: [AIInteractionSignalEvent]) -> AIInterestSummary {
        let base = summarize(events)
        return AIInterestSummary(
            reactionPreferences: base.reactionPreferences,
            locationAffinities: base.locationAffinities,
            interactionAffinities: AIInteractionSignalAggregator.affinities(from: signals))
    }

    private struct PrefKey: Hashable {
        let source: String
        let roleTag: String
    }
}

/// 工具类交互的终局结果(白皮书工程补充八)。压缩 / 解压这类工具软件里,`closedQuickly` / 短 dwell **不能**
/// 当负反馈 —— 用户打开解压窗口、选项已正确、立刻解压并关闭是成功流程。所以在兴趣事件之外再加一个 outcome
/// 聚合,按「是否接受 patch / 是否手改回去 / 是否撤销取消失败」判定正负,而不是看停留时长。
nonisolated struct AIToolInteractionOutcome: Codable, Equatable, Sendable {
    nonisolated enum TerminalResult: String, Codable, Equatable, Sendable {
        case completed
        case cancelled
        case failed
        case undone
        case dismissedSuggestion
        case acceptedSuggestion
        case manuallyOverrodeSuggestion
    }

    nonisolated enum Polarity: String, Codable, Equatable, Sendable {
        case positive, negative, neutral
    }

    let sourceRef: AIContextSourceRef
    let operationKind: String
    let firstReaction: AIUserInterestEvent.FirstReaction
    let terminalResult: TerminalResult
    let optionChangesCount: Int
    let acceptedPatchIDs: [String]
    let revertedPatchIDs: [String]
    let manualOverrideFields: [String]

    init(sourceRef: AIContextSourceRef, operationKind: String,
         firstReaction: AIUserInterestEvent.FirstReaction, terminalResult: TerminalResult,
         optionChangesCount: Int = 0, acceptedPatchIDs: [String] = [],
         revertedPatchIDs: [String] = [], manualOverrideFields: [String] = []) {
        self.sourceRef = sourceRef
        self.operationKind = operationKind
        self.firstReaction = firstReaction
        self.terminalResult = terminalResult
        self.optionChangesCount = optionChangesCount
        self.acceptedPatchIDs = acceptedPatchIDs
        self.revertedPatchIDs = revertedPatchIDs
        self.manualOverrideFields = manualOverrideFields
    }

    /// 反馈极性(确定性,编码白皮书「工具类正向反馈标准」):
    /// - 撤销 patch / 手改字段回去 / cancelled / failed / undone / 主动忽略建议 → 负;
    /// - 接受建议、或接受 patch 后完成、或没改任何选项就成功完成 → 正;
    /// - 其余(如成功但有少量手改)→ 中性。**短 dwell 不参与判定。**
    var polarity: Polarity {
        if !revertedPatchIDs.isEmpty || !manualOverrideFields.isEmpty { return .negative }
        switch terminalResult {
        case .cancelled, .failed, .undone, .dismissedSuggestion, .manuallyOverrodeSuggestion:
            return .negative
        case .acceptedSuggestion:
            return .positive
        case .completed:
            if !acceptedPatchIDs.isEmpty { return .positive }     // 接受 AI patch 后完成 = 强正
            if optionChangesCount == 0 { return .positive }       // 默认/自动预填正确,直接成功 = 正
            return .neutral
        }
    }
}

/// 一次归档打开会话(白皮书工程补充八)。在 `updateArchiveListingCache` 入口写入,补足「用户怎么接触这个归档」
/// 的兴趣信号:打开后第一反应(搜索 / 测试 / 解压 / 看报告 / 立刻关闭)是很强的角色与偏好证据。
/// **红线**:`encryptedEntriesOmitted` 只存计数;不存加密条目名;`profileTags` 来自非加密画像。
nonisolated struct AIArchiveOpenSession: Codable, Equatable, Sendable {
    let archiveID: String
    let openedAt: Date
    let source: AIUserInterestEvent.Source
    let profileTags: [String]
    let entryCount: Int
    let encryptedEntriesOmitted: Int
    let firstReaction: AIUserInterestEvent.FirstReaction?
    let dwellSeconds: Int?

    init(archiveID: String, openedAt: Date, source: AIUserInterestEvent.Source,
         profileTags: [String] = [], entryCount: Int = 0, encryptedEntriesOmitted: Int = 0,
         firstReaction: AIUserInterestEvent.FirstReaction? = nil, dwellSeconds: Int? = nil) {
        self.archiveID = archiveID
        self.openedAt = openedAt
        self.source = source
        self.profileTags = profileTags
        self.entryCount = entryCount
        self.encryptedEntriesOmitted = encryptedEntriesOmitted
        self.firstReaction = firstReaction
        self.dwellSeconds = dwellSeconds
    }
}
