//
//  AIRanking.swift
//  SimpleZip
//
//  0.4.5 #80:统一 ranking 输入 / 输出(白皮书工程补充一·加固 8)。
//
//  现状:候选排序分散在 workspace theme、virtual node、action card、startup directory 各自的 ranker 里,
//  每个内联算分,无法统一解释「为什么排前面 / 为什么降权 / 为什么被压制」。这里抽出共享的三件套,让上述场景
//  都能用同一类信号解释排序——直接服务证据卡(建议十九)与调试页。
//
//  **不替换现有 ranker**(additive):现有 `AINextActionCardRanker` / `AIWorkspaceCandidateRanker` 仍工作,
//  可逐步迁移到用 `AIRankingContext` 表达打分。纯值类型 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 一条对排序分数的具名贡献(稳定英文 token + 数值 delta + 理由)。正 delta 升权,负 delta 降权。
nonisolated struct AIRankingSignal: Codable, Equatable, Sendable {
    /// 信号类型(稳定英文 token,如 `recency` / `frequency` / `evidence` / `dismissed` / `negative-feedback`)。
    let kind: String
    /// 对分数的贡献(正=升权,负=降权)。
    let delta: Double
    /// 人类可读理由 token(证据卡 / 调试显示)。
    let reason: String

    init(kind: String, delta: Double, reason: String) {
        self.kind = kind
        self.delta = delta
        self.reason = reason
    }

    /// 升权信号(delta 取绝对值)。
    static func boost(_ kind: String, _ magnitude: Double, reason: String) -> AIRankingSignal {
        AIRankingSignal(kind: kind, delta: abs(magnitude), reason: reason)
    }
    /// 降权信号(delta 取负绝对值)。
    static func demote(_ kind: String, _ magnitude: Double, reason: String) -> AIRankingSignal {
        AIRankingSignal(kind: kind, delta: -abs(magnitude), reason: reason)
    }
}

/// 一个候选的排序上下文:确定性基础分 + 一组信号 + 压制阈值。
nonisolated struct AIRankingContext: Codable, Equatable, Sendable {
    /// 基础分(候选自身的确定性置信,如 theme/node 的 confidence)。
    let base: Double
    let signals: [AIRankingSignal]
    /// 低于此分视为「被压制」(不展示)。默认 0。
    let suppressionThreshold: Double

    init(base: Double = 0, signals: [AIRankingSignal] = [], suppressionThreshold: Double = 0) {
        self.base = base
        self.signals = signals
        self.suppressionThreshold = suppressionThreshold
    }

    /// 追加一条信号(返回新值,不可变)。
    func adding(_ signal: AIRankingSignal) -> AIRankingContext {
        AIRankingContext(base: base, signals: signals + [signal], suppressionThreshold: suppressionThreshold)
    }
}

/// 排序决策:最终分 + 裁决(升/平/降/压制)+ 按影响力排序的信号(给证据卡解释)。
nonisolated struct AIRankingDecision: Codable, Equatable, Sendable {
    nonisolated enum Verdict: String, Codable, Equatable, Sendable {
        case promoted   // 净信号 > 0
        case neutral    // 净信号 ≈ 0
        case demoted    // 净信号 < 0 但未被压制
        case suppressed // 分数低于阈值,不展示
    }

    let score: Double
    let verdict: Verdict
    /// 按 |delta| 降序的信号(最影响排序的在前;tie 按 kind 升序)—— 证据卡「为什么这么排」直接读这个。
    let rankedSignals: [AIRankingSignal]
    let suppressed: Bool

    /// 从上下文确定性求值:score = base + Σdelta;score < 阈值 → suppressed;否则按净信号(score - base)定升/平/降。
    static func evaluate(_ context: AIRankingContext) -> AIRankingDecision {
        let score = context.base + context.signals.reduce(0) { $0 + $1.delta }
        let ranked = context.signals.sorted { a, b in
            let (la, lb) = (abs(a.delta), abs(b.delta))
            return la != lb ? la > lb : a.kind < b.kind
        }
        let suppressed = score < context.suppressionThreshold
        let net = score - context.base
        let verdict: Verdict
        if suppressed { verdict = .suppressed }
        else if net > 1e-9 { verdict = .promoted }
        else if net < -1e-9 { verdict = .demoted }
        else { verdict = .neutral }
        return AIRankingDecision(score: score, verdict: verdict, rankedSignals: ranked, suppressed: suppressed)
    }
}

/// 用统一上下文给一组候选排序的便捷器(确定性:同分按输入序稳定,被压制的剔除)。
nonisolated enum AIRanker {
    /// 给每个候选求决策,剔除被压制的,按分数降序(同分按输入序)返回 (候选, 决策)。
    static func rank<Item>(_ items: [Item],
                           context: (Item) -> AIRankingContext) -> [(item: Item, decision: AIRankingDecision)] {
        // 显式循环 + 中间类型(避免长链式带标签元组让类型检查超时)。
        var scored: [(index: Int, item: Item, decision: AIRankingDecision)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let decision = AIRankingDecision.evaluate(context(item))
            if !decision.suppressed { scored.append((index: index, item: item, decision: decision)) }
        }
        scored.sort { a, b in
            a.decision.score != b.decision.score ? a.decision.score > b.decision.score : a.index < b.index
        }
        return scored.map { (item: $0.item, decision: $0.decision) }
    }
}
