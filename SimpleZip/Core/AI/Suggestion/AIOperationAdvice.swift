//
//  AIOperationAdvice.swift
//  SimpleZip
//
//  0.4.5 #80:创建/解压「Operation Advice Cards」(白皮书「专项:创建/解压 AI 建议从『一句话速览』升级成
//  Operation Advice Cards」)。把内联速览从「一段文本」升级成「可点击、可解释、可回滚的表单建议」。
//
//  这层是**确定性规则引擎**:从现有 dry-run / preflight / 画像事实直接产建议卡,**无模型也工作**(`AIGate`
//  只 gate 模型润色,不 gate 整个建议区域)。卡片只携带稳定规则 id + 证据 token + allowlist 内的动作 ——
//  **不产 UI 文案**(title/body 留给 App 按 id 做 L10n,或模型按界面语言润色)。模型只能润色 title/body/
//  排序,动作 id / patch id 必须落在 App 给的 allowlist 内,否则剔除。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 操作建议卡的严重度。`blocked` 最高(强阻断),`info` 最低(只提醒)。
nonisolated enum AIOperationAdviceSeverity: String, Codable, Equatable, Sendable, Comparable {
    case info
    case suggestion
    case warning
    case blocked

    private var order: Int {
        switch self {
        case .info: return 0
        case .suggestion: return 1
        case .warning: return 2
        case .blocked: return 3
        }
    }

    static func < (lhs: AIOperationAdviceSeverity, rhs: AIOperationAdviceSeverity) -> Bool { lhs.order < rhs.order }
}

/// 一张操作建议卡。规则引擎产稳定结构(id + 证据 + 动作),模型只润色 `title`/`body`/排序。
nonisolated struct AIOperationAdviceCard: Codable, Equatable, Identifiable, Sendable {
    /// 稳定规则标识(rename-output / review-security / strip-root …)。App 按它做 L10n 与图标。
    let id: String
    let severity: AIOperationAdviceSeverity
    /// 模型润色文案;确定性版为 nil → App 按 `id` 查本地化文案。
    let title: String?
    let body: String?
    let evidence: [AIEvidenceFact]
    /// 主动作 id(openSecurityReport / renameOutput …),必须在 scope 的 allowlist 内。
    let primaryActionID: String?
    /// 表单 patch 动作 id(enableSkipSymlinks …),只改表单不开始操作;必须在 allowlist 内。
    let optionPatchIDs: [String]
    /// 「为什么不建议另一个做法」(模型产,确定性版为空)。
    let whyNot: [String]

    init(
        id: String, severity: AIOperationAdviceSeverity, title: String? = nil, body: String? = nil,
        evidence: [AIEvidenceFact] = [], primaryActionID: String? = nil,
        optionPatchIDs: [String] = [], whyNot: [String] = []
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.body = body
        self.evidence = evidence
        self.primaryActionID = primaryActionID
        self.optionPatchIDs = optionPatchIDs
        self.whyNot = whyNot
    }
}

/// 创建/解压操作建议计划。`summary` 模型润色(nil 时 App 自行兜底);卡片为空表示「无需注意」。
nonisolated struct AIOperationAdvicePlan: Codable, Equatable, Sendable {
    let scope: AIOperationScope
    let summary: String?
    let cards: [AIOperationAdviceCard]

    init(scope: AIOperationScope, summary: String? = nil, cards: [AIOperationAdviceCard]) {
        self.scope = scope
        self.summary = summary
        self.cards = cards
    }
}

/// 创建操作建议的确定性事实(纯标量;App adapter 从 `ArchiveCreationDryRun` / 估算 / 画像填充,不引用 app-only 类型)。
nonisolated struct AICreateAdviceFacts: Codable, Equatable, Sendable {
    let inputFileCount: Int
    let totalBytes: Int64
    let excludedCount: Int
    let symlinkCount: Int
    let packageCount: Int
    let estimatedVolumeCount: Int?
    let outputExists: Bool
    let format: String
    let destinationLocationKind: String
    let guessedRoles: [String]

    init(
        inputFileCount: Int, totalBytes: Int64, excludedCount: Int = 0, symlinkCount: Int = 0,
        packageCount: Int = 0, estimatedVolumeCount: Int? = nil, outputExists: Bool = false,
        format: String, destinationLocationKind: String, guessedRoles: [String] = []
    ) {
        self.inputFileCount = inputFileCount
        self.totalBytes = totalBytes
        self.excludedCount = excludedCount
        self.symlinkCount = symlinkCount
        self.packageCount = packageCount
        self.estimatedVolumeCount = estimatedVolumeCount
        self.outputExists = outputExists
        self.format = format
        self.destinationLocationKind = destinationLocationKind
        self.guessedRoles = guessedRoles
    }
}

