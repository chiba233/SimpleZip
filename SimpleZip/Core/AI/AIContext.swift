//
//  AIContext.swift
//  SimpleZip
//
//  0.4.5 #80:统一 AI 数据层的共享契约 ——「本地事实索引 + 小模型智能组织层」的底座。
//  分工铁律:App 负责扫描 / 索引 / 过滤 / 脱敏 / 召回候选并校验一切 ref;模型只解释 / 命名 / 排序 /
//  归组 / 产结构化建议。所有路径 / 任务 id / 归档 entry id 都由 App 校验,危险动作一律回原生确认流。
//
//  这里只放**纯值类型契约**:信封、用途、隐私分级、来源引用、省略说明、证据卡。各场景 builder 把现有
//  模型转成这些事实,prompt 里只放干净的 JSON facts(枚举用稳定英文 token,不随 UI 语言走)。确定性编码
//  (sortedKeys),同一输入逐字节一致 —— 可单测、可 debug 导出确认不含红线数据。
//
//  **红线**(见仓库隐私口径):口令 / GPG 私钥材料 / GPG 密文 / 加密归档条目名 / 解密明文绝不进入任何信封。
//  `AIPrivacyLevel.blockedSensitive` 这类数据永不组装;每个信封都带 `omissions` 说明被排除了什么、为什么。
//

import Foundation

/// AI 上下文的用途场景。稳定英文 token —— prompt / 测试 / debug 导出共用一套标识,不随 UI 语言走。
nonisolated enum AIContextPurpose: String, Codable, Equatable, CaseIterable, Sendable {
    case activityFilter
    case failureExplanation
    case archiveFinder
    case archiveProfile
    case createAdvisory
    case extractAdvisory
    case reportExplanation
    case settingsAssistant
    case actionRecommendation
    case automationIdeas
    case habitSummary
    case operationPreview
    case aiCenterHome
    case aiWorkspaceTheme
    case aiWorkspaceTree
}

/// 数据敏感分级 —— 决定某事实能不能进信封。`blockedSensitive` 永不组装进 prompt / 缓存 / 索引 / 日志。
///
/// - `publicAppCatalog`:应用内静态目录(设置项 / 动作目录 / 帮助索引 / 格式能力矩阵)。可完整给 AI。
/// - `localUserMetadata`:本机使用元数据(任务 / 路径类别 / 文件名 / **非加密**归档条目名 / 设置当前值)。
///   可给 AI,但有预算、可清空、可调试。
/// - `diagnostics`:失败消息 / 错误行 / 后端输出尾部 / 文件系统状态。可给 AI,但必须先 redaction。
/// - `blockedSensitive`:口令 / passphrase / 密钥材料 / 加密条目名 / 密文 / 解密明文。**永远不给 AI。**
nonisolated enum AIPrivacyLevel: String, Codable, Equatable, Sendable {
    case publicAppCatalog
    case localUserMetadata
    case diagnostics
    case blockedSensitive

    /// 是否允许把这一级别的数据组装进发给模型的信封。`blockedSensitive` 恒否。
    var isAssemblable: Bool { self != .blockedSensitive }
}

/// 本地上下文强度(路线图建议二「深度本地上下文模式」/ 工程补充二)。两种默认可理解的数据模式:
/// - `standardLocalContext`:默认。给足本机元数据(完整当前路径、非加密文件名 / 条目名、任务 facts、
///   设置当前值、报告 facts、错误行、短日志尾)。
/// - `deepLocalContext`:用户可选开启。额外允许非加密文本 marker 短摘要、固定路径别名、更多结构样本、
///   更长历史窗口、更完整报告 finding。**深度模式不突破红线** —— 口令 / 密钥 / 加密条目名 / 密文 /
///   解密明文 / 用户明确排除的路径仍然禁止。
nonisolated enum AIContextMode: String, Codable, Equatable, Sendable {
    case standardLocalContext = "standard_local_context"
    case deepLocalContext = "deep_local_context"
}

/// 信封的隐私描述块:明确「在哪执行 + 什么强度 + 哪些红线类别确认未包含」,可写进 prompt / debug 导出,
/// 让模型与审计都看得到本次上下文的隐私姿态。
nonisolated struct AIPrivacyDescriptor: Codable, Equatable, Sendable {
    /// 执行位置 —— 端上 Apple FoundationModels(全本地、不外发)。
    let execution: String
    let level: AIPrivacyLevel
    let mode: AIContextMode
    // 红线类别确认:无论何种模式,这三项恒 false。
    let passwordsIncluded: Bool
    let encryptedEntryNamesIncluded: Bool
    let decryptedContentIncluded: Bool
    /// 仅深度模式 true:允许非加密文本 marker 的短摘要进入上下文。
    let localTextSnippetsIncluded: Bool

    init(level: AIPrivacyLevel, mode: AIContextMode = .standardLocalContext) {
        self.execution = "on_device_apple_foundation_models"
        self.level = level
        self.mode = mode
        self.passwordsIncluded = false
        self.encryptedEntryNamesIncluded = false
        self.decryptedContentIncluded = false
        self.localTextSnippetsIncluded = (mode == .deepLocalContext)
    }
}

