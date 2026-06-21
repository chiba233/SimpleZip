//
//  AIInteractionSignal.swift
//  SimpleZip
//
//  0.4.5 #80:逐 surface 的轻量交互信号(白皮书工程补充八扩写)。
//
//  四类用户行为事件分工明确,**不混成一个巨大「用户行为模型」**:
//  - `AIUserInterestEvent`:一次较完整的访问会话(打开文件夹 / 归档 / 工作区)。
//  - `AIInteractionSignalEvent`(本文件):会话内部 / UI surface 上的轻量兴趣动作 —— 展开任务、点 chip、
//    打开报告、复制错误、关闭建议。比停留时长更干净的信号。
//  - `AIFeedbackEvent`:明确正负反馈(`x = 不感兴趣`)。
//  - `AIToolInteractionOutcome`:创建 / 解压这类工具流程的终局结果。
//
//  红线:信号事件**不存敏感值** —— `changedOption` 只记 setting id 不记值;搜索 query 进 `evidenceTokens` 前过
//  `AISensitiveRedactor`;密码 / 密钥 / 加密条目名 / 解密明文永不进入。纯值类型 + 确定性聚合,SwiftPM 可断言。
//

import Foundation

/// 一条逐 surface 的轻量交互信号。`value` 是次数权重(通常 1);`evidenceTokens` 是稳定英文短 token
/// (如 `status=failed`、`tag=checksum-mismatch`),**不是**原始查询 / 文件内容。
nonisolated struct AIInteractionSignalEvent: Codable, Identifiable, Equatable, Sendable {
    /// 信号来自哪个 UI surface(白皮书全 surface 埋点矩阵)。
    nonisolated enum Surface: String, Codable, Equatable, Sendable {
        case mainWindow, mainToolbar, fileTable, archiveTable, sidebar, locationBar, searchBar
        case activityCenter, activityTaskRow, activityAIWorkbench
        case aiWorkspace, mainWindowSuggestion, aiCenter
        case createDialog, extractDialog
        case hashResults, reportView, securityReport, contentSearch
        case settings, settingsPane, settingsSearch
        case archiveFinder, spotlight, shortcuts, finderService
    }

    /// 发生了什么交互。
    nonisolated enum Interaction: String, Codable, Equatable, Sendable {
        case shown, expanded, collapsed, clicked, doubleClicked, contextMenuOpened
        case copied, revealedInFinder, openedReport, openedAIExplanation, openedSettingsPane, openedSuggestion
        case appliedPatch, revertedPatch, changedOption
        case ranAction, completedAction, failedAction
        case appliedFilterChip, searched
        case acceptedSuggestion, dismissed, notInterested

        /// 兴趣强度(白皮书:`shown` 只是曝光不算正反馈;`expanded` 中等;`clicked`/`accepted` 强;
        /// `dismissed`/`notInterested` 负)。仅用于排序权重,不直接当反馈。
        var interestWeight: Int {
            switch self {
            case .shown: return 0
            case .collapsed, .changedOption: return 0
            case .expanded, .contextMenuOpened, .appliedFilterChip, .searched, .openedSettingsPane: return 1
            case .clicked, .copied, .revealedInFinder, .openedReport, .openedAIExplanation,
                 .openedSuggestion, .ranAction, .appliedPatch: return 2
            case .doubleClicked, .acceptedSuggestion, .completedAction: return 3
            case .revertedPatch, .failedAction, .dismissed, .notInterested: return 0
            }
        }

        /// outcome 极性(给 counter 的正 / 负计数)。`shown`/`expanded`/`changedOption` 等是中性(不是反馈);
        /// 撤销 patch / 失败 / 主动忽略 / 不感兴趣是负;明确点击 / 接受 / 完成是正。
        var outcomePolarity: AIToolInteractionOutcome.Polarity {
            switch self {
            case .clicked, .doubleClicked, .acceptedSuggestion, .appliedPatch, .completedAction, .ranAction:
                return .positive
            case .revertedPatch, .failedAction, .dismissed, .notInterested:
                return .negative
            case .shown, .expanded, .collapsed, .contextMenuOpened, .copied, .revealedInFinder,
                 .openedReport, .openedAIExplanation, .openedSettingsPane, .openedSuggestion,
                 .changedOption, .appliedFilterChip, .searched:
                return .neutral
            }
        }
    }

    let id: UUID
    let occurredAt: Date
    let surface: Surface
    let interaction: Interaction
    let targetKind: AIUserInterestEvent.TargetKind
    let sourceRef: AIContextSourceRef?
    /// 目标的稳定 token(如 setting id / chip id / task id);**绝不是敏感值**(密码 / 路径输入框内容等)。
    let targetID: String?
    let contextLocation: AILocationContext?
    let roleTags: [String]
    let value: Int
    let evidenceTokens: [String]

    init(id: UUID, occurredAt: Date, surface: Surface, interaction: Interaction,
         targetKind: AIUserInterestEvent.TargetKind, sourceRef: AIContextSourceRef? = nil,
         targetID: String? = nil, contextLocation: AILocationContext? = nil,
         roleTags: [String] = [], value: Int = 1, evidenceTokens: [String] = []) {
        self.id = id
        self.occurredAt = occurredAt
        self.surface = surface
        self.interaction = interaction
        self.targetKind = targetKind
        self.sourceRef = sourceRef
        self.targetID = targetID
        self.contextLocation = contextLocation
        self.roleTags = roleTags
        self.value = max(0, value)
        self.evidenceTokens = evidenceTokens
    }

    /// 安全工厂:`evidenceTokens` 逐条过 `AISensitiveRedactor`(防 App 误把含 `password=…` 的 token 写进数据集)。
    /// App 埋点应走这里,而不是直接 new —— 把脱敏交给类型,而非每个埋点处自觉。
    static func make(id: UUID, occurredAt: Date, surface: Surface, interaction: Interaction,
                     targetKind: AIUserInterestEvent.TargetKind, sourceRef: AIContextSourceRef? = nil,
                     targetID: String? = nil, contextLocation: AILocationContext? = nil,
                     roleTags: [String] = [], value: Int = 1, evidenceTokens: [String] = [])
        -> AIInteractionSignalEvent {
        AIInteractionSignalEvent(
            id: id, occurredAt: occurredAt, surface: surface, interaction: interaction,
            targetKind: targetKind, sourceRef: sourceRef, targetID: targetID,
            contextLocation: contextLocation, roleTags: roleTags, value: value,
            evidenceTokens: evidenceTokens.map { AISensitiveRedactor.redact($0) })
    }
}

