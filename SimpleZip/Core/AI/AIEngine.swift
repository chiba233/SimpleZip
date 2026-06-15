//
//  AIEngine.swift
//  SimpleZip
//
//  0.4.5 #80:AI 引擎能力分层与协商(白皮书工程补充二「模型能力分层与可替换 AI 引擎」+ 补充十七
//  「T0 原则:AI 入口常驻,模型增强可选」)。架构铁律是「强数据底座 + 可替换模型执行器」:
//  数据底座(索引/画像/反馈/source ref/安全校验)不可替换;模型执行器可替换;安全控制永不交给模型。
//
//  这里只放**纯值契约 + 确定性协商**:能力等级、UI 可用姿态、引擎描述、功能能力需求、协商器。
//  真正带 `generate<Output>` 的 `AIEngine` protocol 留 App 层绑 FoundationModels —— Core 不依赖模型框架
//  (工程补充十五:Core 放纯 Codable / 算法,App 放 adapter)。纯函数,SwiftPM 可断言。
//

import Foundation

/// 引擎能力等级(工程补充二 L0–L2)。`Comparable` —— 用于「满足最低 / 取最接近 preferred」的协商。
///
/// - `none`:完全没有 AI 能力(理论值,实际确定性底座恒在)。
/// - `deterministicOnly`:无模型,只输出确定性建议 / 搜索 / 排序(L0 底座)。
/// - `appleOnDevice`:Apple 端上 FoundationModels(L1,默认实现)。
/// - `advancedOptional`:可选高级模型(L2,用户自带 / 未来更强本地模型),必须可选且不破坏本地默认体验。
nonisolated enum AICapabilityLevel: String, Codable, Equatable, CaseIterable, Sendable, Comparable {
    case none
    case deterministicOnly
    case appleOnDevice
    case advancedOptional

    private var order: Int {
        switch self {
        case .none: return 0
        case .deterministicOnly: return 1
        case .appleOnDevice: return 2
        case .advancedOptional: return 3
        }
    }

    static func < (lhs: AICapabilityLevel, rhs: AICapabilityLevel) -> Bool { lhs.order < rhs.order }
}

/// UI 读取的 AI 可用姿态(工程补充十七)。把「AI 是否出现」和「模型是否可用」拆开:
/// **AI surface 常驻**(数据索引 / 确定性建议 / 隐私状态无模型也显示),只有「生成式增强控件」受此 gate。
///
/// - `deterministicOnly`:展示 surface + 基础建议 + 「本机模型暂不可用」说明。
/// - `appleModelAvailable`:展示完整生成式增强。
/// - `disabledByUser`:隐藏生成式入口;AI 中心「数据与隐私 / 重新开启」入口仍可从设置打开。
nonisolated enum AIAvailabilityMode: String, Codable, Equatable, Sendable {
    case deterministicOnly = "deterministic_only"
    case appleModelAvailable = "apple_model_available"
    case disabledByUser = "disabled_by_user"

    /// 是否渲染生成式增强(模型润色 / 排序 / 自然语言)。仅 `appleModelAvailable` 为真。
    var showsGenerativeEnhancements: Bool { self == .appleModelAvailable }

    /// 是否渲染常驻 AI surface(确定性建议 / 数据索引 / 隐私状态)。用户未关时恒在。
    var showsDeterministicSurface: Bool { self != .disabledByUser }
}

/// 一个引擎当前的可用性快照。
nonisolated struct AIEngineAvailability: Codable, Equatable, Sendable {
    let isAvailable: Bool
    let level: AICapabilityLevel
    /// 不可用 / 降级原因(稳定英文 token),如 `model_not_ready` / `disabled_by_user` / `unsupported_os`。
    let reason: String?

    init(isAvailable: Bool, level: AICapabilityLevel, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.level = level
        self.reason = reason
    }

    /// 不可用 —— 退回确定性底座。
    static let deterministicFallback = AIEngineAvailability(
        isAvailable: true, level: .deterministicOnly, reason: "model_not_ready"
    )
}

/// 引擎的纯值描述(id / 展示名 / 能力等级)。真正的 `generate` 由 App adapter 实现 —— Core 只描述能力,
/// 不绑模型框架。
nonisolated struct AIEngineDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let capabilityLevel: AICapabilityLevel

    init(id: String, displayName: String, capabilityLevel: AICapabilityLevel) {
        self.id = id
        self.displayName = displayName
        self.capabilityLevel = capabilityLevel
    }
}