/// 指向一个可回查的本地对象。**AI 输出里引用的 ref 必须能在 App 侧校验存在,否则整条丢弃** ——
/// 模型不能凭空发明路径 / 任务 id / 条目 id。
nonisolated struct AIContextSourceRef: Codable, Equatable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Equatable, Sendable {
        case file
        case folder
        case archive
        case archiveEntry
        case task
        case report
        case setting
        case habit
        case action
        case workspace
    }

    let kind: Kind
    let id: String

    init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// 因为加密 / 体积 / TTL / 上限 / 权限而被省略的数据说明。**每个信封都应带至少相关的几条** ——
/// 明确告诉模型「哪些数据没给、为什么没给」,既防幻觉也便于隐私审计。
nonisolated struct AIContextOmission: Codable, Equatable, Sendable {
    /// 稳定英文 token,如 `encrypted_entry_names`、`raw_logs`、`task_count_truncated`。
    let type: String
    /// 省略了多少(可空 —— 例如「永不包含口令」没有具体计数)。
    let count: Int?
    /// 省略的策略 / 原因,如 `never_included`、`names_not_available_to_ai`、`candidate_budget`。
    let policy: String

    init(type: String, count: Int? = nil, policy: String) {
        self.type = type
        self.count = count
        self.policy = policy
    }

    // 常用省略的便捷构造(红线相关固定文案,避免各处手写飘移)。

    /// 加密归档条目名 —— 名字 / 内容绝不进 AI,只保留计数提示。
    static func encryptedEntryNames(count: Int? = nil) -> AIContextOmission {
        AIContextOmission(type: "encrypted_entry_names", count: count, policy: "names_not_available_to_ai")
    }

    /// 口令 / passphrase / 密钥材料 —— 永不包含。
    static let passwords = AIContextOmission(type: "passwords", policy: "never_included")

    /// 原始日志 —— 只抽错误行 + 短尾部,不给完整 raw output。
    static func rawLogsErrorLinesOnly(keptChars: Int? = nil) -> AIContextOmission {
        AIContextOmission(type: "raw_logs", count: keptChars, policy: "error_lines_and_short_tail")
    }

    /// 大数组按 top-N 截断,说明省略了多少。
    static func truncated(type: String, omitted: Int, reason: String = "budget") -> AIContextOmission {
        AIContextOmission(type: type, count: omitted, policy: reason)
    }

    /// 完整绝对路径 —— 长期学习只存位置类别 + 路径哈希 + 目录名 token。
    static let fullPathsAsCategoriesOnly = AIContextOmission(
        type: "full_paths", policy: "stored_as_location_categories_only"
    )
}

/// 证据事实:一条 AI 建议背后用到的一个本地事实(建议十八「AI 证据卡」)。
/// 让用户能看到 AI 是根据任务 / 归档 / 路径 / 报告还是习惯做的判断,直接解决「AI 像玄学」。
nonisolated struct AIEvidenceFact: Codable, Equatable, Sendable {
    /// 这条证据是什么,如「最近测试任务失败」。
    let label: String
    /// 支撑的具体事实串(稳定英文 token / 短事实),如 `["source=cli", "status=failed", "tag=checksum-mismatch"]`。
    let facts: [String]
    /// 可回查的来源(任务 / 归档 / 报告…);App 校验存在,不存在则整条证据丢弃。
    let sourceRef: AIContextSourceRef?

    init(label: String, facts: [String], sourceRef: AIContextSourceRef? = nil) {
        self.label = label
        self.facts = facts
        self.sourceRef = sourceRef
    }
}

/// 证据卡:一条 AI 建议「为什么这么判断 + 用了哪些事实 + 省略了什么」。
nonisolated struct AIEvidenceCard: Codable, Equatable, Sendable {
    let title: String
    let reason: String
    let evidence: [AIEvidenceFact]
    let omissions: [AIContextOmission]

    init(title: String, reason: String, evidence: [AIEvidenceFact] = [], omissions: [AIContextOmission] = []) {
        self.title = title
        self.reason = reason
        self.evidence = evidence
        self.omissions = omissions
    }
}

