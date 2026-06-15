//
//  AIOperationOptionPatch.swift
//  SimpleZip
//
//  0.4.5 #80:创建/解压「Operation Auto-Tune」的**安全核心**(白皮书「专项:创建/解压 AI 建议升级」之
//  「打开窗口时自动改写为最可能需要的版本」)。打开创建/解压窗口时,AI 可以把表单**预填**成「此时最可能
//  正确」的版本 —— 但它只改表单选项,绝不开始压缩/解压;所有改动可见、可撤销、可关闭。
//
//  这张表是「**哪些表单字段能被 AI 自动改**」的唯一安全权威:模型只能在 App 这张表说了算的范围内动表单。
//  密码 / GPG 私钥材料 / passphrase / 目标路径 / 移废纸篓 / 删源文件 / 自定义排除 / 原始参数永远是 suggestOnly
//  (只能建议、绝不自动改),碰加密内容的 change 直接丢弃。模型返回 patch id + change,App 自己应用 ——
//  模型绝不直接返回完整 options 对象。纯值 + 确定性安全闸,SwiftPM 可断言。
//

import Foundation

/// Auto-Tune 作用域:创建 / 解压。
nonisolated enum AIOperationScope: String, Codable, Equatable, CaseIterable, Sendable {
    case create
    case extract
}

/// Auto-Tune 模式(白皮书 `OperationAutoTuneMode`)。建议默认 `suggestOnly`;`autoApplyAggressive` 必须用户
/// 在设置里显式打开。
nonisolated enum AIOperationAutoTuneMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// 保持当前行为,不预填、不显示 Auto-Tune。
    case off
    /// 只显示建议卡,不自动改表单。
    case suggestOnly = "suggest_only"
    /// 打开窗口时自动套用低风险字段。
    case autoApplySafe = "auto_apply_safe"
    /// 额外允许更多偏好字段(谨慎档),但仍不碰密码 / GPG / 删源 / 危险动作。
    case autoApplyAggressive = "auto_apply_aggressive"
}

/// 单个表单字段允许 Auto-Tune 的策略(白皮书逐字段三档)。
nonisolated enum AIOperationFieldPolicy: String, Codable, Equatable, Sendable {
    /// 低风险:`autoApplySafe` / `autoApplyAggressive` 模式下都可自动改。
    case safeAutoApply = "safe_auto_apply"
    /// 谨慎:仅 `autoApplyAggressive` 模式 + 满足前置条件(如已启用密码才改加密算法)才自动;否则只建议。
    case cautiousAutoApply = "cautious_auto_apply"
    /// **只能建议、绝不自动改**:密码 / GPG / passphrase / 目标路径 / 移废纸篓 / 自定义排除 / 原始参数 / 删源文件。
    case suggestOnly = "suggest_only"
}

