//
//  AISystemWorkspaceFacts+App.swift
//  SimpleZip
//
//  0.4.5 #80:App 层类型 → 确定性 `AISystemWorkspaceFactsBuilder` 的纯值输入适配。
//  单一归属:AI 工作区视图(`AISuggestionFolderView`)与 DevTools「AI 可用数据」导出共用这两个映射,
//  不在某个 SwiftUI 视图里悬一份。只取低敏字段(分类 / 类型 / 来源 / 状态 / 时间 token、归档名与计数),
//  **不含路径内容、不含加密条目名**。
//

import Foundation

extension OperationTask {
    /// 活动中心任务 → 工作区 fact。
    var aiWorkspaceFact: AISystemWorkspaceTaskFact {
        let mappedStatus: AISystemWorkspaceTaskFact.Status
        switch status {
        case .running: mappedStatus = .running
        case .succeeded: mappedStatus = .succeeded
        case .skipped: mappedStatus = .skipped
        case .failed: mappedStatus = .failed
        case .cancelled: mappedStatus = .cancelled
        }
        return AISystemWorkspaceTaskFact(
            id: id.uuidString, category: category.rawValue, kind: kind.rawValue,
            source: source.rawValue, title: title, status: mappedStatus,
            startedAt: startedAt, finishedAt: finishedAt)
    }
}

extension ArchiveListingCacheEntry {
    /// 归档清单缓存条目 → 工作区 fact(只给计数,绝不带条目名 / 内容)。
    var aiWorkspaceFact: AISystemWorkspaceArchiveFact {
        AISystemWorkspaceArchiveFact(
            archivePath: archivePath, archiveName: archiveName, recordedAt: recordedAt,
            totalEntryCount: totalEntryCount, fileEntryCount: fileEntryCount,
            encryptedEntryCount: encryptedEntryCount, truncated: truncated)
    }
}
