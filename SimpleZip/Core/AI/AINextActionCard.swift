//
//  AINextActionCard.swift
//  SimpleZip
//
//  0.4.5 #80:下一步动作卡(白皮书 Feat 3)+ 确定性排序器 —— 把「固定推荐按钮」升级成「现在最值得做的几件事」。
//
//  分工:App **确定性枚举**合法候选动作(模型不能发明动作),`AINextActionRanker` 按基础相关度 + 使用反馈
//  (完成 / 点击 / 忽略 / 失败)确定性排序;模型只负责给卡片起标题、写 whyThis / whyNotOthers。所有 actionID
//  都是稳定英文 token,App 渲染前必须校验在候选集内。这是动态工具栏推荐引擎(建议六)的纯 Core 底座。
//
//  纯值 + 确定性排序,SwiftPM 可断言。
//

import Foundation

/// 一个可执行的候选动作(确定性枚举)。`id` 是稳定英文 token(convertArchive / inspectRelease /
/// testArchive / compareArchives / combineVolumes / browseSZS …)。
nonisolated struct AIActionCandidate: Codable, Equatable, Sendable {
    let id: String
    let safety: AISuggestionSafety
    let evidence: [AIEvidenceFact]

    init(id: String, safety: AISuggestionSafety = .safe, evidence: [AIEvidenceFact] = []) {
        self.id = id
        self.safety = safety
        self.evidence = evidence
    }
}

/// 某动作的聚合使用反馈(确定性排序输入)。来自 App 侧的动作使用统计(同目录 / 同扩展 / 同选择形态聚合后)。
nonisolated struct AIActionUsageSignal: Codable, Equatable, Sendable {
    let actionID: String
    let clicked: Int
    let completed: Int
    let dismissed: Int
    let failed: Int

    init(actionID: String, clicked: Int = 0, completed: Int = 0, dismissed: Int = 0, failed: Int = 0) {
        self.actionID = actionID
        self.clicked = clicked
        self.completed = completed
        self.dismissed = dismissed
        self.failed = failed
    }
}

/// 一张「下一步动作」卡。`title` / `whyThis` / `whyNotOthers` 由模型可选填充(确定性阶段为空)。
nonisolated struct AINextActionCard: Codable, Equatable, Sendable {
    let actionID: String
    var title: String?
    /// `safe-readonly` / `requires-confirmation`。
    let risk: String
    let score: Double
    /// 命中的确定性排序信号(给证据 / 调试)。
    let reasons: [String]
    let evidence: [AIEvidenceFact]
    var whyThis: String?
    var whyNotOthers: String?
    let requiresConfirmation: Bool

    init(actionID: String, title: String? = nil, risk: String, score: Double, reasons: [String],
         evidence: [AIEvidenceFact], whyThis: String? = nil, whyNotOthers: String? = nil,
         requiresConfirmation: Bool) {
        self.actionID = actionID
        self.title = title
        self.risk = risk
        self.score = score
        self.reasons = reasons
        self.evidence = evidence
        self.whyThis = whyThis
        self.whyNotOthers = whyNotOthers
        self.requiresConfirmation = requiresConfirmation
    }
}

nonisolated enum AINextActionRanker {
    /// 确定性排序:基础相关度(候选顺序,越靠前越相关)+ 使用反馈(完成 / 点击加分,忽略 / 失败减分)
    /// + **AI 预烘焙序**(`bakedOrder`,建议七 Phase2:AI 开时把后台烘焙的「对该文件最有用的工具栏动作」当强权重)。
    /// 丢弃不合 v1 安全规则的候选(destructive / 碰加密内容)。同分按 actionID 稳定升序。返回前 `limit` 张卡。
    /// `bakedOrder` 是有序动作 id;只对**在候选池内**的 id 生效(白名单兜底,陌生 id 忽略)。空 = 不叠(AI 关 / 无烘焙)。
    static func rank(candidates: [AIActionCandidate],
                     usage: [AIActionUsageSignal] = [],
                     bakedOrder: [String] = [],
                     limit: Int = 3) -> [AINextActionCard] {
        let usageByID = Dictionary(usage.map { ($0.actionID, $0) }, uniquingKeysWith: { a, _ in a })
        // AI 烘焙序 → id:位置(越靠前权重越大);只用在候选池内的 id。
        var bakedRank: [String: Int] = [:]
        for (i, id) in bakedOrder.enumerated() where bakedRank[id] == nil { bakedRank[id] = i }

        let cards: [AINextActionCard] = candidates.enumerated().compactMap { index, candidate in
            guard candidate.safety.isAllowedInV1 else { return nil }

            // 基础相关度:provider 给的顺序反映上下文相关度,越靠前越高(下限 0.1)。
            let base = max(0.1, 1.0 - 0.08 * Double(index))

            var reasons: [String] = ["base-rank-\(index)"]
            var usageScore = 0.0
            if let u = usageByID[candidate.id] {
                usageScore = 0.15 * Double(u.completed)
                    + 0.05 * Double(u.clicked)
                    - 0.10 * Double(u.dismissed)
                    - 0.08 * Double(u.failed)
                // 单项使用贡献封顶,避免历史压倒当前上下文。
                usageScore = min(0.6, max(-0.5, usageScore))
                if u.completed > 0 { reasons.append("completed×\(u.completed)") }
                if u.clicked > 0 { reasons.append("clicked×\(u.clicked)") }
                if u.dismissed > 0 { reasons.append("dismissed×\(u.dismissed)") }
                if u.failed > 0 { reasons.append("failed×\(u.failed)") }
            }

            // AI 烘焙序加权:命中烘焙序的动作按位置加分(0.7→0,封顶 0.7,压过 base 的 0.08/档),最有用的浮到前。
            var bakedScore = 0.0
            if let p = bakedRank[candidate.id] {
                bakedScore = 0.7 * (1.0 - Double(p) / Double(max(1, bakedOrder.count)))
                reasons.append("baked@\(p)")
            }

            let total = base + usageScore + bakedScore
            let needsConfirm = candidate.safety.requiresConfirmation
            return AINextActionCard(
                actionID: candidate.id,
                risk: needsConfirm ? "requires-confirmation" : "safe-readonly",
                score: total,
                reasons: reasons,
                evidence: candidate.evidence,
                requiresConfirmation: needsConfirm)
        }

        return Array(cards
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.actionID < $1.actionID }
            .prefix(max(0, limit)))
    }
}