/// 信号事件的聚合计数(白皮书工程补充八)。低负载后台把所有 surface 的 shown/clicked/expanded/outcome 折叠成
/// 7d / 30d 计数,供工作区主题、主窗口 Suggestion、设置助手、活动中心、启动目录读取。
nonisolated struct AIInteractionCounterSummary: Codable, Equatable, Sendable {
    static var schemaVersion: String { "simplezip.ai.interactionCounterSummary.v1" }

    let schema: String
    /// 统计窗口(如 `7d` / `30d`)。
    let window: String
    /// 由 App 传入(Core 不取 wall-clock)。
    let generatedAt: Date
    let counters: [Counter]

    nonisolated struct Counter: Codable, Equatable, Sendable {
        let surface: String
        let interaction: String
        let targetKind: String
        /// 聚合计数时为 nil(跨对象汇总);需要逐对象时才填具体 token。
        let targetToken: String?
        let roleTag: String?
        let diagnosticTag: String?
        let locationKind: String?
        let count: Int
        let lastAt: Date?
        let positiveOutcomeCount: Int
        let negativeOutcomeCount: Int
    }

    init(window: String, generatedAt: Date, counters: [Counter]) {
        self.schema = Self.schemaVersion
        self.window = window
        self.generatedAt = generatedAt
        self.counters = counters
    }

    var isEmpty: Bool { counters.isEmpty }
}

