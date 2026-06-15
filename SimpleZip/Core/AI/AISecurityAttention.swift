//
//  AISecurityAttention.swift
//  SimpleZip
//
//  0.4.5 #80:AI 安全关注点摘要(白皮书 Feat 17)。规则判断由 App 的确定性扫描做;AI 只把结果变成短摘要 +
//  下一步。**红线(白皮书逐字)**:
//    1. AI 不判断「安全 / 不安全」的最终结论;
//    2. `riskHints` 必须来自确定性扫描;
//    3. AI 不能因为摘要语气温和就**降低**现有安全提示级别。
//
//  安全机制(对照 Auto-Tune 安全闸教训:clamp 必须覆盖所有返回路径):App 从确定性扫描算出一个**级别下限**
//  (`floorLevel`)。模型只能润色 headline / summary 文案,**绝不能把级别压到下限以下**,也不能把主动作换成更
//  危险的;`clamp(_:against:)` 在最外层统一钳制 —— 取 `max(模型级别, floor)`、stop 级强制主动作=查看安全报告、
//  动作 id 必须落在 allowlist 内。纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 安全关注级别(稳定英文 token,有序)。`stop` 最高(先别直接解压),`none` 最低。
nonisolated enum AISecurityAttentionLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case none
    case info
    case caution
    case stop

    private var order: Int {
        switch self {
        case .none: return 0
        case .info: return 1
        case .caution: return 2
        case .stop: return 3
        }
    }

    static func < (lhs: AISecurityAttentionLevel, rhs: AISecurityAttentionLevel) -> Bool {
        lhs.order < rhs.order
    }
}

/// 喂给模型的安全关注事实。`riskHints` 必须来自确定性扫描(ArchiveRiskScore / SensitiveFileScan / ArchiveSafety),
/// 模型不得新增 hint。`entrySamples` 为低敏样本(非加密条目名,App 脱敏)。
nonisolated struct AISecurityAttentionFacts: Codable, Equatable, Sendable {
    let riskHints: [String]
    let archiveRole: String?
    let entrySamples: [String]
    /// 加密条目数(仅计数 —— 名字与内容不进 AI;加密本身不是「风险」,只是说明)。
    let encryptedEntryCount: Int

    init(riskHints: [String], archiveRole: String? = nil,
         entrySamples: [String] = [], encryptedEntryCount: Int = 0) {
        self.riskHints = riskHints
        self.archiveRole = archiveRole
        self.entrySamples = entrySamples
        self.encryptedEntryCount = encryptedEntryCount
    }
}

/// 安全关注计划。`headline` / `summary` 模型润色(确定性版为 nil);`level` / `primaryActionID` / `attentionIDs`
/// 为受钳制的稳定结构。
nonisolated struct AISecurityAttentionPlan: Codable, Equatable, Sendable {
    let level: AISecurityAttentionLevel
    let headline: String?
    let summary: String?
    let primaryActionID: String?
    let attentionIDs: [String]

    init(level: AISecurityAttentionLevel, headline: String? = nil, summary: String? = nil,
         primaryActionID: String? = nil, attentionIDs: [String] = []) {
        self.level = level
        self.headline = headline
        self.summary = summary
        self.primaryActionID = primaryActionID
        self.attentionIDs = attentionIDs
    }
}

