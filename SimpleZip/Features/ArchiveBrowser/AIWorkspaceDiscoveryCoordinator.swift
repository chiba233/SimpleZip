//
//  AIWorkspaceDiscoveryCoordinator.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 文件夹的**后台发现编排者**(白皮书:后台自动发现是魂)。
//
//  ⚠️ 与当前文件夹 0 关系。它从**全局 AI 数据层**的派生记录汇总候选,跑 `AIWorkspaceStore.refreshRecommendations`
//  生成跨位置推荐主题。当前数据源 = 活动任务历史(`ActivityTaskAIIndex`);**后续接白名单文件预索引
//  (`AIFileMemoryIndex`,工程补充六 opt-in 白名单扫描)作为主来源**。这里只负责汇总 + 触发,不读当前 folder、
//  不挂导航 / reload 路径(A17 天然规避)。
//

import Foundation

@MainActor
final class AIWorkspaceDiscoveryCoordinator {
    static let shared = AIWorkspaceDiscoveryCoordinator()

    /// 启动后台索引 / 预读(AI suggestion 的基座)。**AI 文件夹的后台自动发现已下线**(概念废弃):不再订阅活动
    /// 历史、不再自动跑 `refreshRecommendations` —— 那是给已下线的推荐工作区 + 模型复核(DevTools「复核 发X/判否Y」)
    /// 白干活。`refresh()` 保留为按需入口,留待后续侧栏「建议总览」调用。
    func activate() {
        AIBackgroundIndexer.shared.runIfEnabled()
    }

    /// 汇总当前可用的全局数据层派生记录 → 跑一轮发现。文件来源 = opt-in 白名单预索引(`AIFileMemoryIndex`),
    /// 任务来源 = 活动任务历史(封顶最近 120 条)。store 内部 gated(AI 主开关 + 显示推荐),主题无变化时不刷新
    /// UI(值相等守卫,A17 安全)。**与当前文件夹无关。**
    func refresh() {
        let policy = AIWorkspaceReviewPumpPolicy(
            displayLimit: AppPreferences.aiMaxRecommendedWorkspaces,
            hiddenCandidateCount: 0,
            activityLevel: AppPreferences.aiBackgroundActivityLevel)
        guard policy.allowsAutomaticIteration else { return }
        let tasks = TaskCenter.shared.history.prefix(policy.discoveryTaskRecordLimit).map(\.aiTaskRecord)
        let files = AIBackgroundIndexStore.shared.recentFileRecords(limit: policy.discoveryFileRecordLimit)
        // 本会话扫到的 记录 id → 真实路径(给节点「显示来源目录 / 在 Finder 显示 / 哈希」用;路径不落盘)。
        let paths = AIBackgroundIndexStore.shared.pathsBySourceRef(limit: max(policy.discoveryFileRecordLimit, 1))
        AIWorkspaceStore.shared.refreshRecommendations(files: files, tasks: Array(tasks), pathsBySourceRef: paths)
    }
}
