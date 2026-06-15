//
//  AIIntentRouter.swift
//  SimpleZip
//
//  0.4.5 #80:AI 场景路由器(白皮书建议二十四)。让 AI 像一个整体而非一堆分散入口:用户一句话,App 按当前
//  surface + 选择 + 可用能力**确定性**判断走哪个 AI 场景;模型只在低置信度时辅助,且目标必须在可用能力内。
//
//  安全/边界:① `destination` 必须落在 `availableCapabilities`(App 当前可达的场景)内,模型选了不可用的目标,
//  `clamp` 退回确定性路由;② `confidence` 钳到 [0,1];③ 不执行任何动作 —— 只决定「打开哪个 AI 场景」。
//  纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

/// AI 场景目标(稳定英文 token,与白皮书一致)。
nonisolated enum AIIntentDestination: String, Codable, CaseIterable, Equatable, Sendable {
    case activityFilter
    case archiveSearch
    case operationPreview
    case failureExplanation
    case settingsAssistant
    case aiWorkspace
    case actionRecommendation
    case reportExplanation
}

/// 路由输入。`availableCapabilities` 为当前可达场景的 rawValue 集合(空 = 全部可用)。
/// (白皮书示例里的 `recentContextSummary: AIContextEnvelope` 是泛型信封,路由判定用不到,故不并入此值类型。)
nonisolated struct AIIntentRoutingInput: Codable, Equatable, Sendable {
    let userText: String
    let surface: String
    let currentMode: String
    let selectedSourceRefs: [AIContextSourceRef]
    let availableCapabilities: [String]

    init(userText: String, surface: String, currentMode: String = "",
         selectedSourceRefs: [AIContextSourceRef] = [], availableCapabilities: [String] = []) {
        self.userText = userText
        self.surface = surface
        self.currentMode = currentMode
        self.selectedSourceRefs = selectedSourceRefs
        self.availableCapabilities = availableCapabilities
    }
}

/// 路由结果。`reason` 模型润色(确定性版给稳定 token)。
nonisolated struct AIIntentRoutingResult: Codable, Equatable, Sendable {
    let destination: AIIntentDestination
    let confidence: Double
    let extractedQuery: String
    let reason: String?

    init(destination: AIIntentDestination, confidence: Double, extractedQuery: String, reason: String? = nil) {
        self.destination = destination
        self.confidence = confidence
        self.extractedQuery = extractedQuery
        self.reason = reason
    }
}

nonisolated enum AIIntentRouter {
    /// 确定性路由:按 surface + selection 选目标(无模型)。目标若不在可用能力内,退回 `actionRecommendation`。
    static func deterministicRoute(_ input: AIIntentRoutingInput) -> AIIntentRoutingResult {
        let query = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (preferred, confidence, reason) = preferredDestination(for: input)
        let dest = isAvailable(preferred, in: input) ? preferred : resolvedFallback(in: input)
        let conf = dest == preferred ? confidence : 0.4
        return AIIntentRoutingResult(destination: dest, confidence: conf, extractedQuery: query, reason: reason)
    }

    /// 钳制模型路由:目标必须在可用能力内,否则退回确定性路由;confidence 钳到 [0,1]。
    static func clamp(_ result: AIIntentRoutingResult, for input: AIIntentRoutingInput) -> AIIntentRoutingResult {
        let conf = min(max(result.confidence, 0), 1)
        if isAvailable(result.destination, in: input) {
            return AIIntentRoutingResult(destination: result.destination, confidence: conf,
                                         extractedQuery: result.extractedQuery, reason: result.reason)
        }
        let fallback = deterministicRoute(input)
        let query = result.extractedQuery.isEmpty ? fallback.extractedQuery : result.extractedQuery
        return AIIntentRoutingResult(destination: fallback.destination,
                                     confidence: min(conf, fallback.confidence),
                                     extractedQuery: query, reason: result.reason)
    }

    // MARK: - 确定性细节

    private static func preferredDestination(for input: AIIntentRoutingInput)
        -> (AIIntentDestination, Double, String) {
        let surface = input.surface.lowercased()
        let kinds = Set(input.selectedSourceRefs.map(\.kind))

        switch surface {
        case "activity", "activity-center", "activitycenter":
            return (.activityFilter, 0.75, "surface=activity")
        case "settings", "setting":
            return (.settingsAssistant, 0.75, "surface=settings")
        case "ai-workspace", "aiworkspace", "sidebar", "workspace":
            return (.aiWorkspace, 0.7, "surface=workspace")
        case "archive-memory", "memory", "search":
            return (.archiveSearch, 0.7, "surface=memory")
        case "report", "reports":
            return (.reportExplanation, 0.75, "surface=report")
        case "browser", "archive", "files":
            if kinds.contains(.task) { return (.failureExplanation, 0.6, "selection=task") }
            if kinds.contains(.report) { return (.reportExplanation, 0.6, "selection=report") }
            if kinds.contains(.archive) { return (.operationPreview, 0.7, "selection=archive") }
            return (.actionRecommendation, 0.45, "surface=browser")
        default:
            // 无明确 surface:有选择就按选择类型,否则推荐动作。
            if kinds.contains(.archive) { return (.operationPreview, 0.55, "selection=archive") }
            if kinds.contains(.task) { return (.failureExplanation, 0.55, "selection=task") }
            return (.actionRecommendation, 0.4, "fallback")
        }
    }

    /// 可用能力为空 = 全部可用;否则按 rawValue 判断。
    static func isAvailable(_ dest: AIIntentDestination, in input: AIIntentRoutingInput) -> Bool {
        input.availableCapabilities.isEmpty || input.availableCapabilities.contains(dest.rawValue)
    }

    /// 退回目标:优先 `actionRecommendation`,不可用则取可用能力里的第一个(确定性顺序)。
    private static func resolvedFallback(in input: AIIntentRoutingInput) -> AIIntentDestination {
        if isAvailable(.actionRecommendation, in: input) { return .actionRecommendation }
        for dest in AIIntentDestination.allCases where input.availableCapabilities.contains(dest.rawValue) {
            return dest
        }
        return .actionRecommendation
    }
}