nonisolated enum AISecurityAttentionRuleEngine {
    /// 下一步动作 allowlist(白皮书)。`clamp` 据此剔除模型发明的动作。
    static let allowedActions: Set<String> = ["openSecurityReport", "extractWithReview", "cancel"]

    /// 提到即「先别直接解压」(stop 级)的确定性风险 hint(路径逃逸类)。
    static let stopHints: Set<String> = [
        "path-traversal", "absolute-path", "drive-path", "unc-path", "root-escape", "parent-escape"
    ]
    /// 需谨慎(caution 级)的 hint(可执行 / 链接 / 提权类)。
    static let cautionHints: Set<String> = [
        "executable", "symlink", "hardlink", "setuid", "setgid", "script", "macro", "package-bundle"
    ]
    /// 仅提示(info 级)的 hint(macOS 垃圾 / 异常命名等)。
    static let infoHints: Set<String> = [
        "macos-junk", "control-char-name", "name-normalization", "many-entries", "unusual-extension"
    ]

    /// 确定性级别下限 —— 模型**绝不能**低于它。取所有 hint 命中级别的最高者。
    static func floorLevel(for facts: AISecurityAttentionFacts) -> AISecurityAttentionLevel {
        let hints = Set(facts.riskHints.map { $0.lowercased() })
        if !hints.isDisjoint(with: stopHints) { return .stop }
        if !hints.isDisjoint(with: cautionHints) { return .caution }
        if !hints.isDisjoint(with: infoHints) { return .info }
        return .none
    }

    /// 无模型路径:级别 = 下限;主动作与提醒由级别确定性给出。
    static func deterministicPlan(from facts: AISecurityAttentionFacts) -> AISecurityAttentionPlan {
        let level = floorLevel(for: facts)
        return AISecurityAttentionPlan(
            level: level,
            primaryActionID: deterministicPrimaryAction(for: level),
            attentionIDs: deterministicAttention(for: facts, level: level))
    }

    /// **统一钳制**模型润色后的计划(覆盖所有返回路径):
    ///   - 级别取 `max(模型级别, floor)` —— 模型不能下调;
    ///   - 动作必须在 allowlist 内,否则置 nil;
    ///   - caution 及以上若无有效动作,补「查看安全报告」;
    ///   - stop 级强制主动作 = 「查看安全报告」(不允许在最高警示下引导用户直接解压);
    ///   - attention 必须**并回**确定性提醒集合 —— 模型只能在 allowlist 内**补充**,绝不能**丢弃**任何确定性提醒
    ///     (否则就能靠隐去 `path-escape-samples` 这类细节悄悄弱化警告)。
    static func clamp(_ plan: AISecurityAttentionPlan, against facts: AISecurityAttentionFacts) -> AISecurityAttentionPlan {
        let floor = floorLevel(for: facts)
        let level = max(plan.level, floor)

        var action = plan.primaryActionID.flatMap { allowedActions.contains($0) ? $0 : nil }
        if level == .stop {
            action = "openSecurityReport"
        } else if level >= .caution, action == nil {
            action = "openSecurityReport"
        }

        // 确定性提醒在前(承重、不可丢),模型补充的 allowlist 内提醒在后;dedup 保序去重。
        let floorAttention = deterministicAttention(for: facts, level: level)
        let modelAttention = plan.attentionIDs.filter(allowedAttention.contains)
        return AISecurityAttentionPlan(
            level: level, headline: plan.headline, summary: plan.summary,
            primaryActionID: action, attentionIDs: dedup(floorAttention + modelAttention))
    }

    // MARK: - 确定性细节

    static let allowedAttention: Set<String> = [
        "path-escape-samples", "executable-content", "links-present", "encrypted-entries-present", "macos-junk-present"
    ]

    private static func deterministicPrimaryAction(for level: AISecurityAttentionLevel) -> String? {
        switch level {
        case .stop, .caution: return "openSecurityReport"
        case .info, .none: return nil
        }
    }

    private static func deterministicAttention(for facts: AISecurityAttentionFacts,
                                               level: AISecurityAttentionLevel) -> [String] {
        let hints = Set(facts.riskHints.map { $0.lowercased() })
        var out: [String] = []
        if !hints.isDisjoint(with: stopHints) { out.append("path-escape-samples") }
        if hints.contains("executable") || hints.contains("setuid") || hints.contains("setgid")
            || hints.contains("script") { out.append("executable-content") }
        if hints.contains("symlink") || hints.contains("hardlink") { out.append("links-present") }
        if facts.encryptedEntryCount > 0 { out.append("encrypted-entries-present") }
        if hints.contains("macos-junk") { out.append("macos-junk-present") }
        return dedup(out)
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
