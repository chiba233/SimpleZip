//
//  AIDiffExplanation.swift
//  SimpleZip
//
//  0.4.5 #80:AI 对比解释(白皮书 Feat 9)。归档 diff / hash diff / release ledger 对比都是**确定性结果**;
//  这层把「变化意味着什么」组织成短摘要 + 提醒 + 下一步动作。
//
//  红线与 `AIOperationAdvice` 一致:规则引擎从已算好的 diff 事实**确定性**产出 attention / suggestedAction
//  的稳定 id(无模型也工作);模型只润色 `summary`(一句人话),attention / action id 必须落在 allowlist 内,
//  否则被 `sanitize` 剔除。**不产 UI 文案**(id 留给 App 按界面语言 L10n)。低敏样本(非加密条目名)由 App
//  脱敏后填入,Core 不读条目内容。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 对比结果的确定性内容信号(App 从 diff 的 added / removed / changed 条目名提取;稳定英文 token)。
/// 只标记「出现了哪类标志性文件」,不携带具体路径 —— 具体样本走 `*Samples`,由 App 脱敏。
nonisolated enum AIDiffSignal: String, Codable, Equatable, CaseIterable, Sendable {
    case addedChecksums = "added-checksums"        // SHA256SUMS / *.sha256 等校验文件新增
    case addedSignature = "added-signature"        // *.asc / *.sig / signature 新增
    case addedAppBundle = "added-app-bundle"        // *.app bundle 新增
    case removedBuildLog = "removed-build-log"      // debug.log / build log 移除
    case changedReadme = "changed-readme"          // README 变化
    case changedManifest = "changed-manifest"      // Package.swift / 清单文件变化
}

/// 喂给模型的对比事实(纯标量 + 低敏样本)。模型只产 `summary`;attention / action 由规则引擎确定性给出。
nonisolated struct AIDiffExplanationFacts: Codable, Equatable, Sendable {
    let addedCount: Int
    let removedCount: Int
    let changedCount: Int
    let unchangedCount: Int
    /// 内容 hash 实际变化的条目数(确定性 diff 的 changed 子集,App 算)。
    let hashChangedCount: Int
    /// 净体积变化(新 - 旧),可负。
    let netSizeDeltaBytes: Int64
    /// 低敏样本(非加密条目名;App 负责脱敏与上限)。Core 不依赖其内容做判定,仅透传给模型润色。
    let addedSamples: [String]
    let removedSamples: [String]
    let changedSamples: [String]
    let signals: [AIDiffSignal]
    /// 归档角色(AIArchiveRole rawValue),可空。
    let archiveRole: String?
    /// 位置类别(AILocationKind rawValue),可空。
    let locationKind: String?

    init(
        addedCount: Int = 0, removedCount: Int = 0, changedCount: Int = 0, unchangedCount: Int = 0,
        hashChangedCount: Int = 0, netSizeDeltaBytes: Int64 = 0,
        addedSamples: [String] = [], removedSamples: [String] = [], changedSamples: [String] = [],
        signals: [AIDiffSignal] = [], archiveRole: String? = nil, locationKind: String? = nil
    ) {
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.changedCount = changedCount
        self.unchangedCount = unchangedCount
        self.hashChangedCount = hashChangedCount
        self.netSizeDeltaBytes = netSizeDeltaBytes
        self.addedSamples = addedSamples
        self.removedSamples = removedSamples
        self.changedSamples = changedSamples
        self.signals = signals
        self.archiveRole = archiveRole
        self.locationKind = locationKind
    }

    /// 是否真有变化 —— 无变化时调用点显示「两者一致」而非空转。
    var hasChanges: Bool { addedCount > 0 || removedCount > 0 || changedCount > 0 }
}

/// 对比解释计划。`summary` 模型润色(nil = App 兜底);`attentionIDs` / `suggestedActionIDs` 为稳定 id,App 做 L10n。
nonisolated struct AIDiffExplanationPlan: Codable, Equatable, Sendable {
    let summary: String?
    let attentionIDs: [String]
    let suggestedActionIDs: [String]

    init(summary: String? = nil, attentionIDs: [String] = [], suggestedActionIDs: [String] = []) {
        self.summary = summary
        self.attentionIDs = attentionIDs
        self.suggestedActionIDs = suggestedActionIDs
    }

    var isEmpty: Bool { attentionIDs.isEmpty && suggestedActionIDs.isEmpty }
}

/// 确定性对比解释规则引擎。无模型也工作。
nonisolated enum AIDiffExplanationRuleEngine {
    /// 下一步动作 allowlist(白皮书 suggestedActions)。`sanitize` 据此剔除模型发明的非法动作。
    static let allowedActions: Set<String> = [
        "openDiffReport", "compareWithPrevious", "runReleaseInspection",
        "generateReleaseBodyDraft", "verifyHashes", "openSecurityReport"
    ]

    /// 提醒 id allowlist(稳定 token;App 按界面语言 L10n)。
    static let allowedAttention: Set<String> = [
        "looks-like-release-build", "release-notes-may-need-sync", "content-hashes-changed",
        "manifest-changed", "only-additions", "only-removals"
    ]

    /// 从确定性事实产出计划(无模型路径)。`summary` 恒 nil,留给模型;无变化时返回空计划。
    static func deterministicPlan(from f: AIDiffExplanationFacts) -> AIDiffExplanationPlan {
        guard f.hasChanges else { return AIDiffExplanationPlan() }
        var attention: [String] = []
        var actions: [String] = []
        let sig = Set(f.signals)
        let releaseLike = !sig.isDisjoint(with: [.addedChecksums, .addedSignature, .addedAppBundle])
            || f.archiveRole == AIArchiveRole.releasePackage.rawValue
            || f.archiveRole == AIArchiveRole.installerPackage.rawValue

        if releaseLike {
            attention.append("looks-like-release-build")
            actions.append("runReleaseInspection")
            if sig.contains(.addedSignature) || sig.contains(.addedChecksums) {
                actions.append("generateReleaseBodyDraft")
            }
        }
        if sig.contains(.changedReadme) && releaseLike {
            attention.append("release-notes-may-need-sync")
        }
        if sig.contains(.changedManifest) {
            attention.append("manifest-changed")
        }
        if f.hashChangedCount > 0 {
            attention.append("content-hashes-changed")
            if sig.contains(.addedChecksums) || releaseLike { actions.append("verifyHashes") }
        }
        if f.removedCount == 0 && f.changedCount == 0 && f.addedCount > 0 { attention.append("only-additions") }
        if f.addedCount == 0 && f.changedCount == 0 && f.removedCount > 0 { attention.append("only-removals") }
        // 总能查看完整 diff。
        actions.append("openDiffReport")

        return AIDiffExplanationPlan(
            summary: nil,
            attentionIDs: dedup(attention),
            suggestedActionIDs: dedup(actions))
    }

    /// 校验模型润色后的计划:剔除 allowlist 外的 attention / action id(模型不能发明动作或绕开提醒集合)。
    static func sanitize(_ plan: AIDiffExplanationPlan) -> AIDiffExplanationPlan {
        AIDiffExplanationPlan(
            summary: plan.summary,
            attentionIDs: dedup(plan.attentionIDs.filter(allowedAttention.contains)),
            suggestedActionIDs: dedup(plan.suggestedActionIDs.filter(allowedActions.contains)))
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
