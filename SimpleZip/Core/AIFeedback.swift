//
//  AIFeedback.swift
//  SimpleZip
//
//  0.4.5 #80:AI 纠错反馈(白皮书 Feat 11 / 建议二十一)。每个 AI 标签 / 角色 / 工作区 / 动作卡旁的轻量反馈
//  (有用 / 不感兴趣 / 理由不对 / 不是源码包 / 多推荐这种 …)先写成本地事件,**模型不变**,后续确定性
//  ranker 和 prompt hints 读聚合结果 —— 体验照样越来越聪明。
//
//  这里是纯值类型 + 确定性聚合(SwiftPM 可断言)。持久化(UserDefaults,90 天聚合 / 30 天原始)和清空入口
//  在 app 侧(随设置「清空学习数据」)。**红线**:聚合只存可泛化的 token,绝不存完整敏感路径 / 口令 / 加密条目名。
//

import Foundation

nonisolated struct AIFeedbackEvent: Codable, Equatable, Sendable {
    nonisolated enum TargetKind: String, Codable, Equatable, Sendable {
        case archiveRole
        case semanticTag
        case workspace
        case virtualNode
        case toolbarAction
        case nextActionCard
        case activityCard
        case settingSuggestion
        case operationPreview
        case lens
    }

    nonisolated enum Kind: String, Codable, Equatable, Sendable {
        case useful
        case dismissed
        case wrongReason
        case wrongTag
        case tooBroad
        case tooNoisy
        case doMoreLikeThis
        case doLessLikeThis
    }

    let targetKind: TargetKind
    let targetID: String
    let kind: Kind
    /// 标签纠错的原标签(kind == .wrongTag 时)。
    let fromTag: String?
    /// 标签纠错的目标标签。
    let toTag: String?
    /// 可泛化的证据 token(目录名 token / marker / 角色 …)—— 绝不是完整路径。
    let evidenceTokens: [String]
    let createdAt: Date

    init(targetKind: TargetKind, targetID: String, kind: Kind,
         fromTag: String? = nil, toTag: String? = nil, evidenceTokens: [String] = [], createdAt: Date) {
        self.targetKind = targetKind
        self.targetID = targetID
        self.kind = kind
        self.fromTag = fromTag
        self.toTag = toTag
        self.evidenceTokens = evidenceTokens
        self.createdAt = createdAt
    }

    /// 正向反馈(强化这类)。
    var isPositive: Bool { kind == .useful || kind == .doMoreLikeThis }
    /// 负向反馈(降权这类)。
    var isNegative: Bool {
        kind == .dismissed || kind == .tooBroad || kind == .tooNoisy || kind == .doLessLikeThis
    }
}

nonisolated struct AIFeedbackSummary: Codable, Equatable, Sendable {
    struct Pattern: Codable, Equatable, Sendable {
        let tokens: [String]
        let targetKind: String
        let count: Int
    }
    struct TagCorrection: Codable, Equatable, Sendable {
        let from: String
        let to: String
        let count: Int
    }

    let positivePatterns: [Pattern]
    let negativePatterns: [Pattern]
    let tagCorrections: [TagCorrection]

    var isEmpty: Bool { positivePatterns.isEmpty && negativePatterns.isEmpty && tagCorrections.isEmpty }
}

nonisolated enum AIFeedbackAggregator {
    /// 把原始反馈事件确定性聚合成「喜欢哪类 / 讨厌哪类 / 哪些标签常判错」。按 token+targetKind 归组计数。
    static func summarize(_ events: [AIFeedbackEvent]) -> AIFeedbackSummary {
        var positive: [PatternKey: Int] = [:]
        var negative: [PatternKey: Int] = [:]
        var corrections: [CorrectionKey: Int] = [:]

        for event in events {
            // token 排序去重 → 稳定归组键。
            let tokens = Array(Set(event.evidenceTokens.map { $0.lowercased() })).sorted()
            let key = PatternKey(tokens: tokens, targetKind: event.targetKind.rawValue)
            if event.isPositive { positive[key, default: 0] += 1 }
            if event.isNegative { negative[key, default: 0] += 1 }
            if event.kind == .wrongTag, let from = event.fromTag, let to = event.toTag {
                corrections[CorrectionKey(from: from, to: to), default: 0] += 1
            }
        }

        return AIFeedbackSummary(
            positivePatterns: patterns(from: positive),
            negativePatterns: patterns(from: negative),
            tagCorrections: corrections
                .map { AIFeedbackSummary.TagCorrection(from: $0.key.from, to: $0.key.to, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.from, $0.to) < ($1.from, $1.to) }
        )
    }

    private struct PatternKey: Hashable {
        let tokens: [String]
        let targetKind: String
    }
    private struct CorrectionKey: Hashable {
        let from: String
        let to: String
    }

    private static func patterns(from counts: [PatternKey: Int]) -> [AIFeedbackSummary.Pattern] {
        counts
            .map { AIFeedbackSummary.Pattern(tokens: $0.key.tokens, targetKind: $0.key.targetKind, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.targetKind != $1.targetKind { return $0.targetKind < $1.targetKind }
                return $0.tokens.joined() < $1.tokens.joined()
            }
    }
}
