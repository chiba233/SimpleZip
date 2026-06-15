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

// MARK: - 低负载静默调度(工程补充五)

/// 后台调度时的运行时上下文(纯标量;App 填充,经过的秒数由 App 算 —— Core 不读墙钟)。
nonisolated struct AIBackgroundRuntimeContext: Codable, Equatable, Sendable {
    let appIsActive: Bool
    let runningTaskCount: Int
    let heavyArchiveTaskRunning: Bool
    /// App 启动至今秒数。
    let secondsSinceLaunch: Int
    /// 距用户上次交互的秒数。
    let secondsSinceLastInteraction: Int
    let powerSaverMode: Bool
    let lowBattery: Bool
    let isCharging: Bool?
    let modelAvailable: Bool
    let activityLevel: AIBackgroundActivityLevel

    init(appIsActive: Bool, runningTaskCount: Int = 0, heavyArchiveTaskRunning: Bool = false,
         secondsSinceLaunch: Int, secondsSinceLastInteraction: Int,
         powerSaverMode: Bool = false, lowBattery: Bool = false, isCharging: Bool? = nil,
         modelAvailable: Bool, activityLevel: AIBackgroundActivityLevel) {
        self.appIsActive = appIsActive
        self.runningTaskCount = runningTaskCount
        self.heavyArchiveTaskRunning = heavyArchiveTaskRunning
        self.secondsSinceLaunch = secondsSinceLaunch
        self.secondsSinceLastInteraction = secondsSinceLastInteraction
        self.powerSaverMode = powerSaverMode
        self.lowBattery = lowBattery
        self.isCharging = isCharging
        self.modelAvailable = modelAvailable
        self.activityLevel = activityLevel
    }
}

/// 当前允许的后台工作档位(由轻到重,有序)。深档位蕴含浅档位都可跑。
nonisolated enum AIBackgroundWorkTier: String, Codable, CaseIterable, Comparable, Sendable {
    case none
    case deterministicIndex = "deterministic-index"   // 只读建立索引(最轻,低电也可)
    case modelPrewarm = "model-prewarm"               // 跑端上模型轻任务(当前目录 Lens / 失败动作卡)
    case deepContext = "deep-context"                 // 深度本地上下文(最重,需充电 + 空闲)

    private var order: Int {
        switch self {
        case .none: return 0
        case .deterministicIndex: return 1
        case .modelPrewarm: return 2
        case .deepContext: return 3
        }
    }

    static func < (lhs: AIBackgroundWorkTier, rhs: AIBackgroundWorkTier) -> Bool { lhs.order < rhs.order }
}

/// 后台静默调度的**确定性条件**(工程补充五)。真正的 actor 调度 / IO 在 App 层;这里只判定「现在能跑到哪档」。
nonisolated enum AIBackgroundSchedulingRules {
    /// App 启动后多少秒内不跑后台 AI。
    static let minSecondsSinceLaunch = 60
    /// 用户无输入多少秒后才跑轻任务。
    static let minIdleSecondsForLightWork = 20

    /// 确定性索引可跑:过了启动静默期、无重任务、活跃度非关闭。低电 / 省电也可(只读索引不耗模型)。
    static func canRunDeterministicIndexing(_ c: AIBackgroundRuntimeContext) -> Bool {
        c.secondsSinceLaunch >= minSecondsSinceLaunch
            && !c.heavyArchiveTaskRunning
            && c.activityLevel != .off
    }

    /// 端上模型轻任务可跑:在确定性索引基础上,模型可用、用户已空闲、且非低电 / 非省电(低电只跑确定性索引)。
    static func canRunModelWork(_ c: AIBackgroundRuntimeContext) -> Bool {
        canRunDeterministicIndexing(c)
            && c.modelAvailable
            && c.secondsSinceLastInteraction >= minIdleSecondsForLightWork
            && !c.lowBattery
            && !c.powerSaverMode
    }

    /// 深度本地上下文可跑:在模型轻任务基础上,充电中且活跃度为平衡 / 积极。
    static func canRunDeepContext(_ c: AIBackgroundRuntimeContext) -> Bool {
        canRunModelWork(c)
            && (c.isCharging ?? false)
            && (c.activityLevel == .balanced || c.activityLevel == .aggressive)
    }

    /// 当前可跑的**最深**后台工作档位(深档蕴含浅档)。`.none` = 现在什么都不该跑。
    static func deepestAllowedTier(_ c: AIBackgroundRuntimeContext) -> AIBackgroundWorkTier {
        guard canRunDeterministicIndexing(c) else { return .none }
        guard canRunModelWork(c) else { return .deterministicIndex }
        guard canRunDeepContext(c) else { return .modelPrewarm }
        return .deepContext
    }
}