/// 一个 AI 功能声明自己需要什么能力(工程补充二「能力协商」)。让某场景在不同引擎可用性下确定性选择引擎,
/// 即使 Apple 本地模型不够强也不卡架构。
nonisolated struct AIFeatureCapabilityRequirement: Codable, Equatable, Sendable {
    let featureID: String
    /// 能跑起来的最低能力(很多 feat 是 `deterministicOnly` —— 无模型也工作)。
    let minimumLevel: AICapabilityLevel
    /// 理想能力(够得到时优先用,但不过度升到更高级引擎)。
    let preferredLevel: AICapabilityLevel
    let requiresStructuredOutput: Bool
    let requiresToolCalling: Bool
    /// 是否允许动用 `advancedOptional`(L2)引擎。默认否 —— L2 必须可选、不破坏本地默认体验。
    let allowsAdvancedOptionalEngine: Bool

    init(
        featureID: String,
        minimumLevel: AICapabilityLevel,
        preferredLevel: AICapabilityLevel,
        requiresStructuredOutput: Bool = true,
        requiresToolCalling: Bool = false,
        allowsAdvancedOptionalEngine: Bool = false
    ) {
        self.featureID = featureID
        self.minimumLevel = minimumLevel
        self.preferredLevel = preferredLevel
        self.requiresStructuredOutput = requiresStructuredOutput
        self.requiresToolCalling = requiresToolCalling
        self.allowsAdvancedOptionalEngine = allowsAdvancedOptionalEngine
    }

    /// 某能力等级是否满足该功能的最低要求。
    func isSatisfied(by level: AICapabilityLevel) -> Bool { level >= minimumLevel }
}

/// 确定性能力协商:为某功能从一组可用引擎里挑引擎,并把「用户开关 + 最佳可用等级」解析成 UI 可用姿态。
/// 纯函数 —— 同一输入逐次一致,可单测。
nonisolated enum AICapabilityNegotiator {
    /// 为 `requirement` 选最合适引擎:
    /// 1. 滤掉低于 `minimumLevel` 的;`allowsAdvancedOptionalEngine == false` 时排除 `advancedOptional`。
    /// 2. 在满足 `preferredLevel` 的引擎里选**最低**等级(刚好够、不过度);
    /// 3. 都够不到 preferred 时,在合格引擎里选**最高**等级(尽量接近 preferred)。
    /// 同等级按 `id` 升序确定性。无合格引擎返回 nil。
    static func resolve(
        requirement: AIFeatureCapabilityRequirement,
        from engines: [AIEngineDescriptor]
    ) -> AIEngineDescriptor? {
        let eligible = engines.filter {
            $0.capabilityLevel >= requirement.minimumLevel
                && (requirement.allowsAdvancedOptionalEngine || $0.capabilityLevel != .advancedOptional)
        }
        guard !eligible.isEmpty else { return nil }

        let meetsPreferred = eligible.filter { $0.capabilityLevel >= requirement.preferredLevel }
        if !meetsPreferred.isEmpty {
            // 刚好够 preferred:取最低等级,同级 id 升序。
            return meetsPreferred.sorted {
                $0.capabilityLevel != $1.capabilityLevel
                    ? $0.capabilityLevel < $1.capabilityLevel
                    : $0.id < $1.id
            }.first
        }
        // 够不到 preferred:取最高等级,同级 id 升序。
        return eligible.sorted {
            $0.capabilityLevel != $1.capabilityLevel
                ? $0.capabilityLevel > $1.capabilityLevel
                : $0.id < $1.id
        }.first
    }

    /// 把「用户是否开启 AI + 当前最佳可用能力等级」解析成 UI 姿态。用户关闭恒 `disabledByUser`;
    /// 否则有端上模型(≥ `appleOnDevice`)→ `appleModelAvailable`,只有确定性底座 → `deterministicOnly`。
    static func availabilityMode(
        aiEnabledByUser: Bool,
        bestAvailableLevel: AICapabilityLevel
    ) -> AIAvailabilityMode {
        guard aiEnabledByUser else { return .disabledByUser }
        return bestAvailableLevel >= .appleOnDevice ? .appleModelAvailable : .deterministicOnly
    }
}
