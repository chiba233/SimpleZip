//
//  AIDataLifecycle.swift
//  SimpleZip
//
//  0.4.5 #80:AI 数据保留、开关和清空策略(白皮书工程补充三)。「给 AI 更多数据」必须配套清晰的保留周期 +
//  用户控制。这里把白皮书的三张表变成**确定性映射**:① 每类 AI 数据的保留策略(持久化 / TTL / 上限);
//  ② 用户关闭某开关 → 对应 builder 该写进 `omissions` 的原因(复用 `AIContextOmission`);③ 清空入口 → 级联清掉
//  哪些派生数据类别。让数据与隐私页可预测、可审计。纯映射 + 确定性,SwiftPM 可断言。
//

import Foundation

/// AI 数据类别(受控词表;对应白皮书保留表的行)。
nonisolated enum AIDataCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case promptFacts = "prompt-facts"               // 当次 AI prompt facts
    case contextDebug = "context-debug"             // AI 上下文调试记录
    case activityIndex = "activity-index"           // 活动中心 AI 索引
    case archiveMemory = "archive-memory"           // 归档记忆索引
    case archiveProfile = "archive-profile"         // 归档画像
    case markerSummary = "marker-summary"           // 非加密文本 marker 摘要
    case workspaceTreeCache = "workspace-tree-cache" // AI 工作区虚拟树缓存
    case recommendedTheme = "recommended-theme"     // AI 推荐主题
    case userWorkspace = "user-workspace"           // 用户创建工作区
    case feedbackEvent = "feedback-event"           // AI 反馈事件(原始)
    case habitSummary = "habit-summary"             // 习惯摘要
}

/// 一类 AI 数据的保留策略。
nonisolated struct AIRetentionPolicy: Codable, Equatable, Sendable {
    /// 是否持久化(false = 仅本次调用,用完即弃)。
    let persists: Bool
    /// 独立 TTL 天数(nil = 不按时间过期)。
    let maxAgeDays: Int?
    /// 数量上限(nil = 不按数量裁剪)。
    let maxCount: Int?
    /// 是否跟随其它缓存(归档缓存 / 活动历史)过期 —— 本身不独立保存。
    let followsOtherCache: Bool

    init(persists: Bool, maxAgeDays: Int? = nil, maxCount: Int? = nil, followsOtherCache: Bool = false) {
        self.persists = persists
        self.maxAgeDays = maxAgeDays
        self.maxCount = maxCount
        self.followsOtherCache = followsOtherCache
    }
}

/// 用户可关闭的、会影响喂给 AI 的数据的开关(受控词表)。
nonisolated enum AIDataSwitch: String, Codable, CaseIterable, Equatable, Sendable {
    case aiEnabled
    case activityHistory          // 允许 AI 使用活动中心历史
    case archiveListingCache      // 允许 AI 使用归档清单缓存
    case fullPaths                // 允许 AI 使用当前完整路径
    case pathCategories           // 允许 AI 使用路径类别
    case folderNameTokens         // 允许 AI 使用文件夹名称 token
    case markerSummaries          // 允许 AI 读取非加密文本 marker 摘要(深度)
    case pinnedPathAliases        // 允许 AI 使用固定路径别名(深度)
    case backgroundHabit          // 允许后台习惯总结
    case recommendedWorkspaces    // 允许侧边栏显示推荐工作区
}

/// 清空入口(受控词表;对应白皮书清空策略)。
nonisolated enum AIClearScope: String, Codable, CaseIterable, Equatable, Sendable {
    case archiveListingCache      // 清空归档清单缓存
    case deepContext              // 清空 AI 深度上下文缓存
    case prefetchArchiveIndex     // 清空后台归档预读索引
    case fileIndex                // 清空后台文件预索引
    case activityHistory          // 清空活动中心历史
    case learningData             // 清空 AI 学习数据
    case userWorkspace            // 删除用户工作区
    case disableAI                // 关闭总 AI 开关(不清已有派生缓存)
}

