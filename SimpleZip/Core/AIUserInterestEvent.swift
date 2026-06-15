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

    let reactionPreferences: [ReactionPreference]
    let locationAffinities: [LocationAffinity]

    var isEmpty: Bool { reactionPreferences.isEmpty && locationAffinities.isEmpty }
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

    private struct PrefKey: Hashable {
        let source: String
        let roleTag: String
    }
}