/// 把信号事件确定性折叠成 counter summary / interaction affinity。纯函数 —— 后台调度器在低负载时调用。
nonisolated enum AIInteractionSignalAggregator {
    /// 折叠成聚合计数(`targetToken == nil`)。按 (surface, interaction, targetKind, roleTag, diagnosticTag,
    /// locationKind) 分组;`lastAt` 取最新,正 / 负 outcome 按 interaction 极性计。
    static func counterSummary(from events: [AIInteractionSignalEvent], window: String,
                               generatedAt: Date) -> AIInteractionCounterSummary {
        let groups = group(events)
        let counters = groups.map { key, acc in
            AIInteractionCounterSummary.Counter(
                surface: key.surface, interaction: key.interaction, targetKind: key.targetKind,
                targetToken: nil, roleTag: key.roleTag, diagnosticTag: key.diagnosticTag,
                locationKind: key.locationKind, count: acc.count, lastAt: acc.lastAt,
                positiveOutcomeCount: acc.positive, negativeOutcomeCount: acc.negative)
        }.sorted(by: counterOrder)
        return AIInteractionCounterSummary(window: window, generatedAt: generatedAt, counters: counters)
    }

    /// 折叠成 `InteractionAffinity`(给 `AIInterestSummary` 补第三类信号:用户在哪些 surface 对什么对象有兴趣)。
    static func affinities(from events: [AIInteractionSignalEvent]) -> [AIInterestSummary.InteractionAffinity] {
        group(events).map { key, acc in
            AIInterestSummary.InteractionAffinity(
                surface: key.surface, interaction: key.interaction, targetKind: key.targetKind,
                roleTag: key.roleTag, diagnosticTag: key.diagnosticTag, count: acc.count, lastAt: acc.lastAt)
        }.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.surface != b.surface { return a.surface < b.surface }
            if a.interaction != b.interaction { return a.interaction < b.interaction }
            return a.targetKind < b.targetKind
        }
    }

    // MARK: -

    private struct GroupKey: Hashable {
        let surface: String
        let interaction: String
        let targetKind: String
        let roleTag: String?
        let diagnosticTag: String?
        let locationKind: String?
    }

    private struct Accumulator {
        var count = 0
        var lastAt: Date?
        var positive = 0
        var negative = 0
    }

    private static func group(_ events: [AIInteractionSignalEvent]) -> [GroupKey: Accumulator] {
        var groups: [GroupKey: Accumulator] = [:]
        for event in events {
            let roles: [String?] = event.roleTags.isEmpty ? [nil] : event.roleTags.map { Optional($0) }
            let diagnosticTag = event.evidenceTokens
                .first { $0.hasPrefix("tag=") }
                .map { String($0.dropFirst("tag=".count)) }
            let locationKind = event.contextLocation?.kind.rawValue
            let polarity = event.interaction.outcomePolarity
            for role in roles {
                let key = GroupKey(surface: event.surface.rawValue, interaction: event.interaction.rawValue,
                                   targetKind: event.targetKind.rawValue, roleTag: role,
                                   diagnosticTag: diagnosticTag, locationKind: locationKind)
                var acc = groups[key] ?? Accumulator()
                acc.count += max(1, event.value)
                if let last = acc.lastAt { acc.lastAt = Swift.max(last, event.occurredAt) }
                else { acc.lastAt = event.occurredAt }
                if polarity == .positive { acc.positive += 1 }
                else if polarity == .negative { acc.negative += 1 }
                groups[key] = acc
            }
        }
        return groups
    }

    /// 确定性排序:次数降序,再按 surface / interaction / targetKind 升序。
    private static func counterOrder(_ a: AIInteractionCounterSummary.Counter,
                                     _ b: AIInteractionCounterSummary.Counter) -> Bool {
        if a.count != b.count { return a.count > b.count }
        if a.surface != b.surface { return a.surface < b.surface }
        if a.interaction != b.interaction { return a.interaction < b.interaction }
        if a.targetKind != b.targetKind { return a.targetKind < b.targetKind }
        return (a.roleTag ?? "") < (b.roleTag ?? "")
    }
}