nonisolated enum AIDataLifecycle {
    /// 每类数据的保留策略(白皮书保留表)。
    static func retentionPolicy(for category: AIDataCategory) -> AIRetentionPolicy {
        switch category {
        case .promptFacts:
            return AIRetentionPolicy(persists: false)
        case .contextDebug:
            return AIRetentionPolicy(persists: true, maxAgeDays: 1, maxCount: 20)
        case .activityIndex:
            return AIRetentionPolicy(persists: true, followsOtherCache: true)
        case .archiveMemory:
            return AIRetentionPolicy(persists: true, followsOtherCache: true)
        case .archiveProfile:
            return AIRetentionPolicy(persists: true, followsOtherCache: true)
        case .markerSummary:
            return AIRetentionPolicy(persists: true, followsOtherCache: true)
        case .workspaceTreeCache:
            return AIRetentionPolicy(persists: true, maxAgeDays: 7, maxCount: 50)
        case .recommendedTheme:
            return AIRetentionPolicy(persists: true, maxAgeDays: 7)
        case .userWorkspace:
            return AIRetentionPolicy(persists: true) // 用户删除前保留
        case .feedbackEvent:
            return AIRetentionPolicy(persists: true, maxAgeDays: 30)
        case .habitSummary:
            return AIRetentionPolicy(persists: true, maxAgeDays: 90)
        }
    }

    /// 用户关闭某开关时,对应 builder 该写进 `omissions` 的原因(policy 固定 `disabled_by_user`)。
    static func omission(forDisabled dataSwitch: AIDataSwitch) -> AIContextOmission {
        AIContextOmission(type: omissionType(for: dataSwitch), policy: "disabled_by_user")
    }

    private static func omissionType(for dataSwitch: AIDataSwitch) -> String {
        switch dataSwitch {
        case .aiEnabled: return "ai_disabled"
        case .activityHistory: return "activity_history"
        case .archiveListingCache: return "archive_listing_cache"
        case .fullPaths: return "full_paths"
        case .pathCategories: return "path_categories"
        case .folderNameTokens: return "folder_name_tokens"
        case .markerSummaries: return "marker_summaries"
        case .pinnedPathAliases: return "pinned_path_aliases"
        case .backgroundHabit: return "habit_summary"
        case .recommendedWorkspaces: return "recommended_workspaces"
        }
    }

    /// 一个清空入口会级联清掉哪些派生数据类别(白皮书清空策略)。**绝不删除任何真实文件 / 任务 / 归档本体。**
    static func categoriesCleared(by scope: AIClearScope) -> Set<AIDataCategory> {
        switch scope {
        case .archiveListingCache:
            // 清归档清单缓存 → 同时清归档记忆、画像、相关虚拟树缓存。
            return [.archiveMemory, .archiveProfile, .workspaceTreeCache]
        case .deepContext:
            // 清深度上下文 → 非加密 marker 摘要 + 深度模式画像增强字段。
            return [.markerSummary, .archiveProfile]
        case .prefetchArchiveIndex:
            // 清后台预读 → 归档记忆、画像、由它生成的工作区推荐主题。
            return [.archiveMemory, .archiveProfile, .recommendedTheme]
        case .fileIndex:
            // 清后台文件预索引 → 非加密文本 marker 摘要。
            return [.markerSummary]
        case .activityHistory:
            return [.activityIndex]
        case .learningData:
            return [.habitSummary, .feedbackEvent, .recommendedTheme]
        case .userWorkspace:
            // 删用户工作区 → prompt / 虚拟树缓存 / 折叠状态。不删源文件 / 任务 / 归档缓存。
            return [.userWorkspace, .workspaceTreeCache]
        case .disableAI:
            // 关总开关不清已有派生缓存(UI 不展示而已)。
            return []
        }
    }
}
