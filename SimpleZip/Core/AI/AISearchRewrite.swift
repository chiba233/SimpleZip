//
//  AISearchRewrite.swift
//  SimpleZip
//
//  0.4.5 #80:AI 搜索重写(白皮书 Feat 8 / 建议九)。把用户模糊的一句话(「那个带签名的包」)重写成
//  本地索引能执行的结构化 query —— 关键词 / 语义标签 / marker / 扩展 / 任务标签 / 搜索面。
//
//  分工:**模型只做 query rewrite(产出这个结构),不做检索**;App 用 `toQueryPlan()` 把重写映射成确定性
//  `AIWorkspaceQueryPlan`,再交给现成执行器在已索引归档 / 任务里召回真实对象。弱模型压力极小、结果稳定。
//  纯值 + 确定性映射,SwiftPM 可断言。
//

import Foundation

/// 一次搜索覆盖的「面」。稳定英文 token。
nonisolated enum AISearchSurface: String, Codable, Equatable, CaseIterable, Sendable {
    case archives
    case archiveEntries
    case tasks
    case reports
    case settings
    case folders
}

/// 模型把模糊查询重写成的结构化 query。所有字段都是 App 本地索引能执行的低敏信号。
nonisolated struct AISearchRewrite: Codable, Equatable, Sendable {
    var keywords: [String]
    var semanticTags: [String]
    var markerFiles: [String]
    var extensions: [String]
    var taskTags: [String]
    var locationKinds: [String]
    var surfaces: [AISearchSurface]

    init(keywords: [String] = [], semanticTags: [String] = [], markerFiles: [String] = [],
         extensions: [String] = [], taskTags: [String] = [], locationKinds: [String] = [],
         surfaces: [AISearchSurface] = []) {
        self.keywords = keywords
        self.semanticTags = semanticTags
        self.markerFiles = markerFiles
        self.extensions = extensions
        self.taskTags = taskTags
        self.locationKinds = locationKinds
        self.surfaces = surfaces
    }

    /// 没有任何可执行信号 —— 调用点据此显示「没看懂这次搜索」而非空转。
    var isEmpty: Bool {
        keywords.isEmpty && semanticTags.isEmpty && markerFiles.isEmpty
            && extensions.isEmpty && taskTags.isEmpty && locationKinds.isEmpty
    }

    /// 映射成确定性查询计划:扩展名并进关键词(归档名 / 样本路径子串可命中如 `.szs`),
    /// include 标志由 surfaces 推出。交给 `AIWorkspaceQueryExecutor` 召回。
    func toQueryPlan() -> AIWorkspaceQueryPlan {
        let surfaceSet = Set(surfaces)
        let mergedKeywords = keywords + extensions.map { $0.hasPrefix(".") ? $0 : "." + $0 }
        return AIWorkspaceQueryPlan(
            semanticTags: semanticTags,
            taskTags: taskTags,
            markerFiles: markerFiles,
            keywords: mergedKeywords,
            locationKinds: locationKinds,
            includeArchives: surfaceSet.contains(.archives) || surfaceSet.isEmpty,
            includeArchiveEntries: surfaceSet.contains(.archiveEntries),
            includeTasks: surfaceSet.contains(.tasks) || surfaceSet.isEmpty,
            includeReports: surfaceSet.contains(.reports),
            includeActions: false
        )
    }
}
