//
//  AIPrefetch.swift
//  SimpleZip
//
//  0.4.5 #80:后台 AI 预读 / 预索引的**纯值模型 + 确定性安全规则**(白皮书工程补充五 / 六 / 七)。
//
//  后台预读只建立更强的本地索引(只读 list / inspect,绝不解压 / 写入 / 解密),必须白名单、预算化、可暂停、
//  可清空。这里只放:① 后台活跃度档位;② 各档预算;③ 白名单作用域值模型;④ **默认排除规则**(系统 / 密钥 /
//  缓存 / 开发依赖 / 临时解密目录 —— 安全红线,可单测);⑤ 预读清单状态。真正的调度、IO、节流在 App 层。
//
//  纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 后台本地 AI 活跃度档位(稳定英文 token)。
nonisolated enum AIBackgroundActivityLevel: String, Codable, Equatable, CaseIterable, Sendable {
    case off
    case powerSaver = "power-saver"
    case balanced
    case aggressive
}

/// 单轮预读预算(每轮目录 / 归档上限、单归档条目上限)。`off` 无预算。
nonisolated struct AIArchivePrefetchBudget: Codable, Equatable, Sendable {
    let maxDirectoriesPerRound: Int
    let maxArchivesPerRound: Int
    let maxEntriesPerArchive: Int

    /// 档位 → 预算(对齐工程补充六的预算表)。`off` 返回 nil(不跑预读)。
    static func forLevel(_ level: AIBackgroundActivityLevel) -> AIArchivePrefetchBudget? {
        switch level {
        case .off: return nil
        case .powerSaver: return AIArchivePrefetchBudget(maxDirectoriesPerRound: 1, maxArchivesPerRound: 10, maxEntriesPerArchive: 2_000)
        case .balanced: return AIArchivePrefetchBudget(maxDirectoriesPerRound: 3, maxArchivesPerRound: 40, maxEntriesPerArchive: 10_000)
        case .aggressive: return AIArchivePrefetchBudget(maxDirectoriesPerRound: 8, maxArchivesPerRound: 120, maxEntriesPerArchive: 20_000)
        }
    }
}

/// 一个后台预读白名单作用域。UI 文案要明确「只读建立索引」,不是「自动解压」。
nonisolated struct AIArchivePrefetchScope: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum Origin: String, Codable, Equatable, Sendable {
        case suggestedSafeDirectory = "suggested-safe-directory"
        case userAdded = "user-added"
        case pinnedPath = "pinned-path"
        case projectFolder = "project-folder"
    }

    let id: UUID
    let directoryPath: String
    let origin: Origin
    let recursive: Bool
    let maxDepth: Int
    let includeExternalVolumes: Bool
    let includeNetworkVolumes: Bool
    let createdAt: Date
    let lastScannedAt: Date?

    init(id: UUID, directoryPath: String, origin: Origin, recursive: Bool = false, maxDepth: Int = 1,
         includeExternalVolumes: Bool = false, includeNetworkVolumes: Bool = false,
         createdAt: Date, lastScannedAt: Date? = nil) {
        self.id = id
        self.directoryPath = directoryPath
        self.origin = origin
        self.recursive = recursive
        self.maxDepth = maxDepth
        self.includeExternalVolumes = includeExternalVolumes
        self.includeNetworkVolumes = includeNetworkVolumes
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
    }
}

/// 单个归档预读后的清单状态(稳定英文 token)。需要密码 / 头加密 / 损坏的归档不进条目索引,只记状态 + omission。
nonisolated enum AIArchivePrefetchListingStatus: String, Codable, Equatable, CaseIterable, Sendable {
    case indexed
    case needsPassword = "needs-password"
    case encryptedListingUnavailable = "encrypted-listing-unavailable"
    case corrupt
    case unsupported
    case failed
}

/// 默认排除规则:后台预读 / 预索引绝不进入的目录。安全红线 —— 系统 / 密钥 / 缓存 / 开发依赖 / 临时解密。
nonisolated enum AIPrefetchExclusions {
    /// 完整目录路径是否应排除(在排除前缀下,或任一路径分量命中排除名)。
    static func shouldExclude(directoryPath: String, home: String = NSHomeDirectory()) -> Bool {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let path = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        let homePath = URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL.path

        for prefix in absoluteExcludedPrefixes(home: homePath) {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        if path.contains("/SimpleZip-") { return true }  // 临时解密 / 暂存目录

        let components = path.split(separator: "/").map(String.init)
        return components.contains { shouldExclude(directoryName: $0) }
    }

    /// 单段目录名是否属于默认排除集(`.git` / `node_modules` / 缓存 / 密钥目录 …)。
    static func shouldExclude(directoryName: String) -> Bool {
        excludedNames.contains(directoryName) || excludedNames.contains(directoryName.lowercased())
    }

    private static func absoluteExcludedPrefixes(home: String) -> [String] {
        [
            "/System", "/Library", "/private/var/folders", "/var/folders", "/private/tmp", "/tmp",
            home + "/Library"
        ]
    }

    /// 任意层级命中即排除的目录名(开发依赖 / VCS / 密钥 / 缓存)。
    static let excludedNames: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".build", "deriveddata", "target", "dist", "build",
        "caches", "containers",
        ".ssh", ".gnupg", ".aws", ".kube", ".config"
    ]
}
