//
//  AIIndexMaintenance.swift
//  SimpleZip
//
//  0.4.5 #80:AI 缓存 / 索引维护员(白皮书 Feat 21)。后台 AI、Spotlight、归档缓存、文件夹预索引都变强后,
//  用户需要知道「现在索引健康吗」。从现有索引统计**确定性**判定该做什么维护(清过期 / 重建 Spotlight /
//  从没跑过预索引),模型只把结论变成人话摘要。
//
//  时间用注入的 `lastBackgroundRunSecondsAgo`(避免 Core 读 Date,保持可复现)。建议动作都是受控 token,
//  执行仍走现有设置 / 索引入口。纯函数,SwiftPM 可断言。
//

import Foundation

/// 索引统计快照(都是低敏计数 / 布尔 / 注入的相对时间)。
nonisolated struct AIIndexMaintenanceFacts: Codable, Equatable, Sendable {
    let archiveListingCacheEnabled: Bool
    let spotlightIndexingEnabled: Bool
    let archiveCacheCount: Int
    let staleArchiveCacheCount: Int
    let spotlightArchiveCount: Int
    let folderProfileCount: Int
    /// 距上次后台预索引运行的秒数;nil = 从未运行。
    let lastBackgroundRunSecondsAgo: Int?

    init(archiveListingCacheEnabled: Bool = true, spotlightIndexingEnabled: Bool = true,
         archiveCacheCount: Int = 0, staleArchiveCacheCount: Int = 0, spotlightArchiveCount: Int = 0,
         folderProfileCount: Int = 0, lastBackgroundRunSecondsAgo: Int? = nil) {
        self.archiveListingCacheEnabled = archiveListingCacheEnabled
        self.spotlightIndexingEnabled = spotlightIndexingEnabled
        self.archiveCacheCount = archiveCacheCount
        self.staleArchiveCacheCount = staleArchiveCacheCount
        self.spotlightArchiveCount = spotlightArchiveCount
        self.folderProfileCount = folderProfileCount
        self.lastBackgroundRunSecondsAgo = lastBackgroundRunSecondsAgo
    }
}

/// 受控维护动作(稳定英文 token,执行走现有入口)。
nonisolated enum AIIndexMaintenanceAction: String, Codable, Equatable, CaseIterable, Sendable {
    case pruneStaleCache = "prune-stale-cache"
    case reindexSpotlight = "reindex-spotlight"
    case openAIDataSettings = "open-ai-data-settings"
    case runBackgroundIndex = "run-background-index"
}

nonisolated struct AIIndexMaintenanceFinding: Codable, Equatable, Sendable {
    /// 稳定问题码:stale-cache / spotlight-drift / never-ran。
    let code: String
    let action: AIIndexMaintenanceAction
    let evidence: [String]
}

nonisolated enum AIIndexMaintenanceAnalyzer {
    /// 确定性维护判定(固定顺序)。`staleThreshold`/`driftThreshold` 控制噪声;都健康返回空。
    static func analyze(_ facts: AIIndexMaintenanceFacts,
                        staleThreshold: Int = 1, driftThreshold: Int = 5,
                        neverRanGraceSeconds: Int = 86_400) -> [AIIndexMaintenanceFinding] {
        var findings: [AIIndexMaintenanceFinding] = []

        // 过期缓存项 → 建议清理。
        if facts.staleArchiveCacheCount >= staleThreshold {
            findings.append(AIIndexMaintenanceFinding(
                code: "stale-cache", action: .pruneStaleCache,
                evidence: ["staleArchiveCacheCount=\(facts.staleArchiveCacheCount)"]))
        }

        // Spotlight 漂移:开了索引,但缓存里的归档明显多于已索引的 → 建议重建。
        if facts.spotlightIndexingEnabled {
            let drift = facts.archiveCacheCount - facts.spotlightArchiveCount
            if drift >= driftThreshold {
                findings.append(AIIndexMaintenanceFinding(
                    code: "spotlight-drift", action: .reindexSpotlight,
                    evidence: ["archiveCacheCount=\(facts.archiveCacheCount)",
                               "spotlightArchiveCount=\(facts.spotlightArchiveCount)"]))
            }
        }

        // 从没跑过后台预索引,但缓存已开 → 提示首次运行(只在缓存开启时,尊重用户关闭意愿)。
        if facts.archiveListingCacheEnabled, facts.lastBackgroundRunSecondsAgo == nil {
            findings.append(AIIndexMaintenanceFinding(
                code: "never-ran", action: .runBackgroundIndex,
                evidence: ["lastBackgroundRun=never"]))
        }

        return findings
    }
}
