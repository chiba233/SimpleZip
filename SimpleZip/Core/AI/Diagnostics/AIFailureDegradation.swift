//
//  AIFailureDegradation.swift
//  SimpleZip
//
//  0.4.5 #80:AI 失败降级矩阵(白皮书工程补充十二)。**每个 AI 场景都必须有确定性 fallback —— AI 失败不能让
//  功能不可用**。这里把「失败类型 → 降级策略 / 调试分类」编码成确定性映射,供各场景统一处理。
//
//  通用铁律(白皮书):AI 输出不能成为唯一数据源;可点动作必须来自 App 预定义枚举;**AI 失败时不弹阻塞
//  alert**(除非用户主动打开调试详情);调试记录要区分「模型失败 / 校验失败 / 隐私阻断 / 用户关闭」。
//  纯枚举映射、确定性,SwiftPM 可断言。
//

import Foundation

/// AI 场景可能遇到的失败类型(白皮书工程补充十二矩阵的行)。
nonisolated enum AIFailureKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// FoundationModels 不可用。
    case modelUnavailable = "model_unavailable"
    /// 用户关闭了 AI 总开关。
    case userDisabled = "user_disabled"
    /// prompt 超预算。
    case promptOverBudget = "prompt_over_budget"
    /// 模型输出 JSON 解析失败。
    case jsonParseFailed = "json_parse_failed"
    /// schema 版本不匹配。
    case schemaMismatch = "schema_mismatch"
    /// 模型引用了不存在的 source ref。
    case sourceRefInvalid = "source_ref_invalid"
    /// 模型返回了危险 / 未定义动作。
    case dangerousAction = "dangerous_action"
    /// 模型返回空结果。
    case emptyResult = "empty_result"
    /// redaction 命中高风险内容,阻断本次调用。
    case redactionBlocked = "redaction_blocked"
    /// 归档 / 派生缓存过期。
    case cacheStale = "cache_stale"
    /// 习惯摘要损坏。
    case habitCorrupted = "habit_corrupted"
}

/// 确定性降级策略(矩阵的「处理方式」列)。
nonisolated enum AIDegradationStrategy: String, Codable, Equatable, Sendable {
    /// 用确定性建议 / 搜索 / 排序顶上。
    case useDeterministic = "use_deterministic"
    /// 隐藏 AI 入口或显示「已关闭,可重新开启」说明。
    case hideOrExplainDisabled = "hide_or_explain_disabled"
    /// 本地召回后截断,写入 omissions,结果仍显示。
    case truncateWithOmissions = "truncate_with_omissions"
    /// 丢弃 AI 输出,回退确定性结果。
    case discardAIOutput = "discard_ai_output"
    /// 尝试迁移;失败则丢弃派生缓存重建(用户数据保壳)。
    case migrateOrRebuild = "migrate_or_rebuild"
    /// 丢弃该节点 / 证据(引用无效)。
    case dropElement = "drop_element"
    /// 丢弃危险动作,保留只读解释(或整条丢)。
    case dropActionKeepReadonly = "drop_action_keep_readonly"
    /// 显示「为什么没有推荐」空状态解释。
    case showEmptyStateReason = "show_empty_state_reason"
    /// 阻断本次 AI 调用,显示基础(确定性)结果。
    case blockShowBasic = "block_show_basic"
    /// 重建缓存或显示过期说明。
    case rebuildOrExplainStale = "rebuild_or_explain_stale"
}

/// 调试分类 —— 白皮书要求区分这四类,便于排查「AI 说废话」到底是哪一环。
nonisolated enum AIFailureCategory: String, Codable, Equatable, Sendable {
    case modelFailure = "model_failure"
    case validationFailure = "validation_failure"
    case privacyBlock = "privacy_block"
    case userDisabled = "user_disabled"
}

nonisolated enum AIFailureDegradation {
    /// 失败类型 → 确定性降级策略(白皮书矩阵)。
    static func strategy(for kind: AIFailureKind) -> AIDegradationStrategy {
        switch kind {
        case .modelUnavailable: return .useDeterministic
        case .userDisabled: return .hideOrExplainDisabled
        case .promptOverBudget: return .truncateWithOmissions
        case .jsonParseFailed: return .discardAIOutput
        case .schemaMismatch: return .migrateOrRebuild
        case .sourceRefInvalid: return .dropElement
        case .dangerousAction: return .dropActionKeepReadonly
        case .emptyResult: return .showEmptyStateReason
        case .redactionBlocked: return .blockShowBasic
        case .cacheStale: return .rebuildOrExplainStale
        case .habitCorrupted: return .migrateOrRebuild
        }
    }

    /// 失败类型 → 调试分类。
    static func category(for kind: AIFailureKind) -> AIFailureCategory {
        switch kind {
        case .modelUnavailable, .jsonParseFailed, .emptyResult, .promptOverBudget:
            return .modelFailure
        case .schemaMismatch, .sourceRefInvalid, .dangerousAction, .cacheStale, .habitCorrupted:
            return .validationFailure
        case .redactionBlocked:
            return .privacyBlock
        case .userDisabled:
            return .userDisabled
        }
    }

    /// **铁律:AI 失败时不弹阻塞 alert**。恒 false —— 任何失败都静默降级,不打断用户。
    /// (调试详情只在用户主动打开调试页时展示。)
    static func showsBlockingAlert(for kind: AIFailureKind) -> Bool { false }

    /// AI 输出是否仍可作为唯一数据源 —— 恒 false(白皮书通用规则:AI 输出永远要有确定性兜底)。
    static var aiOutputCanBeSoleSource: Bool { false }
}
