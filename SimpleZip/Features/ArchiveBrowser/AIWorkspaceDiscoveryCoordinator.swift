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

import Combine
import Foundation

@MainActor
final class AIWorkspaceDiscoveryCoordinator {
    static let shared = AIWorkspaceDiscoveryCoordinator()

    private var cancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var activated = false
    /// 启动后台发现。订阅活动任务历史**数量变化**(去重 → 避开进度刷新风暴)→ 排队重跑发现;`@Published` 在订阅时
    /// 即推送当前值,故首轮发现会被排队触发。重复调用安全(已激活则只补排一轮)。顺带 kick 一轮 opt-in 文件预索引
    /// (门控未过则什么都不做)—— 索引完成后它会回调 `refresh()` 把新文件记录纳入。
    func activate() {
        if !activated {
            activated = true
            cancellable = TaskCenter.shared.$history
                .map(\.count)
                .removeDuplicates()
                .sink { [weak self] _ in self?.scheduleRefresh() }
        } else {
            scheduleRefresh()
        }
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

    /// 首轮发现不能抢主窗口首帧。发现本身会做语义聚类(O(n²) pair 比较),所以把启动/历史变化压成一次
    /// 短延迟刷新;多次窗口 onAppear 或历史批量落盘只保留最后一次。
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }
}