/// 创建 / 解压各字段的 Auto-Tune 策略表(白皮书逐字段三档)。静态、确定性、可单测。
/// **未列出的字段一律视为 `suggestOnly`** —— 不在白名单就绝不自动改(默认最保守,新字段不会意外被自动写)。
nonisolated enum AIOperationFieldCatalog {
    /// 创建侧字段策略(fieldID = `ArchiveCreationOptions` 的字段名)。
    static let create: [String: AIOperationFieldPolicy] = [
        // 低风险可自动改。
        "format": .safeAutoApply,
        "compressionLevel": .safeAutoApply,
        "updateMode": .safeAutoApply,
        "skipDSStore": .safeAutoApply,
        "skipHiddenFiles": .safeAutoApply,
        "sevenZipMethod": .safeAutoApply,
        "sevenZipDictionarySizeMB": .safeAutoApply,
        "sevenZipWordSize": .safeAutoApply,
        "sevenZipThreadCount": .safeAutoApply,
        "sevenZipSolidArchive": .safeAutoApply,
        "sevenZipSolidBlockSize": .safeAutoApply,
        "sevenZipPathMode": .safeAutoApply,
        "sevenZipStoreSymbolicLinks": .safeAutoApply,
        "sevenZipStoreHardLinks": .safeAutoApply,
        "sevenZipCompressSharedFiles": .safeAutoApply,
        "reproducibleArchive": .safeAutoApply,
        // 谨慎自动改(仅 aggressive + 前置条件)。
        "encryptionMethod": .cautiousAutoApply,        // 仅用户已启用密码时才按格式改算法
        "sevenZipEncryptFileNames": .cautiousAutoApply, // 仅用户已启用密码
        "sevenZipVolumeSize": .cautiousAutoApply,       // 可建议,谨慎写具体值
        "destinationExtensionFix": .cautiousAutoApply,  // 只修输出文件扩展名,不改目录
        // 只能建议、绝不自动改。
        "password": .suggestOnly,
        "passwordConfirmation": .suggestOnly,
        "showPassword": .suggestOnly,
        "gpgSigningKeyFingerprint": .suggestOnly,
        "gpgRecipientFingerprints": .suggestOnly,
        "gpgSymmetricPassphrase": .suggestOnly,
        "gpgDeliveryNote": .suggestOnly,
        "rawParameters": .suggestOnly,
        "customExcludes": .suggestOnly,
        "sevenZipDeleteSourceFiles": .suggestOnly,
        "destinationURL": .suggestOnly,
    ]

    /// 解压侧字段策略(fieldID = `ExtractArchiveRequest` 的字段名)。
    static let extract: [String: AIOperationFieldPolicy] = [
        // 低风险可自动改。
        "skipJunk": .safeAutoApply,
        "skipSymlinks": .safeAutoApply,
        "stripSingleRootFolder": .safeAutoApply,
        "extractIntoSubfolder": .safeAutoApply,
        "autoRenameConflicts": .safeAutoApply,
        "revealWhenDone": .safeAutoApply,
        // 只能建议、绝不自动改。
        "password": .suggestOnly,
        "zipDecryptionMethod": .suggestOnly,
        "gpgDecryptionKeyFingerprint": .suggestOnly,
        "gpgDecryptionPassphrase": .suggestOnly,
        "destinationURL": .suggestOnly,
        "trashOriginalWhenDone": .suggestOnly, // 会移动用户原始归档,必须用户当次确认
    ]

    /// 某字段的策略。未列出 → `suggestOnly`(最保守)。
    static func policy(scope: AIOperationScope, fieldID: String) -> AIOperationFieldPolicy {
        let table = scope == .create ? create : extract
        return table[fieldID] ?? .suggestOnly
    }

    /// 给定模式,某字段是否允许**自动应用**(无需用户点)。这是硬安全闸:
    /// - `off` / `suggestOnly` 模式:全 false(只展示建议)。
    /// - `autoApplySafe`:仅 `safeAutoApply` 字段。
    /// - `autoApplyAggressive`:`safeAutoApply` + `cautiousAutoApply` 字段。
    /// - `suggestOnly` 策略字段:**任何模式恒 false**(密码 / GPG / 删源等永不自动)。
    static func allowsAutoApply(scope: AIOperationScope, fieldID: String, mode: AIOperationAutoTuneMode) -> Bool {
        switch mode {
        case .off, .suggestOnly:
            return false
        case .autoApplySafe:
            return policy(scope: scope, fieldID: fieldID) == .safeAutoApply
        case .autoApplyAggressive:
            let p = policy(scope: scope, fieldID: fieldID)
            return p == .safeAutoApply || p == .cautiousAutoApply
        }
    }

    /// 某作用域的低风险可自动改字段(排序,确定性)。
    static func safeAutoApplyFields(scope: AIOperationScope) -> [String] {
        let table = scope == .create ? create : extract
        return table.filter { $0.value == .safeAutoApply }.keys.sorted()
    }
}

