//
//  AIWorkspaceQueryPlan.swift
//  SimpleZip
//
//  0.4.5 #80:AI 工作区 / Lens / 智能文件夹 / 搜索重写的**共用基石**(白皮书 Feat 2 / 6 / 8)。
//
//  关键设计:**模型只把一句话 prompt 转成 query plan,App 确定性执行 plan 召回真实候选**。工作区不是每次
//  让模型重想一棵树,而是保存一个稳定的 plan;模型只在创建 / 刷新时把 prompt → plan,后续召回全确定性。
//  这让弱模型压力极小、结果稳定,且所有召回的对象都是 App 已索引的真实 source ref(模型不发明)。
//
//  纯值类型 + 确定性执行器,SwiftPM 可断言。
//

import Foundation

nonisolated struct AIWorkspaceQueryPlan: Codable, Equatable, Sendable {
    /// 匹配归档的语义标签(ArchiveProfile.semanticTags / 角色)。
    var semanticTags: [String]
    /// 匹配任务的诊断标签(AIDiagnosticTag rawValue)。
    var taskTags: [String]
    /// 匹配归档的 marker 文件名。
    var markerFiles: [String]
    /// 自由关键词(归档名 / 条目样本 / 任务名 / 产物名 子串)。
    var keywords: [String]
    /// 位置类别偏好 / 过滤(AILocationKind rawValue)。
    var locationKinds: [String]
    var includeArchives: Bool
    var includeArchiveEntries: Bool
    var includeTasks: Bool
    var includeReports: Bool
    var includeActions: Bool

    init(
        semanticTags: [String] = [],
        taskTags: [String] = [],
        markerFiles: [String] = [],
        keywords: [String] = [],
        locationKinds: [String] = [],
        includeArchives: Bool = true,
        includeArchiveEntries: Bool = false,
        includeTasks: Bool = true,
        includeReports: Bool = false,
        includeActions: Bool = false
    ) {
        self.semanticTags = semanticTags
        self.taskTags = taskTags
        self.markerFiles = markerFiles
        self.keywords = keywords
        self.locationKinds = locationKinds
        self.includeArchives = includeArchives
        self.includeArchiveEntries = includeArchiveEntries
        self.includeTasks = includeTasks
        self.includeReports = includeReports
        self.includeActions = includeActions
    }

    /// plan 是否什么都不匹配(全空)—— 调用点据此显示「为什么没有推荐」而非空转。
    /// 显式 `includeReports` / `includeActions`(默认 false)也算「有意图」:勾选了「含报告 / 含动作」即便没有
    /// 标签 / 关键词,也不是空 plan —— 否则 App 侧的报告 / 动作召回会被这层提前掐掉(BUG-W12)。
    var isEmpty: Bool {
        semanticTags.isEmpty && taskTags.isEmpty && markerFiles.isEmpty
            && keywords.isEmpty && locationKinds.isEmpty
            && !includeReports && !includeActions
    }
}

/// 确定性执行器:用 plan 在已索引的归档记忆 / 任务记录里召回匹配项,按命中信号数排序。
/// 报告 / 动作召回在 App 侧(它们的 store 在 app 层);这里覆盖纯 Core 的归档 + 任务两类。
nonisolated enum AIWorkspaceQueryExecutor {
    /// 召回匹配的归档记忆(命中信号越多越靠前,同分按记录时间新→旧)。
    static func matchArchives(_ plan: AIWorkspaceQueryPlan,
                              in records: [ArchiveMemoryRecord]) -> [ArchiveMemoryRecord] {
        guard plan.includeArchives, !plan.isEmpty else { return [] }
        let wantTags = Set(plan.semanticTags)
        let wantMarkers = Set(plan.markerFiles.map { $0.lowercased() })
        let wantLocations = Set(plan.locationKinds)
        let keywords = plan.keywords.map { $0.lowercased() }.filter { !$0.isEmpty }

        func score(_ record: ArchiveMemoryRecord) -> Int {
            var matched = 0
            if !wantTags.isDisjoint(with: Set(record.profile.semanticTags)) { matched += 1 }
            if !wantMarkers.isDisjoint(with: Set(record.profile.markerFiles.map { $0.lowercased() })) { matched += 1 }
            if wantLocations.contains(record.location.kind.rawValue) { matched += 1 }
            if !keywords.isEmpty {
                let hay = (record.archiveName + " " + record.samplePaths.joined(separator: " ")).lowercased()
                if keywords.contains(where: hay.contains) { matched += 1 }
            }
            return matched
        }

        return records.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.recordedAt > $1.0.recordedAt }
            .map { $0.0 }
    }

    /// 召回匹配的任务记录(命中信号越多越靠前,同分按 id 稳定排序)。
    static func matchTasks(_ plan: AIWorkspaceQueryPlan,
                           in records: [AITaskRecord]) -> [AITaskRecord] {
        guard plan.includeTasks, !plan.isEmpty else { return [] }
        let wantTags = Set(plan.taskTags)
        let wantLocations = Set(plan.locationKinds)
        let keywords = plan.keywords.map { $0.lowercased() }.filter { !$0.isEmpty }

        func score(_ record: AITaskRecord) -> Int {
            var matched = 0
            if !wantTags.isDisjoint(with: Set(record.diagnostics.tags)) { matched += 1 }
            if !wantLocations.isDisjoint(with: Set(record.files.locationKinds)) { matched += 1 }
            if !keywords.isEmpty {
                let hay = (record.title + " " + (record.files.archiveName ?? "")).lowercased()
                if keywords.contains(where: hay.contains) { matched += 1 }
            }
            return matched
        }

        return records.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .map { $0.0 }
    }
}
