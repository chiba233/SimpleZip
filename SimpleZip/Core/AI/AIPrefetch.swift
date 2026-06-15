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

// MARK: - 后台计划(工程补充五:aggressive = 本地智能维护员)

/// 后台调度的**输入**(工程补充五)。把「现在能跑到哪档 + 用户最近在哪些 surface 关注什么 + 工作区缺哪些证据 +
/// 哪些工作区/建议过期 + 索引健康 + 可预读范围」一次性喂给规划器。纯数据,App 收集后传入。
nonisolated struct AIBackgroundPlanningInput: Codable, Equatable, Sendable {
    let runtime: AIBackgroundRuntimeContext
    let interactionSummary: AIInteractionCounterSummary
    let recentInterestSummary: AIInterestSummary
    let workspaceEvidenceGaps: [AIWorkspaceEvidenceGap]
    let staleWorkspaceIDs: [UUID]
    let staleSuggestionSurfaces: [AISuggestionSurfaceID]
    /// 索引健康(白皮书写 `AIIndexMaintenanceSnapshot`,Core 里既有类型是 `AIIndexMaintenanceFacts`)。
    let indexHealth: AIIndexMaintenanceFacts
    let prefetchScopes: [AIArchivePrefetchScope]

    init(runtime: AIBackgroundRuntimeContext, interactionSummary: AIInteractionCounterSummary,
         recentInterestSummary: AIInterestSummary, workspaceEvidenceGaps: [AIWorkspaceEvidenceGap] = [],
         staleWorkspaceIDs: [UUID] = [], staleSuggestionSurfaces: [AISuggestionSurfaceID] = [],
         indexHealth: AIIndexMaintenanceFacts, prefetchScopes: [AIArchivePrefetchScope] = []) {
        self.runtime = runtime
        self.interactionSummary = interactionSummary
        self.recentInterestSummary = recentInterestSummary
        self.workspaceEvidenceGaps = workspaceEvidenceGaps
        self.staleWorkspaceIDs = staleWorkspaceIDs
        self.staleSuggestionSurfaces = staleSuggestionSurfaces
        self.indexHealth = indexHealth
        self.prefetchScopes = prefetchScopes
    }
}

/// 后台调度的**输出**(工程补充五):一组可取消、可解释的后台 job。不是「马上跑模型」,而是「该补什么数据 /
/// 该预热哪个 surface」。每个 job 带 requiredTier —— 由规划器按当前档位天花板过滤,绝不越界。
nonisolated struct AIBackgroundPlan: Codable, Equatable, Sendable {
    nonisolated enum JobKind: String, Codable, CaseIterable, Sendable {
        case refreshInteractionSummary
        case preindexFolderFacts
        case prefetchArchiveListing
        case calculateCheapHashes
        case testSmallArchives
        case refreshDefaultOpenApps
        case deriveArchiveProfiles
        case generateWorkspaceThemes
        case refreshVirtualTrees
        case prewarmMainWindowSuggestions
        case prewarmActivityWorkbench
        case prewarmSettingsDoctor
        case precomputeOperationAutoTune
        case refreshStartupSuggestions

        /// 该 job 至少需要的工作档位。纯确定性维护(索引/哈希/测试/清单/facts/autoTune/startup)= 索引档;
        /// 依赖端上模型的(主题/虚拟树/各 surface 预热/画像 AI 标签)= 模型档。v1 不产深度档 job(最保守)。
        var requiredTier: AIBackgroundWorkTier {
            switch self {
            case .refreshInteractionSummary, .preindexFolderFacts, .prefetchArchiveListing,
                 .calculateCheapHashes, .testSmallArchives, .refreshDefaultOpenApps,
                 .precomputeOperationAutoTune, .refreshStartupSuggestions:
                return .deterministicIndex
            case .deriveArchiveProfiles, .generateWorkspaceThemes, .refreshVirtualTrees,
                 .prewarmMainWindowSuggestions, .prewarmActivityWorkbench, .prewarmSettingsDoctor:
                return .modelPrewarm
            }
        }

        /// 预算桶 key —— App 按桶限流(同桶 job 共享预算)。
        var budgetKey: String {
            switch self {
            case .calculateCheapHashes: return "hash"
            case .testSmallArchives: return "test"
            case .prefetchArchiveListing: return "listing"
            case .preindexFolderFacts, .refreshDefaultOpenApps: return "facts"
            case .deriveArchiveProfiles: return "profile"
            case .generateWorkspaceThemes, .refreshVirtualTrees: return "workspace"
            case .prewarmMainWindowSuggestions, .prewarmActivityWorkbench, .prewarmSettingsDoctor:
                return "prewarm"
            case .refreshInteractionSummary, .precomputeOperationAutoTune, .refreshStartupSuggestions:
                return "maintenance"
            }
        }
    }

    nonisolated struct Job: Codable, Equatable, Sendable {
        let kind: JobKind
        let priority: Int
        let reasonTokens: [String]
        let sourceRefs: [AIContextSourceRef]
        let requiredTier: AIBackgroundWorkTier
        let budgetKey: String

        init(kind: JobKind, priority: Int, reasonTokens: [String] = [],
             sourceRefs: [AIContextSourceRef] = []) {
            self.kind = kind
            self.priority = priority
            self.reasonTokens = reasonTokens
            self.sourceRefs = sourceRefs
            self.requiredTier = kind.requiredTier
            self.budgetKey = kind.budgetKey
        }
    }

    let allowedTier: AIBackgroundWorkTier
    let jobs: [Job]

    var isEmpty: Bool { jobs.isEmpty }
}