/// 解压操作建议的确定性事实(纯标量)。含当前表单状态 —— 用来决定要不要建议某开关(已开的不再建议)。
nonisolated struct AIExtractAdviceFacts: Codable, Equatable, Sendable {
    let fileCount: Int
    let totalBytes: Int64
    let symlinkCount: Int
    let suspiciousEntryCount: Int
    let encryptedEntryCount: Int
    let overwriteCount: Int
    let missingVolumeCount: Int
    let lowSpace: Bool
    let detectedSingleRootFolder: String?
    let semanticTags: [String]
    // 当前表单状态
    let skipSymlinks: Bool
    let autoRenameConflicts: Bool
    let stripSingleRootFolder: Bool
    let destinationLocationKind: String

    init(
        fileCount: Int, totalBytes: Int64, symlinkCount: Int = 0, suspiciousEntryCount: Int = 0,
        encryptedEntryCount: Int = 0, overwriteCount: Int = 0, missingVolumeCount: Int = 0,
        lowSpace: Bool = false, detectedSingleRootFolder: String? = nil, semanticTags: [String] = [],
        skipSymlinks: Bool = false, autoRenameConflicts: Bool = false,
        stripSingleRootFolder: Bool = false, destinationLocationKind: String
    ) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.symlinkCount = symlinkCount
        self.suspiciousEntryCount = suspiciousEntryCount
        self.encryptedEntryCount = encryptedEntryCount
        self.overwriteCount = overwriteCount
        self.missingVolumeCount = missingVolumeCount
        self.lowSpace = lowSpace
        self.detectedSingleRootFolder = detectedSingleRootFolder
        self.semanticTags = semanticTags
        self.skipSymlinks = skipSymlinks
        self.autoRenameConflicts = autoRenameConflicts
        self.stripSingleRootFolder = stripSingleRootFolder
        self.destinationLocationKind = destinationLocationKind
    }
}

