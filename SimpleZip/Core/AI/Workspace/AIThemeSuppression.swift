//
//  AIThemeSuppression.swift
//  SimpleZip
//
//  0.4.5 #80 #89:推荐主题的**衰减抑制账本**(白皮书建议四「不感兴趣 = 永久降权 + 随时间逐渐减弱」)。
//
//  「不感兴趣」不是一轮 dismiss,而是写一条**永久保留、带时间戳 + 次数**的负权重记录:
//  - 抑制强度随时间**指数衰减**(刚点最狠,慢慢减弱);
//  - **多次不感兴趣 → 记得更久更狠**(半衰期随次数变长、基础权重随次数升高);
//  - 主题证据足够强、且衰减到阈值以下时,主题**可以重新浮现** —— 不是永久封杀;
//  - 匹配是**模糊**的(themeTokens / sourceRefHashes 重叠 + role / location 一致),否则加一个文件令指纹一变、
//    主题又冒出来,等于没抑制。
//
//  纯值 + 确定性(`now` 由 App 传入,不取 wall-clock;只用 `pow`,无随机),SwiftPM 可断言。后台主题发现器在
//  upsert 推荐工作区前先过这一层。
//

import Foundation

/// 一条「不感兴趣」记录(永久保留)。一个主题指纹对应一条;再次不感兴趣只 bump 次数 + 时间,不新增。
nonisolated struct AIThemeDismissalRecord: Codable, Equatable, Sendable {
    let fingerprint: AIWorkspaceThemeFingerprint
    let firstDismissedAt: Date
    var lastDismissedAt: Date
    var dismissCount: Int

    init(fingerprint: AIWorkspaceThemeFingerprint, firstDismissedAt: Date,
         lastDismissedAt: Date, dismissCount: Int = 1) {
        self.fingerprint = fingerprint
        self.firstDismissedAt = firstDismissedAt
        self.lastDismissedAt = lastDismissedAt
        self.dismissCount = max(1, dismissCount)
    }
}

/// 衰减抑制的**纯数学**(可调常量集中在这里,便于断言)。
nonisolated enum AIThemeSuppressionPolicy {
    /// 模糊匹配阈值:两指纹相似度 ≥ 此值即视为「同一个主题」(用于命中已有不感兴趣记录)。
    static let matchThreshold = 0.5
    /// 一次不感兴趣的基础权重(count=1 时);随次数线性升高,封顶 `maxBaseWeight`。
    static let firstDismissBaseWeight = 0.6
    static let perExtraDismissWeight = 0.2
    static let maxBaseWeight = 1.0
    /// 单次不感兴趣的半衰期(秒);随次数线性变长(记得更久)。默认 10 天 × 次数。
    static let baseHalfLifeSeconds: TimeInterval = 10 * 24 * 3600
    /// 低于此抑制权重视作「已充分衰减」,主题可自由重新浮现。
    static let resurfaceFloor = 0.05

    /// 两指纹的相似度 [0,1]:themeTokens 与 sourceRefHashes 的 Jaccard 取较大者,再要求 role / location 有交集
    /// (完全不同领域不算同主题)。两边皆空 → 0。
    static func similarity(_ a: AIWorkspaceThemeFingerprint, _ b: AIWorkspaceThemeFingerprint) -> Double {
        // role / location 必须有交集(否则「发布物」和「论文」即使 token 偶合也不算同主题)。
        let roleOverlap = !Set(a.dominantRoleTags).isDisjoint(with: Set(b.dominantRoleTags))
        let locOverlap = !Set(a.locationKinds).isDisjoint(with: Set(b.locationKinds))
        guard roleOverlap || locOverlap else { return 0 }
        let tokenSim = jaccard(Set(a.themeTokens), Set(b.themeTokens))
        let refSim = jaccard(Set(a.sourceRefHashes), Set(b.sourceRefHashes))
        return Swift.max(tokenSim, refSim)
    }

    /// 一条记录在 `now` 时刻的当前抑制权重 [0,1]。`baseWeight × 0.5^(Δt / halfLife)`。
    static func weight(of record: AIThemeDismissalRecord, now: Date) -> Double {
        let base = Swift.min(maxBaseWeight,
                             firstDismissBaseWeight + perExtraDismissWeight * Double(record.dismissCount - 1))
        let halfLife = baseHalfLifeSeconds * Double(record.dismissCount)
        let dt = Swift.max(0, now.timeIntervalSince(record.lastDismissedAt))   // 时钟回拨 → 钳 0(全权重)
        let decay = pow(0.5, dt / halfLife)
        return base * decay
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }
}

