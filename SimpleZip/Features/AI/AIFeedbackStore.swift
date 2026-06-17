//
//  AIFeedbackStore.swift
//  SimpleZip
//
//  0.4.5 #80:跨表面 AI 反馈 / 交互信号的 **app 侧事件 store**(白皮书 Feat 11 / 建议二十一)。
//
//  Core 早有纯值类型 + 确定性聚合(`AIFeedbackEvent`/`AIFeedbackAggregator`、`AIInteractionSignalEvent`/
//  `AIInteractionSignalAggregator`),但**没有任何 app 侧记录这些事件的地方** —— 这是真缺口。本 store 补上:
//  文件浏览器抽屉右键「我不喜欢」= `dismissed` 反馈、打开 / 双击建议 = 正向兴趣信号,逐条落盘;后台建议 pass
//  读聚合结果做**轻度软降权**(同位置同类反复被忽略 → 喂模型一句 prompt hint,模型仍可选,**绝不全局封类**)。
//
//  红线(沿用 Core 约定):**只存可泛化 token** —— 目录**名**(非完整路径)+ 角色 + 建议类型 token;evidenceTokens
//  逐条过 `AISensitiveRedactor`;密码 / 密钥 / 加密条目名 / 解密明文永不进入。派生数据,**不进偏好备份**,随
//  「清空后台索引」一并抹掉。
//

import Combine
import Foundation

@MainActor
final class AIFeedbackStore: ObservableObject {
    static let shared = AIFeedbackStore()

    /// 明确正负反馈(目前只有文件抽屉「我不喜欢」= dismissed;后续活动 / 设置 / 创建 / 解压共用同一套)。
    private(set) var feedbackEvents: [AIFeedbackEvent]
    /// 轻量交互信号(点击 / 打开建议 = 兴趣;给后续 ranker 用)。
    private(set) var signalEvents: [AIInteractionSignalEvent]

    private let defaults: UserDefaults
    /// 原始事件保留窗口(白皮书:原始 30 天 / 聚合 90 天;本 store 只存原始,聚合即时算)。
    private let rawRetention: TimeInterval = 30 * 86_400
    /// 每类硬上限(护栏:旧的先裁)。
    private let maxEvents = 1_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.feedbackEvents = Self.loadFeedback(from: defaults)
        self.signalEvents = Self.loadSignals(from: defaults)
        pruneInMemory()
    }

    // MARK: - 记录(底层)

    func record(_ event: AIFeedbackEvent) {
        feedbackEvents.append(event)
        pruneInMemory()
        persistFeedback()
    }

    func record(_ signal: AIInteractionSignalEvent) {
        signalEvents.append(signal)
        pruneInMemory()
        persistSignals()
    }

    // MARK: - 文件浏览器抽屉便捷埋点(脱敏 + 折叠成事件)

    /// 「我不喜欢」一条建议 → `dismissed` 反馈。`token` = 建议类型(`openWith` / `hash` / … 或 `summary`);
    /// `folderToken` = 文件所在目录**名**(可泛化,**绝不存完整路径**);`roleTags` = 文件角色(取前 4)。
    func recordFileDrawerDislike(token: String, folderToken: String, roleTags: [String], now: Date = Date()) {
        let tags = (["dir=" + folderToken.lowercased()] + roleTags.prefix(4)).map { AISensitiveRedactor.redact($0) }
        record(AIFeedbackEvent(targetKind: .nextActionCard, targetID: token, kind: .dismissed,
                               surface: .fileBrowserDrawer, evidenceTokens: tags, createdAt: now))
    }

    /// 打开 / 双击一条建议 → 正向兴趣信号(「点击学兴趣」)。走 `make` 工厂自动脱敏 evidenceTokens。
    func recordFileDrawerOpen(token: String, folderToken: String, roleTags: [String], now: Date = Date()) {
        record(AIInteractionSignalEvent.make(
            id: UUID(), occurredAt: now, surface: .fileTable, interaction: .openedSuggestion,
            targetKind: .file, targetID: token, roleTags: Array(roleTags.prefix(4)),
            evidenceTokens: ["dir=" + folderToken.lowercased()]))
    }

    // MARK: - 软降权查询(给后台建议 pass 当 prompt hint)

    /// 当前文件夹内被**同类**反复忽略的建议 token 集:某 `(folderToken, token)` 在保留窗口内 `dismissed ≥ 阈值`。
    /// 仅 `.fileBrowserDrawer` 表面的反馈计入(per-surface,不跨面误伤)。**轻**:默认阈值 2(同一类在该文件夹被
    /// **不同文件**忽略两次以上才软降权),且只是喂模型 prompt hint,模型仍可在明显有用时给出 —— 绝不全局封类。
    func discouragedTokens(forFolderToken folderToken: String, minDismissals: Int = 2) -> Set<String> {
        let tag = "dir=" + folderToken.lowercased()
        var counts: [String: Int] = [:]
        for event in feedbackEvents where event.kind == .dismissed && event.surface == .fileBrowserDrawer {
            guard event.evidenceTokens.contains(tag) else { continue }
            counts[event.targetID, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value >= minDismissals ? $0.key : nil })
    }

    // MARK: - DevTools / 调试可视

    var feedbackSummary: AIFeedbackSummary { AIFeedbackAggregator.summarize(feedbackEvents) }
    var counts: (feedback: Int, signals: Int) { (feedbackEvents.count, signalEvents.count) }

    // MARK: - 清空(随「清空后台索引」一起,学习数据一并抹掉)

    func clearAll() {
        guard !feedbackEvents.isEmpty || !signalEvents.isEmpty else { return }
        feedbackEvents.removeAll()
        signalEvents.removeAll()
        defaults.removeObject(forKey: AppPreferences.Key.aiFeedbackEventsData)
        defaults.removeObject(forKey: AppPreferences.Key.aiInteractionSignalsData)
        objectWillChange.send()
    }

    // MARK: - 修剪 / 持久化

    private func pruneInMemory(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-rawRetention)
        feedbackEvents = Array(feedbackEvents.filter { $0.createdAt >= cutoff }.suffix(maxEvents))
        signalEvents = Array(signalEvents.filter { $0.occurredAt >= cutoff }.suffix(maxEvents))
    }

    private func persistFeedback() {
        if let data = try? JSONEncoder().encode(feedbackEvents) {
            defaults.set(data, forKey: AppPreferences.Key.aiFeedbackEventsData)
        }
    }

    private func persistSignals() {
        if let data = try? JSONEncoder().encode(signalEvents) {
            defaults.set(data, forKey: AppPreferences.Key.aiInteractionSignalsData)
        }
    }

    private static func loadFeedback(from defaults: UserDefaults) -> [AIFeedbackEvent] {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiFeedbackEventsData),
              let decoded = try? JSONDecoder().decode([AIFeedbackEvent].self, from: data) else { return [] }
        return decoded
    }

    private static func loadSignals(from defaults: UserDefaults) -> [AIInteractionSignalEvent] {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiInteractionSignalsData),
              let decoded = try? JSONDecoder().decode([AIInteractionSignalEvent].self, from: data) else { return [] }
        return decoded
    }
}