/// AI 上下文信封:一个场景一次性发给模型的全部受控事实。
///
/// `Facts` 是该场景的结构化事实负载(每个场景一个 Codable 类型);`omissions` 说明省略了什么;
/// `sourceRefs` 是本次提供的可回查对象集合(AI 输出引用的 ref 必须落在这个集合里)。
///
/// `jsonString()` 产确定性紧凑 JSON,prompt 里直接嵌入。**不要**把对象 dump 成自然语言 ——
/// JSON 字段稳定、便于测试、也更容易确认没有红线数据。
nonisolated struct AIContextEnvelope<Facts: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    /// schema 版本标识 —— 将来字段演进 / 模型回归测试锚点。
    let schema: String
    let purpose: AIContextPurpose
    let privacy: AIPrivacyDescriptor
    let facts: Facts
    let omissions: [AIContextOmission]
    let sourceRefs: [AIContextSourceRef]

    static var schemaVersion: String { "simplezip.ai.context.v1" }

    init(
        purpose: AIContextPurpose,
        privacyLevel: AIPrivacyLevel,
        mode: AIContextMode = .standardLocalContext,
        facts: Facts,
        omissions: [AIContextOmission] = [],
        sourceRefs: [AIContextSourceRef] = []
    ) {
        self.schema = Self.schemaVersion
        self.purpose = purpose
        self.privacy = AIPrivacyDescriptor(level: privacyLevel, mode: mode)
        self.facts = facts
        self.omissions = omissions
        self.sourceRefs = sourceRefs
    }

    /// 确定性紧凑 JSON(同一输入逐字节一致)。prompt 里直接放;`/` 不转义,保持路径可读。
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// 校验模型输出里引用的 source ref 是否都在 App 本次提供的候选集内 —— **模型不能发明引用**:不在候选集的
/// ref 整条丢弃。路线图工程补充一验收(「所有虚拟节点都有可回查 source ref」)+ 补充十明确要求的安全闸。
nonisolated enum AIContextSourceRefValidator {
    /// 单个 ref 是否在候选集内。
    static func isValid(_ ref: AIContextSourceRef, allowed: Set<AIContextSourceRef>) -> Bool {
        allowed.contains(ref)
    }

    /// 一组 ref 是否**全部**在候选集内(空集合视为 vacuously 有效 —— 是否接受空 ref 由调用点决定)。
    static func allRefsValid(_ refs: [AIContextSourceRef], allowed: Set<AIContextSourceRef>) -> Bool {
        refs.allSatisfy { allowed.contains($0) }
    }

    /// 把一批 ref 分成(在候选集内, 被拒)。保持输入顺序。
    static func partition(_ refs: [AIContextSourceRef], allowed: Set<AIContextSourceRef>)
        -> (valid: [AIContextSourceRef], rejected: [AIContextSourceRef]) {
        var valid: [AIContextSourceRef] = []
        var rejected: [AIContextSourceRef] = []
        for ref in refs {
            if allowed.contains(ref) { valid.append(ref) } else { rejected.append(ref) }
        }
        return (valid, rejected)
    }

    /// 过滤一组带 ref 的元素(虚拟节点 / 建议 / 动作):只保留「引用的 ref 全部有效」的元素。
    /// 含发明 ref 的节点被整条丢弃 —— 安全 > 完整。
    static func keepingValid<Element>(_ elements: [Element], allowed: Set<AIContextSourceRef>,
                                      refs: (Element) -> [AIContextSourceRef]) -> [Element] {
        elements.filter { allRefsValid(refs($0), allowed: allowed) }
    }
}

/// 确定性、低暴露的稳定哈希(FNV-1a 32-bit → 8 位十六进制)。**非加密用途** —— 只为「同一对象」识别,
/// 不暴露原始路径 / 内容。位置哈希(`loc-`)、归档 id(`arch-`)等共用此实现,避免重复造轮子(A2)。
nonisolated enum AIStableHash {
    static func fnv1a32Hex(_ string: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return String(format: "%08x", hash)
    }

    /// 把一个稳定 id 字符串确定性映射成 UUID(同输入逐次一致)。用于把字符串候选 id 落成需要 `UUID` 的
    /// 虚拟节点 id —— 这样虚拟树可在无 `Date`/`随机` 的前提下完全可复现、可单测。**非加密用途**:
    /// 由 4 段不同盐的 FNV-1a 拼成 16 字节,非 RFC 4122 v4,只为稳定身份。
    static func deterministicUUID(_ string: String) -> UUID {
        let segments = (0..<4).map { fnv1a32Hex(string + "#\($0)") }
        let hex = segments.joined()  // 32 个十六进制字符
        let i = hex.startIndex
        func slice(_ from: Int, _ to: Int) -> Substring {
            hex[hex.index(i, offsetBy: from)..<hex.index(i, offsetBy: to)]
        }
        let formatted = "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
        return UUID(uuidString: formatted) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}