/// 衰减抑制账本(可持久化)。后台主题发现器在 upsert 前用它过滤 / 降权;用户点「不感兴趣」时记一笔。
nonisolated struct AIThemeSuppressionLedger: Codable, Equatable, Sendable {
    private(set) var records: [AIThemeDismissalRecord]

    init(_ records: [AIThemeDismissalRecord] = []) { self.records = records }

    /// 记一次「不感兴趣」:命中已有(模糊匹配)记录则 bump 次数 + 刷新时间(取较早 first / 较晚 last);否则新增。
    func recordingDismissal(_ fingerprint: AIWorkspaceThemeFingerprint, at date: Date) -> AIThemeSuppressionLedger {
        var copy = records
        if let i = bestMatchIndex(for: fingerprint) {
            var r = copy[i]
            r.dismissCount += 1
            r.lastDismissedAt = Swift.max(r.lastDismissedAt, date)
            // 指纹随主题演化可能微变 —— 记最新指纹(更贴近用户当前不感兴趣的形态)。
            copy[i] = AIThemeDismissalRecord(fingerprint: fingerprint,
                                             firstDismissedAt: Swift.min(r.firstDismissedAt, date),
                                             lastDismissedAt: r.lastDismissedAt, dismissCount: r.dismissCount)
        } else {
            copy.append(AIThemeDismissalRecord(fingerprint: fingerprint,
                                               firstDismissedAt: date, lastDismissedAt: date, dismissCount: 1))
        }
        return AIThemeSuppressionLedger(copy)
    }

    /// 一个候选当前的抑制权重 [0,1](取所有命中记录的最大值;无指纹 / 无命中 → 0)。
    func suppressionWeight(for fingerprint: AIWorkspaceThemeFingerprint?, now: Date) -> Double {
        guard let fingerprint else { return 0 }
        var best = 0.0
        for r in records where AIThemeSuppressionPolicy.similarity(r.fingerprint, fingerprint) >= AIThemeSuppressionPolicy.matchThreshold {
            best = Swift.max(best, AIThemeSuppressionPolicy.weight(of: r, now: now))
        }
        return best
    }

    /// 过滤主题候选:抑制权重 ≥ `resurfaceFloor` 的判为「当前应抑制」(已充分衰减的放行)。返回放行的候选 +
    /// 被抑制的(候选 + 权重),后者供「为什么没有推荐」生成 `dismissedByUser` 原因。
    func partition(_ themes: [AIWorkspaceThemeCandidate], now: Date)
        -> (kept: [AIWorkspaceThemeCandidate], suppressed: [(candidate: AIWorkspaceThemeCandidate, weight: Double)]) {
        var kept: [AIWorkspaceThemeCandidate] = []
        var suppressed: [(AIWorkspaceThemeCandidate, Double)] = []
        for theme in themes {
            let w = suppressionWeight(for: theme.fingerprint, now: now)
            if w >= AIThemeSuppressionPolicy.resurfaceFloor { suppressed.append((theme, w)) }
            else { kept.append(theme) }
        }
        return (kept, suppressed)
    }

    /// 丢弃已完全衰减到地板以下的陈旧记录(可选清理;不影响语义,只控体积)。`now` 由 App 传入。
    func pruned(now: Date) -> AIThemeSuppressionLedger {
        AIThemeSuppressionLedger(records.filter {
            AIThemeSuppressionPolicy.weight(of: $0, now: now) >= AIThemeSuppressionPolicy.resurfaceFloor
        })
    }

    private func bestMatchIndex(for fingerprint: AIWorkspaceThemeFingerprint) -> Int? {
        var bestIdx: Int?
        var bestSim = AIThemeSuppressionPolicy.matchThreshold
        for (i, r) in records.enumerated() {
            let sim = AIThemeSuppressionPolicy.similarity(r.fingerprint, fingerprint)
            if sim >= bestSim { bestSim = sim; bestIdx = i }
        }
        return bestIdx
    }
}
