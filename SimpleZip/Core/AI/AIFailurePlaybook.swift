//
//  AIFailurePlaybook.swift
//  SimpleZip
//
//  0.4.5 #80:失败修复手册(白皮书 Feat 4)。不让模型看完整日志去猜根因 —— 先由确定性
//  `AIDiagnosticsClassifier` 给标签,再由本手册按标签给出**固定修复流程**:有序步骤 token + 建议动作 token。
//  模型只把这套固定流程「贴合当前任务」表达成人话,不发明步骤。
//
//  这里只放**稳定英文 token**(步骤 key / 动作 token / 标题 key),不放本地化文案 —— 由 UI 层本地化、
//  或交给模型措辞,避免在 Core 引未建的 L10n key(半接线)。同一标签积累固定流程,纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 一个诊断标签对应的修复手册:标题 + 有序步骤 + 建议下一步动作(全部稳定英文 token)。
nonisolated struct AIFailurePlaybook: Codable, Equatable, Sendable {
    let tag: AIDiagnosticTag
    /// 标题 token(UI 本地化 / 模型贴合表达)。
    let headlineKey: String
    /// 有序修复步骤的稳定 key。
    let stepKeys: [String]
    /// 建议的下一步动作 token(open-folder / locate-missing-volume / supply-password / retest /
    /// free-disk-space / request-permission / choose-destination / verify-signature / wait-or-retry)。
    let suggestedAction: String
}

nonisolated enum AIFailurePlaybookLibrary {
    /// 诊断标签优先级(越靠前越具体 / 可操作)—— 多个标签同时命中时,选最该先处理的那个。
    static let priority: [AIDiagnosticTag] = [
        .needsPassword,
        .missingVolume,
        .permissionDenied,
        .diskSpace,
        .destinationConflict,
        .signatureProblem,
        .checksumMismatch,
        .corruptArchive,
        .unsupportedFormat,
        .interruptedPreviousSession,
        .cancelledByUser
    ]

    /// 按优先级选出最该处理的标签的手册。一个可识别标签都没有 → nil(由调用点退回通用失败解释)。
    static func playbook(for tags: [AIDiagnosticTag]) -> AIFailurePlaybook? {
        let present = Set(tags)
        guard let tag = priority.first(where: present.contains) else { return nil }
        return playbook(for: tag)
    }

    /// 单标签手册。每个标签的固定修复流程。
    static func playbook(for tag: AIDiagnosticTag) -> AIFailurePlaybook {
        switch tag {
        case .needsPassword:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "needs-password",
                stepKeys: ["confirm-archive-is-encrypted", "enter-correct-password", "retry-with-password"],
                suggestedAction: "supply-password")
        case .missingVolume:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "missing-volume",
                stepKeys: ["gather-all-volume-parts-in-one-folder",
                           "check-for-incomplete-downloads",
                           "retest-or-extract-after-complete"],
                suggestedAction: "locate-missing-volume")
        case .permissionDenied:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "permission-denied",
                stepKeys: ["check-destination-is-writable",
                           "choose-a-writable-destination",
                           "grant-folder-access-if-needed"],
                suggestedAction: "request-permission")
        case .diskSpace:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "disk-space",
                stepKeys: ["free-up-space-on-destination-volume",
                           "or-choose-a-volume-with-more-space",
                           "retry"],
                suggestedAction: "free-disk-space")
        case .destinationConflict:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "destination-conflict",
                stepKeys: ["existing-files-would-be-overwritten",
                           "extract-into-a-new-folder",
                           "or-choose-overwrite-policy"],
                suggestedAction: "choose-destination")
        case .signatureProblem:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "signature-problem",
                stepKeys: ["signature-could-not-be-verified-or-trusted",
                           "confirm-the-public-key-is-imported-and-trusted",
                           "do-not-rely-on-an-unverified-archive"],
                suggestedAction: "verify-signature")
        case .checksumMismatch:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "checksum-mismatch",
                stepKeys: ["data-does-not-match-expected-checksum",
                           "re-download-or-re-obtain-the-file",
                           "retest-after-obtaining-a-good-copy"],
                suggestedAction: "retest")
        case .corruptArchive:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "corrupt-archive",
                stepKeys: ["archive-appears-damaged",
                           "re-obtain-the-archive-if-possible",
                           "try-data-rescue-to-recover-readable-files"],
                suggestedAction: "retest")
        case .unsupportedFormat:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "unsupported-format",
                stepKeys: ["this-format-or-method-is-not-supported",
                           "confirm-the-file-is-actually-an-archive",
                           "try-a-different-tool-if-needed"],
                suggestedAction: "open-folder")
        case .interruptedPreviousSession:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "interrupted-previous-session",
                stepKeys: ["a-previous-run-left-incomplete-output",
                           "remove-or-move-the-partial-output",
                           "retry-from-a-clean-state"],
                suggestedAction: "wait-or-retry")
        case .cancelledByUser:
            return AIFailurePlaybook(
                tag: tag, headlineKey: "cancelled-by-user",
                stepKeys: ["the-operation-was-cancelled",
                           "rerun-it-when-ready"],
                suggestedAction: "wait-or-retry")
        }
    }
}
