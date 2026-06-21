//
//  AIBackgroundIndexRun.swift
//  SimpleZipCore
//
//  独立 AI 进程改造 · 阶段2 · 后台预索引**一轮扫描的纯编排**。
//
//  把原本内联在 `AIBackgroundIndexer.runIfEnabled` 里 `Task.detached` 那段「按最久没扫取预算内 scope → 逐个
//  `AIIndexerScan.scanScope` → 收记录」抽成 Core 纯函数,**App 前台(心跳)与 agent 后台(launchd 周期拉起)
//  共用同一份编排**(A2:别让两处各拷一份扫描循环)。**这里不发明任何新机制** —— 排序 / 预算 / 取消都是现成的。
//
//  「跑不完留待下次续」是**现成的渐进覆盖机制**,不是本函数新加的:`scopeBudget` 每轮只取 N 个、
//  `leastRecentlyScanned` 把没扫过 / 扫得最久的排队首、调用方扫完一个就 `markScanned` —— 没轮到的 scope 保持旧
//  `lastScannedAt`,下一轮自然排到最前续上。多轮把全部白名单轮一遍(省电档每轮 1 个也终会全覆盖)。
//
//  agent 的「单次后台 timeout」也**不需要专门参数**:超时只是「该停了」的一种原因,直接折进现成的 `isCancelled`
//  停止钩子(agent 传 `{ Date() >= 截止时刻 }`,App 传 `{ Task.isCancelled }`)。停下时已扫完的在返回里、调用方
//  已 `markScanned`,剩下的靠上面那套现成续扫机制下次接着跑。本函数只管「这一轮按序扫到被叫停 / 预算用尽为止」。
//
//  纯函数:只依赖入参 + `AIIndexerScan` / `AIArchivePrefetchScope`(同在 Core),不碰任何实例 / UI 状态 /
//  全局可变量,可被 SwiftPM 单测。**调度门控(电源 / 空闲 / 间隔)不在这里** —— 那是调用方(App 的
//  `AIBackgroundSchedulingRules` 闸 / agent 的 launchd 间隔 + 电源判断)的事。
//

import Foundation

enum AIBackgroundIndexRun {

    /// 一个 scope 扫描完的产物:scope 标识 + 这一轮扫到的文件记录。调用方据此 `ingest` + `markScanned`。
    nonisolated struct ScopeResult: Sendable {
        let scopeID: UUID
        let records: [AIFileMemoryRecord]
    }

    /// 扫描进度事件(给 CLI / DevTools 滚动 log;App 后台默认不订阅)。
    nonisolated enum ScanEvent: Sendable {
        case willScanScope(done: Int, total: Int, directoryPath: String)
        case didScanScope(done: Int, total: Int, directoryPath: String, records: Int)
    }

    /// 跑一轮预索引扫描(纯编排,off-main 由调用方安排)。
    ///
    /// - Parameters:
    ///   - scopes: **全部**白名单 scope(本函数内部按 `leastRecentlyScanned` 排序 + 取 `scopeBudget` 个,
    ///     调用方不必预排);从没扫过的最优先,其余按上次扫描时间升序 → 多轮把所有目录轮一遍(现成渐进覆盖)。
    ///   - home: `NSHomeDirectory()`(目录分类 / 敏感目录判定用)。
    ///   - scopeBudget: 这一轮最多扫几个 scope(= 活跃度档的 `maxDirectoriesPerRound`,至少 1)。
    ///   - fileBudget: 单 scope 最多记多少文件(= `min(maxEntriesPerArchive, 3000)`)。
    ///   - allowContent: 是否在元数据之外补**内容摘要**(更高隐私等级,仅「预读内容」开关开时为 true)。
    ///   - existingSummarized: 上一轮已有摘要的记录(id → 记录),给渐进覆盖做「指纹没变就沿用旧摘要、不重读」。
    ///   - isCancelled: **唯一停止钩子**,每个 scope 前问一次。App 传 `{ Task.isCancelled }`;agent 把单次 timeout
    ///     折进这里(传 `{ Date() >= 截止时刻 }`)—— 超时和取消同一个口子,无需另设 deadline 参数。返回 true 即停,
    ///     未扫的 scope 不在返回里、`lastScannedAt` 不变,靠现成 `leastRecentlyScanned` 续扫机制下轮接着跑。
    /// - Returns: **已扫完**的 scope 结果(顺序 = 实际扫描顺序);被叫停时只含已完成的那些。
    nonisolated static func scan(scopes: [AIArchivePrefetchScope],
                                 home: String,
                                 scopeBudget: Int,
                                 fileBudget: Int,
                                 allowContent: Bool,
                                 existingSummarized: [String: AIFileMemoryRecord] = [:],
                                 isCancelled: () -> Bool = { false },
                                 progress: (ScanEvent) -> Void = { _ in }) -> [ScopeResult] {
        let picked = scopes
            .sorted(by: AIArchivePrefetchScope.leastRecentlyScanned)
            .prefix(max(1, scopeBudget))
        let total = picked.count
        var results: [ScopeResult] = []
        for (i, scope) in picked.enumerated() {
            if isCancelled() { break }
            progress(.willScanScope(done: i, total: total, directoryPath: scope.directoryPath))
            let records = AIIndexerScan.scanScope(scope, home: home, fileBudget: fileBudget,
                                                  allowContent: allowContent,
                                                  existingSummarized: existingSummarized)
            results.append(ScopeResult(scopeID: scope.id, records: records))
            progress(.didScanScope(done: i + 1, total: total, directoryPath: scope.directoryPath, records: records.count))
        }
        return results
    }
}
