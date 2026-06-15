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
    private var activated = false

    /// 启动后台发现。订阅活动任务历史**数量变化**(去重 → 避开进度刷新风暴)→ 重跑发现;`@Published` 在订阅时
    /// 即推送当前值,故首轮发现自动触发。重复调用安全(已激活则只补跑一轮)。
    func activate() {
        guard !activated else { refresh(); return }
        activated = true
        cancellable = TaskCenter.shared.$history
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// 汇总当前可用的全局数据层派生记录 → 跑一轮发现。当前:活动任务历史(封顶最近 300 条)。
    /// 后续在此加入白名单文件预索引产出的 `AIFileMemoryRecord`。store 内部 gated(AI 主开关 + 显示推荐),
    /// 主题无变化时不刷新 UI(值相等守卫,A17 安全)。
    func refresh() {
        let tasks = TaskCenter.shared.history.prefix(300).map(\.aiTaskRecord)
        AIWorkspaceStore.shared.refreshRecommendations(tasks: Array(tasks))
    }
}
