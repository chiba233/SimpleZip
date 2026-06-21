//
//  AIEmptyStateReason.swift
//  SimpleZip
//
//  0.4.5 #80:AI「为什么没有推荐」(白皮书建议二十三)。空状态不能只写「没有建议」—— 用户会以为 AI 坏了。
//  应该确定性地解释原因(任务太少 / 当前目录没归档 / 缓存为空 / 当前是加密清单 / 习惯学习已关 / 推荐都被关掉 /
//  模型暂不可用 / 候选被安全规则拦截),并给安全的下一步。
//
//  这里只放纯值类型 + 确定性推导(从索引状态快照推原因码 + 下一步)。文案由 UI 本地化;原因码 / 步骤是稳定
//  英文 token。纯函数,SwiftPM 可断言。
//

import Foundation

/// 推导空状态原因所需的索引状态快照(都是低敏计数 / 布尔)。
nonisolated struct AIEmptyStateInputs: Codable, Equatable, Sendable {
    let recentTaskCount: Int
    let nearbyArchiveCount: Int
    let archiveCacheCount: Int
    /// 当前打开的是头加密归档(条目名不可见,不能进 AI)。
    let currentArchiveEncryptedListing: Bool
    let habitLearningEnabled: Bool
    let allRecommendationsDismissed: Bool
    let modelAvailable: Bool
    /// 被安全规则拦掉的候选数(>0 说明有候选但都不安全)。
    let candidatesBlockedBySafety: Int

    init(recentTaskCount: Int = 0, nearbyArchiveCount: Int = 0, archiveCacheCount: Int = 0,
         currentArchiveEncryptedListing: Bool = false, habitLearningEnabled: Bool = true,
         allRecommendationsDismissed: Bool = false, modelAvailable: Bool = true,
         candidatesBlockedBySafety: Int = 0) {
        self.recentTaskCount = recentTaskCount
        self.nearbyArchiveCount = nearbyArchiveCount
        self.archiveCacheCount = archiveCacheCount
        self.currentArchiveEncryptedListing = currentArchiveEncryptedListing
        self.habitLearningEnabled = habitLearningEnabled
        self.allRecommendationsDismissed = allRecommendationsDismissed
        self.modelAvailable = modelAvailable
        self.candidatesBlockedBySafety = candidatesBlockedBySafety
    }
}

/// 空状态原因码(稳定英文 token)。
nonisolated enum AIEmptyStateReasonCode: String, Codable, Equatable, CaseIterable, Sendable {
    case encryptedListingUnavailable = "encrypted-listing-unavailable"
    case archiveCacheEmpty = "archive-cache-empty"
    case noNearbyArchives = "no-nearby-archives"
    case fewRecentTasks = "few-recent-tasks"
    case candidatesBlockedBySafety = "candidates-blocked-by-safety"
    case allRecommendationsDismissed = "all-recommendations-dismissed"
    case habitLearningDisabled = "habit-learning-disabled"
    case modelUnavailable = "model-unavailable"
}

/// 安全的下一步(稳定英文 token,UI 映射到实际导航)。
nonisolated enum AIEmptyStateNextStep: String, Codable, Equatable, CaseIterable, Sendable {
    case openArchive = "open-archive"
    case openAIPrivacySettings = "open-ai-privacy-settings"
    case openActivityCenter = "open-activity-center"
    case enableHabitLearning = "enable-habit-learning"
    case refresh
}

nonisolated struct AIEmptyStateReason: Codable, Equatable, Sendable {
    let surface: AISuggestionSurfaceID
    let codes: [AIEmptyStateReasonCode]
    let safeNextSteps: [AIEmptyStateNextStep]

    /// 没有可解释的原因(数据充足却仍空)—— 调用点据此显示通用空状态。
    var isEmpty: Bool { codes.isEmpty }
}

nonisolated enum AIEmptyStateAnalyzer {
    /// 从索引状态确定性推导原因码(固定优先级顺序)+ 对应安全下一步(去重保序)。
    static func analyze(surface: AISuggestionSurfaceID, inputs: AIEmptyStateInputs,
                        recentTaskThreshold: Int = 3) -> AIEmptyStateReason {
        var codes: [AIEmptyStateReasonCode] = []
        if inputs.currentArchiveEncryptedListing { codes.append(.encryptedListingUnavailable) }
        if inputs.archiveCacheCount == 0 { codes.append(.archiveCacheEmpty) }
        if inputs.nearbyArchiveCount == 0 { codes.append(.noNearbyArchives) }
        if inputs.recentTaskCount < recentTaskThreshold { codes.append(.fewRecentTasks) }
        if inputs.candidatesBlockedBySafety > 0 { codes.append(.candidatesBlockedBySafety) }
        if inputs.allRecommendationsDismissed { codes.append(.allRecommendationsDismissed) }
        if !inputs.habitLearningEnabled { codes.append(.habitLearningDisabled) }
        if !inputs.modelAvailable { codes.append(.modelUnavailable) }

        var steps: [AIEmptyStateNextStep] = []
        func add(_ step: AIEmptyStateNextStep) { if !steps.contains(step) { steps.append(step) } }
        for code in codes {
            switch code {
            case .archiveCacheEmpty, .noNearbyArchives: add(.openArchive)
            case .fewRecentTasks: add(.openActivityCenter)
            case .habitLearningDisabled: add(.enableHabitLearning); add(.openAIPrivacySettings)
            case .allRecommendationsDismissed, .candidatesBlockedBySafety: add(.refresh)
            case .encryptedListingUnavailable, .modelUnavailable: break
            }
        }
        return AIEmptyStateReason(surface: surface, codes: codes, safeNextSteps: steps)
    }
}