/// 确定性后台规划器(工程补充五)。把规划输入折叠成一组 tier-gated job:证据缺口 → 补证据动作;陈旧工作区 →
/// 重生成主题 / 虚拟树;陈旧建议 surface → 预热;用户常关注失败诊断 → 提高哈希 / 测试 job 优先级。
/// **绝不越档**:超过当前天花板的 job 一律剔除;天花板为 `.none` 时产空计划。
nonisolated enum AIBackgroundPlanner {
    /// 用户对失败诊断的关注达到此阈值时,提高相关补证据 job 优先级。
    static let failureEngagementBoostThreshold = 3

    static func plan(_ input: AIBackgroundPlanningInput) -> AIBackgroundPlan {
        let ceiling = AIBackgroundSchedulingRules.deepestAllowedTier(input.runtime)
        guard ceiling > .none else { return AIBackgroundPlan(allowedTier: ceiling, jobs: []) }

        var jobs: [AIBackgroundPlan.Job] = []
        let failureBoost = input.interactionSummary.counters
            .contains { $0.diagnosticTag != nil && $0.count >= failureEngagementBoostThreshold } ? 5 : 0

        // 1) 证据缺口 → 对应补证据 job(带缺口的 sourceRefs)。
        for gap in input.workspaceEvidenceGaps {
            let base: Int
            switch gap.urgency {
            case .high: base = 30
            case .normal: base = 20
            case .low: base = 10
            }
            let (kind, boostable): (AIBackgroundPlan.JobKind, Bool)
            switch gap.kind {
            case .missingHash: (kind, boostable) = (.calculateCheapHashes, true)
            case .missingArchiveListing: (kind, boostable) = (.prefetchArchiveListing, false)
            case .missingArchiveHealth: (kind, boostable) = (.testSmallArchives, true)
            case .missingDefaultOpenApp: (kind, boostable) = (.refreshDefaultOpenApps, false)
            case .missingPermissionFacts: (kind, boostable) = (.preindexFolderFacts, false)
            case .missingRecentOpenSignal: (kind, boostable) = (.refreshInteractionSummary, false)
            }
            jobs.append(.init(kind: kind, priority: base + (boostable ? failureBoost : 0),
                              reasonTokens: ["evidence-gap", gap.kind.rawValue, "urgency=\(gap.urgency.rawValue)"],
                              sourceRefs: gap.affectedSourceRefs))
        }

        // 2) 陈旧工作区 → 重生成主题 + 虚拟树(模型档)。
        if !input.staleWorkspaceIDs.isEmpty {
            jobs.append(.init(kind: .generateWorkspaceThemes, priority: 14,
                              reasonTokens: ["stale-workspaces", "count=\(input.staleWorkspaceIDs.count)"]))
            jobs.append(.init(kind: .refreshVirtualTrees, priority: 12,
                              reasonTokens: ["stale-workspaces", "count=\(input.staleWorkspaceIDs.count)"]))
        }

        // 3) 陈旧建议 surface → 预热对应 surface。
        for surface in input.staleSuggestionSurfaces {
            guard let kind = prewarmKind(for: surface) else { continue }
            jobs.append(.init(kind: kind, priority: 15, reasonTokens: ["stale-surface", surface.rawValue]))
        }

        // 4) 有交互信号 → 折叠 interaction summary(最便宜的维护)+ 预计算 auto-tune / 启动建议。
        if !input.interactionSummary.isEmpty {
            jobs.append(.init(kind: .refreshInteractionSummary, priority: 8, reasonTokens: ["interaction-signals"]))
            jobs.append(.init(kind: .precomputeOperationAutoTune, priority: 7 + failureBoost,
                              reasonTokens: ["interaction-signals"]))
        }
        if !input.recentInterestSummary.locationAffinities.isEmpty {
            jobs.append(.init(kind: .refreshStartupSuggestions, priority: 6,
                              reasonTokens: ["location-affinity"]))
        }

        // 天花板过滤 + 确定性排序(优先级降序,再按 kind 名 + budgetKey 升序)。
        let allowed = jobs
            .filter { $0.requiredTier <= ceiling }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
                return a.budgetKey < b.budgetKey
            }
        return AIBackgroundPlan(allowedTier: ceiling, jobs: allowed)
    }

    private static func prewarmKind(for surface: AISuggestionSurfaceID) -> AIBackgroundPlan.JobKind? {
        switch surface {
        case .mainWindowSuggestion, .mainToolbar, .folderSelection, .archiveSelection:
            return .prewarmMainWindowSuggestions
        case .activityCenter, .activityTaskRow:
            return .prewarmActivityWorkbench
        case .settingsPane:
            return .prewarmSettingsDoctor
        default:
            return nil
        }
    }
}
