//
//  AIWorkspaceLearningStore.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 文件夹的**泛化反馈学习层**(白皮书建议四 + 用户点名的闭环核心)。
//
//  「我不喜欢」不该只是把那一个 ref 从工作区硬删 —— 还要**泛化**:用户不喜欢这个文件,通常也意味着不太喜欢
//  同角色 / 同类型 / 同来源位置的东西进这个主题。所以把每次 like / dislike 摊到候选的**信号**(roleTags +
//  低敏语义 token + 位置类别)上累积权重(喜欢 +、不喜欢 −,钳到 [-cap, cap] 防失控)。召回 / 喂模型前用这套
//  权重**软调**:强负权重的同类候选少进来(而非全局硬删),正权重的更优先。
//
//  纯值 + 确定性,SwiftPM 可断言。只存已脱敏信号(角色 / token / 位置类别),绝不含路径 / 内容。
//

import Foundation

nonisolated struct AIWorkspaceLearningStore: Codable, Equatable, Sendable {
    /// 单个信号权重的钳制上限(防一类信号被反复强化到压过一切)。
    static let cap = 5.0
    /// 「强负」阈值:候选的泛化亲和分 ≤ 此值 → 同类已被明显排斥,召回时软剔除(非固定成员才剔)。
    static let strongNegative = -3.0
    /// 时间衰减半衰期(天):30 天后反馈权重降至一半;旧偏好不再长期压制候选。
    static let feedbackHalfLifeDays = 30.0

    /// workspace id → 信号 token → 累积权重(正=喜欢同类,负=不喜欢同类)。
    private var weights: [UUID: [String: Double]]
    /// workspace id → 最后一次强化时间(用于衰减计算;旧数据无时间戳时 nil → 不衰减)。
    private var reinforcedAt: [UUID: Date]

    init(weights: [UUID: [String: Double]] = [:], reinforcedAt: [UUID: Date] = [:]) {
        self.weights = weights
        self.reinforcedAt = reinforcedAt
    }

    // MARK: - 变换

    /// 用一个候选的信号强化(喜欢 delta>0 / 不喜欢 delta<0)。每个信号各加 delta,钳到 [-cap, cap]。
    /// 向后兼容:无时间戳版本不记录时间(衰减时退回 raw 亲和分)。
    func reinforcing(_ workspace: UUID, signals: [String], by delta: Double) -> AIWorkspaceLearningStore {
        recording(workspace, signals: signals, by: delta, at: nil)
    }

    /// 带时间戳的强化版本(推荐调用;`at` 由 App 传入,不取 wall-clock)。
    func recording(_ workspace: UUID, signals: [String], by delta: Double,
                   at date: Date?) -> AIWorkspaceLearningStore {
        guard !signals.isEmpty, delta != 0 else { return self }
        var copy = self
        for s in signals where !s.isEmpty {
            let next = (copy.weights[workspace]?[s] ?? 0) + delta
            copy.weights[workspace, default: [:]][s] = max(-Self.cap, min(Self.cap, next))
        }
        if let date {
            copy.reinforcedAt[workspace] = Swift.max(copy.reinforcedAt[workspace] ?? .distantPast, date)
        }
        if copy.weights[workspace]?.allSatisfy({ $0.value == 0 }) == true {
            copy.weights[workspace] = nil
            copy.reinforcedAt[workspace] = nil
        }
        return copy
    }

    func clearingWorkspace(_ workspace: UUID) -> AIWorkspaceLearningStore {
        guard weights[workspace] != nil else { return self }
        var copy = self
        copy.weights[workspace] = nil
        copy.reinforcedAt[workspace] = nil
        return copy
    }

    // MARK: - 查询

    /// 一组信号的泛化亲和分 = 各信号权重之和(无学习记录则 0,不影响排序)。
    func affinity(_ workspace: UUID, signals: [String]) -> Double {
        guard let w = weights[workspace], !w.isEmpty else { return 0 }
        return signals.reduce(0) { $0 + (w[$1] ?? 0) }
    }

    /// 时间衰减亲和分:raw 亲和分 × 0.5^(天数 / halfLife)。
    /// 无时间戳(旧数据 / 未用 recording())时退回 raw,不作衰减。`now` 由 App 传入。
    func weightedAffinity(_ workspace: UUID, signals: [String], now: Date) -> Double {
        let raw = affinity(workspace, signals: signals)
        guard raw != 0, let ts = reinforcedAt[workspace] else { return raw }
        let days = Swift.max(0, now.timeIntervalSince(ts)) / 86_400
        return raw * pow(0.5, days / Self.feedbackHalfLifeDays)
    }

    /// 该候选是否因「同类被明显排斥」应在召回时软剔除(强负且非固定;固定由调用点保证不剔)。
    func isStronglyDisliked(_ workspace: UUID, signals: [String]) -> Bool {
        affinity(workspace, signals: signals) <= Self.strongNegative
    }

    /// 时间衰减版强排斥判断(使用 weightedAffinity)。
    func isStronglyDisliked(_ workspace: UUID, signals: [String], now: Date) -> Bool {
        weightedAffinity(workspace, signals: signals, now: now) <= Self.strongNegative
    }

    var isEmpty: Bool { weights.isEmpty }
}
