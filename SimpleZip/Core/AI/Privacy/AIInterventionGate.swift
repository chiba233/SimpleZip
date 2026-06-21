//
//  AIInterventionGate.swift
//  SimpleZip
//
//  0.4.5 #80:AI 打扰阈值门(白皮书「轻工具优先:AI 必须有打扰阈值」)。SimpleZip 首先是压缩/解压工具,
//  不是任务管理器 —— **AI 不决定自己要不要出现,出现强度由 Swift 规则决定**。任何 AI 工作区 / Operation
//  Preview / Advice Card / Auto-Tune 都先过这道门;它放在 `AISuggestionBus` / 规则引擎**之前**。
//
//  默认目标是让用户更快完成操作,而不是多看一个界面。无风险的 Finder 双击保持安静;只有真实风险信号
//  (覆盖 / 缺卷 / 可疑路径 / 符号链接 / 低空间)或高价值归档角色才升级到建议卡;自动解压路径要特别克制,
//  绝不被 AI 打断。纯规则、确定性,SwiftPM 可断言。
//

import Foundation

/// AI 介入强度,从不打扰到强提示逐级升高。`Comparable` —— 便于「至少 X 级才显示某控件」。
nonisolated enum AIInterventionLevel: String, Codable, Equatable, CaseIterable, Sendable, Comparable {
    /// 完全不出现。
    case silent
    /// 仅状态栏轻提示,不抢焦点。
    case statusOnly = "status_only"
    /// 一行内联速览(替代现在的 sparkle 文案)。
    case inlineHint = "inline_hint"
    /// 可展开的建议卡(1–3 张,带证据和可点动作)。
    case adviceCards = "advice_cards"
    /// 强制操作预演(最高级)。由调用方在用户显式请求预演时使用 —— 门本身不主动升到这里。
    case requirePreview = "require_preview"

    private var order: Int {
        switch self {
        case .silent: return 0
        case .statusOnly: return 1
        case .inlineHint: return 2
        case .adviceCards: return 3
        case .requirePreview: return 4
        }
    }

    static func < (lhs: AIInterventionLevel, rhs: AIInterventionLevel) -> Bool { lhs.order < rhs.order }
}

/// 打扰阈值判定的输入(纯 facts,不含红线)。字段来自现有预检 / 画像 / 偏好。
nonisolated struct AIInterventionGateInput: Codable, Equatable, Sendable {
    let surface: AISuggestionSurfaceID
    /// 任务 / 打开来源 token(finder / app / cli / spotlight …)。
    let source: String
    let fileByteSize: Int64?
    let archiveExtension: String?
    let overwriteCount: Int
    let missingVolumeCount: Int
    let suspiciousEntryCount: Int
    let symlinkCount: Int
    let lowSpaceWarning: Bool
    /// 归档角色 / 语义标签(来自 `ArchiveProfile.semanticTags`)。命中高价值角色值得升级。
    let archiveRoleTags: [String]
    /// `AppPreferences.finderOpenAutoExtract` —— 自动打开 / 解压路径要特别克制,绝不被 AI 打断。
    let finderAutoExtract: Bool
    /// 用户是否主动打开 AI 中心 / 工作区 / Lens(主动请求才允许重型 UI)。
    let userRequestedAI: Bool

    init(
        surface: AISuggestionSurfaceID,
        source: String,
        fileByteSize: Int64? = nil,
        archiveExtension: String? = nil,
        overwriteCount: Int = 0,
        missingVolumeCount: Int = 0,
        suspiciousEntryCount: Int = 0,
        symlinkCount: Int = 0,
        lowSpaceWarning: Bool = false,
        archiveRoleTags: [String] = [],
        finderAutoExtract: Bool = false,
        userRequestedAI: Bool = false
    ) {
        self.surface = surface
        self.source = source
        self.fileByteSize = fileByteSize
        self.archiveExtension = archiveExtension
        self.overwriteCount = overwriteCount
        self.missingVolumeCount = missingVolumeCount
        self.suspiciousEntryCount = suspiciousEntryCount
        self.symlinkCount = symlinkCount
        self.lowSpaceWarning = lowSpaceWarning
        self.archiveRoleTags = archiveRoleTags
        self.finderAutoExtract = finderAutoExtract
        self.userRequestedAI = userRequestedAI
    }

    /// 是否存在任何真实风险信号(覆盖 / 缺卷 / 可疑路径 / 符号链接 / 低空间)。
    var hasRiskSignal: Bool {
        overwriteCount > 0 || missingVolumeCount > 0 || suspiciousEntryCount > 0
            || symlinkCount > 0 || lowSpaceWarning
    }
}

/// 打扰阈值规则层。放在 `AISuggestionBus` / `OperationAdviceRuleEngine` **之前** —— AI 出现强度由这里说了算。
nonisolated enum AIInterventionGate {
    /// 高价值归档角色:命中即值得升级到建议卡(发布 / 源码 / 签名容器)。
    static let elevatedRoles: Set<String> = [
        "release-artifact", "release-package",
        "source-archive", "source-package",
        "signed-container", "signed-container-related",
    ]

    /// 判定本次该用哪一级介入强度。
    ///
    /// **自动解压(`finderAutoExtract`)是绝对天花板**:无论何种路径(含用户主动要 AI),最多 `inlineHint`,
    /// 绝不打断自动流 —— 这道钳制统一加在最外层,避免任何分支漏掉它(对抗审计发现过 `userRequestedAI`
    /// 先于钳制返回 `adviceCards` 的绕过)。
    static func level(for input: AIInterventionGateInput) -> AIInterventionLevel {
        let raw = unclampedLevel(for: input)
        if input.finderAutoExtract { return min(raw, .inlineHint) }
        return raw
    }

    /// 未经自动解压钳制的原始强度。
    /// 1. 用户主动打开 AI 中心 / 工作区 / Lens → `adviceCards`。
    /// 2. 有真实风险信号或命中高价值角色 → `adviceCards`。
    /// 3. 自动解压且无风险 → `silent`。
    /// 4. Finder 来源无风险(双击小包浏览) → `statusOnly`。
    /// 5. 其余(app 内打开对话框) → `inlineHint`。
    private static func unclampedLevel(for input: AIInterventionGateInput) -> AIInterventionLevel {
        if input.userRequestedAI { return .adviceCards }
        let elevatedRole = !Set(input.archiveRoleTags).isDisjoint(with: elevatedRoles)
        if input.hasRiskSignal || elevatedRole { return .adviceCards }
        if input.finderAutoExtract { return .silent }
        if input.source == "finder" { return .statusOnly }
        return .inlineHint
    }
}