/// 确定性操作建议规则引擎。无模型也工作。
nonisolated enum AIOperationAdviceRuleEngine {
    /// scope 的动作 / patch allowlist(白皮书逐项)。`sanitize` 据此剔除模型发明的非法动作。
    static func allowedActions(scope: AIOperationScope) -> Set<String> {
        switch scope {
        case .create:
            return ["renameOutput", "openDestinationChooser", "applySourceArchivePreset",
                    "applyReleasePackagePreset", "enableTestAfterCreate", "openExcludeRules",
                    "switchTo7z", "keepCurrentSettings"]
        case .extract:
            return ["enableStripSingleRoot", "enableSkipSymlinks", "enableAutoRenameConflicts",
                    "openSecurityReport", "chooseDifferentDestination", "locateMissingVolumes",
                    "keepCurrentSettings"]
        }
    }

    // MARK: - 创建

    static func createCards(from f: AICreateAdviceFacts) -> [AIOperationAdviceCard] {
        var cards: [AIOperationAdviceCard] = []
        if f.outputExists {
            cards.append(AIOperationAdviceCard(
                id: "rename-output", severity: .suggestion,
                evidence: [AIEvidenceFact(label: "output", facts: ["outputExists=true"])],
                primaryActionID: "renameOutput"))
        }
        if f.symlinkCount > 0 {
            cards.append(AIOperationAdviceCard(
                id: "warn-symlinks", severity: .info,
                evidence: [AIEvidenceFact(label: "dryRun", facts: ["symlinkCount=\(f.symlinkCount)"])]))
        }
        if f.packageCount > 0 {
            cards.append(AIOperationAdviceCard(
                id: "warn-package", severity: .info,
                evidence: [AIEvidenceFact(label: "dryRun", facts: ["packageCount=\(f.packageCount)"])]))
        }
        if let volumes = f.estimatedVolumeCount, volumes > 1 {
            cards.append(AIOperationAdviceCard(
                id: "warn-volumes", severity: .info,
                evidence: [AIEvidenceFact(label: "estimate", facts: ["estimatedVolumeCount=\(volumes)"])]))
        }
        if f.excludedCount > 0 {
            cards.append(AIOperationAdviceCard(
                id: "review-excludes", severity: .info,
                evidence: [AIEvidenceFact(label: "dryRun", facts: ["excludedCount=\(f.excludedCount)"])],
                primaryActionID: "openExcludeRules"))
        }
        return sortedBySeverity(cards)
    }

    static func createPlan(from f: AICreateAdviceFacts) -> AIOperationAdvicePlan {
        AIOperationAdvicePlan(scope: .create, cards: createCards(from: f))
    }

    // MARK: - 解压

    static func extractCards(from f: AIExtractAdviceFacts) -> [AIOperationAdviceCard] {
        var cards: [AIOperationAdviceCard] = []
        if f.suspiciousEntryCount > 0 {
            cards.append(AIOperationAdviceCard(
                id: "review-security", severity: .warning,
                evidence: [AIEvidenceFact(label: "preflight", facts: ["suspiciousEntryCount=\(f.suspiciousEntryCount)"])],
                primaryActionID: "openSecurityReport"))
        }
        if f.missingVolumeCount > 0 {
            cards.append(AIOperationAdviceCard(
                id: "locate-volumes", severity: .warning,
                evidence: [AIEvidenceFact(label: "preflight", facts: ["missingVolumeCount=\(f.missingVolumeCount)"])],
                primaryActionID: "locateMissingVolumes"))
        }
        if f.lowSpace {
            cards.append(AIOperationAdviceCard(
                id: "choose-destination", severity: .warning,
                evidence: [AIEvidenceFact(label: "diskSpace", facts: ["lowSpace=true"])],
                primaryActionID: "chooseDifferentDestination"))
        }
        if f.symlinkCount > 0 && !f.skipSymlinks {
            cards.append(AIOperationAdviceCard(
                id: "skip-symlinks", severity: .suggestion,
                evidence: [AIEvidenceFact(label: "preflight", facts: ["symlinkCount=\(f.symlinkCount)"])],
                primaryActionID: "enableSkipSymlinks", optionPatchIDs: ["enableSkipSymlinks"]))
        }
        if f.overwriteCount > 0 && !f.autoRenameConflicts {
            cards.append(AIOperationAdviceCard(
                id: "auto-rename", severity: .suggestion,
                evidence: [AIEvidenceFact(label: "preflight", facts: ["overwriteCount=\(f.overwriteCount)"])],
                primaryActionID: "enableAutoRenameConflicts", optionPatchIDs: ["enableAutoRenameConflicts"]))
        }
        if let root = f.detectedSingleRootFolder, !root.isEmpty, !f.stripSingleRootFolder {
            cards.append(AIOperationAdviceCard(
                id: "strip-root", severity: .suggestion,
                evidence: [AIEvidenceFact(label: "structure", facts: ["topLevelShape=single_root_folder"])],
                primaryActionID: "enableStripSingleRoot", optionPatchIDs: ["enableStripSingleRoot"]))
        }
        return sortedBySeverity(cards)
    }

    static func extractPlan(from f: AIExtractAdviceFacts) -> AIOperationAdvicePlan {
        AIOperationAdvicePlan(scope: .extract, cards: extractCards(from: f))
    }

    // MARK: - 模型输出校验

    /// 校验模型润色后的 plan:每张 card 的 `primaryActionID` 不在 allowlist 则置 nil,`optionPatchIDs`
    /// 过滤只留 allowlist 内的(模型发明的动作被剔除,card 本身保留)。
    static func sanitize(_ plan: AIOperationAdvicePlan) -> AIOperationAdvicePlan {
        let allowed = allowedActions(scope: plan.scope)
        let cards = plan.cards.map { card -> AIOperationAdviceCard in
            let action = card.primaryActionID.flatMap { allowed.contains($0) ? $0 : nil }
            let patches = card.optionPatchIDs.filter { allowed.contains($0) }
            return AIOperationAdviceCard(
                id: card.id, severity: card.severity, title: card.title, body: card.body,
                evidence: card.evidence, primaryActionID: action, optionPatchIDs: patches, whyNot: card.whyNot)
        }
        return AIOperationAdvicePlan(scope: plan.scope, summary: plan.summary, cards: cards)
    }

    // MARK: -

    /// 严重度降序(warning 在 suggestion 前),同级保持插入顺序(稳定排序)。
    private static func sortedBySeverity(_ cards: [AIOperationAdviceCard]) -> [AIOperationAdviceCard] {
        cards.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity != rhs.element.severity
                    ? lhs.element.severity > rhs.element.severity
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