/// 一个 Auto-Tune patch:把表单往「此时最可能正确」调。模型返回 patch id + change,App 自己应用。
nonisolated struct AIOperationOptionPatch: Codable, Equatable, Sendable {
    /// 单个字段改动。`fromValue` 必须等于当前表单值,否则丢弃(防旧 patch 覆盖用户刚手改的字段)。
    nonisolated struct Change: Codable, Equatable, Sendable {
        let fieldID: String
        let fromValue: String
        let toValue: String
        let reason: String
        let evidence: [AIEvidenceFact]
        let safety: AISuggestionSafety
        /// true → 不能自动应用,只显示按钮等用户点(如移废纸篓这类破坏性整理)。
        let requiresExplicitClick: Bool

        init(
            fieldID: String, fromValue: String, toValue: String, reason: String,
            evidence: [AIEvidenceFact] = [], safety: AISuggestionSafety = .safe,
            requiresExplicitClick: Bool = false
        ) {
            self.fieldID = fieldID
            self.fromValue = fromValue
            self.toValue = toValue
            self.reason = reason
            self.evidence = evidence
            self.safety = safety
            self.requiresExplicitClick = requiresExplicitClick
        }
    }

    let scope: AIOperationScope
    let patchID: String
    let title: String
    let changes: [Change]
    /// 被模型 / 规则明确拒绝的字段说明(如 `password: never auto-filled`),仅供 UI / 调试展示。
    let rejectedChanges: [String]

    init(scope: AIOperationScope, patchID: String, title: String,
         changes: [Change], rejectedChanges: [String] = []) {
        self.scope = scope
        self.patchID = patchID
        self.title = title
        self.changes = changes
        self.rejectedChanges = rejectedChanges
    }
}

/// 一个 patch 经安全闸后的去向。
nonisolated struct AIOperationPatchResolution: Equatable, Sendable {
    /// 可自动应用(无需用户点)的 change。
    let autoApply: [AIOperationOptionPatch.Change]
    /// 只能作为按钮展示、等用户点的 change(suggestOnly 字段 / requiresExplicitClick / 破坏性 / 需确认)。
    let suggestOnly: [AIOperationOptionPatch.Change]
    /// 被拒绝丢弃的 change(碰加密内容 / `fromValue` 与当前不符 / 用户已手改该字段)。
    let rejected: [AIOperationOptionPatch.Change]

    static let empty = AIOperationPatchResolution(autoApply: [], suggestOnly: [], rejected: [])
}

/// Auto-Tune 安全闸 —— 把模型 / 规则产出的 patch 拆成(自动应用, 只建议, 拒绝)。**所有自动应用的硬前提都在这里。**
nonisolated enum AIOperationAutoTuneEngine {
    /// 拆分规则(顺序即优先级):
    /// 1. `mode == off` → 整体空(不预填、不显示)。
    /// 2. `safety.touchesEncryptedContent` → 拒绝(碰加密内容整条丢)。
    /// 3. 字段在 `userTouchedFields` 里 → 拒绝(用户碰过的字段 auto-tune 不覆盖)。
    /// 4. `fromValue != currentValues[fieldID]` → 拒绝(防旧 patch 覆盖用户刚手改的 / 过时建议)。
    /// 5. 满足自动应用资格(catalog `allowsAutoApply` && !requiresExplicitClick && !destructive
    ///    && !requiresConfirmation)→ `autoApply`;否则 → `suggestOnly`(展示按钮等用户点)。
    static func resolve(
        _ patch: AIOperationOptionPatch,
        mode: AIOperationAutoTuneMode,
        currentValues: [String: String],
        userTouchedFields: Set<String>
    ) -> AIOperationPatchResolution {
        guard mode != .off else { return .empty }

        var autoApply: [AIOperationOptionPatch.Change] = []
        var suggestOnly: [AIOperationOptionPatch.Change] = []
        var rejected: [AIOperationOptionPatch.Change] = []

        for change in patch.changes {
            if change.safety.touchesEncryptedContent { rejected.append(change); continue }
            if userTouchedFields.contains(change.fieldID) { rejected.append(change); continue }
            if currentValues[change.fieldID] != change.fromValue { rejected.append(change); continue }

            let eligible = AIOperationFieldCatalog.allowsAutoApply(scope: patch.scope, fieldID: change.fieldID, mode: mode)
                && !change.requiresExplicitClick
                && !change.safety.destructive
                && !change.safety.requiresConfirmation
            if eligible { autoApply.append(change) } else { suggestOnly.append(change) }
        }
        return AIOperationPatchResolution(autoApply: autoApply, suggestOnly: suggestOnly, rejected: rejected)
    }
}
