//
//  AIBackgroundIndexRun.swift
//  SimpleZipCore
//
//  独立 AI 进程改造 · 阶段2 · 后台预索引**一轮扫描的纯编排**。
//
//  把原本内联在 `AIBackgroundIndexer.runIfEnabled` 里 `Task.detached` 那段「按最久没扫取预算内 scope → 逐个
//  `AIIndexerScan.scanScope` → 收记录」抽成 Core 纯函数,**App 前台(心跳)与 agent 后台(launchd 周期拉起)
//  共用同一份编排**(A2:别让两处各拷一份扫描循环)。新增的是 agent 需要的 **`deadline`(单次后台 timeout):
//  到点即停、未扫的 scope 留待下次** —— 因为返回的只是「已扫完」的 scope,没轮到的保持旧 `lastScannedAt`,
//  下一轮 `leastRecentlyScanned` 自然把它们排到队首续上(用户:超时就下次继续,现有电源/渐进覆盖策略完美兼容)。
//
//  纯函数:只依赖入参 + `AIIndexerScan` / `AIArchivePrefetchScope`(同在 Core),不碰任何实例 / UI 状态 /
//  全局可变量,可被 SwiftPM 单测。**调度门控(电源 / 空闲 / 间隔)不在这里** —— 那是调用方(App 的
//  `AIBackgroundSchedulingRules` 闸 / agent 的 launchd 间隔 + 电源判断)的事,本函数只负责「这一轮扫哪些、扫多久」。
//

import Foundation

enum AIBackgroundIndexRun {

    /// 一个 scope 扫描完的产物:scope 标识 + 这一轮扫到的文件记录。调用方据此 `ingest` + `markScanned`。
    nonisolated struct ScopeResult: Sendable {
        let scopeID: UUID
        let records: [AIFileMemoryRecord]
    }

    /// 跑一轮预索引扫描(纯编排,off-main 由调用方安排)。
    ///
    /// - Parameters:
    ///   - scopes: **全部**白名单 scope(本函数内部按 `leastRecentlyScanned` 排序 + 取 `scopeBudget` 个,
    ///     调用方不必预排);从没扫过的最优先,其余按上次扫描时间升序 → 多轮把所有目录轮一遍。
    ///   - home: `NSHomeDirectory()`(目录分类 / 敏感目录判定用)。
    ///   - scopeBudget: 这一轮最多扫几个 scope(= 活跃度档的 `maxDirectoriesPerRound`,至少 1)。
    ///   - fileBudget: 单 scope 最多记多少文件(= `min(maxEntriesPerArchive, 3000)`)。
    ///   - allowContent: 是否在元数据之外补**内容摘要**(更高隐私等级,仅「预读内容」开关开时为 true)。
    ///   - existingSummarized: 上一轮已有摘要的记录(id → 记录),给渐进覆盖做「指纹没变就沿用旧摘要、不重读」。
    ///   - deadline: **单次后台 timeout 的截止时刻**(agent 传 `now + maxRunSeconds`;App 前台传 nil = 不限时)。
    ///     每扫一个 scope 前检查,到点即停 —— 没扫的 scope 不在返回里、`lastScannedAt` 不变 → 下轮排队首续上。
    ///   - isCancelled: 取消检查(App 传 `{ Task.isCancelled }`;agent 传退出信号检查)。每个 scope 前问一次。
    /// - Returns: **已扫完**的 scope 结果(顺序 = 实际扫描顺序);超时 / 取消时只含已完成的那些。
    nonisolated static func scan(scopes: [AIArchivePrefetchScope],
                                 home: String,
                                 scopeBudget: Int,
                                 fileBudget: Int,
                                 allowContent: Bool,
                                 existingSummarized: [String: AIFileMemoryRecord] = [:],
                                 deadline: Date? = nil,
                                 isCancelled: () -> Bool = { false }) -> [ScopeResult] {
        let picked = scopes
            .sorted(by: AIArchivePrefetchScope.leastRecentlyScanned)
            .prefix(max(1, scopeBudget))
        var results: [ScopeResult] = []
        for scope in picked {
            if isCancelled() { break }
            if let deadline, Date() >= deadline { break }   // 超时:剩下的留待下次(leastRecentlyScanned 续上)
            let records = AIIndexerScan.scanScope(scope, home: home, fileBudget: fileBudget,
                                                  allowContent: allowContent,
                                                  existingSummarized: existingSummarized)
            results.append(ScopeResult(scopeID: scope.id, records: records))
        }
        return results
    }
}
