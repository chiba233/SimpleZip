//
//  AppPreferences.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import Security

/// App 内语言选择。system 表示跟随 macOS，其它值对应本地化目录名。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case french
    case german
    case korean
    case russian
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case thai

    var id: String { rawValue }

    nonisolated var localizationCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .korean:
            return "ko"
        case .russian:
            return "ru"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .japanese:
            return "ja"
        case .thai:
            return "th"
        }
    }

    nonisolated var appleLanguageCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .korean:
            return "ko"
        case .russian:
            return "ru"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .japanese:
            return "ja"
        case .thai:
            return "th"
        }
    }

    var title: String {
        switch self {
        case .system:
            return L10n.text("settings.language.system")
        case .english:
            return L10n.text("settings.language.en")
        case .spanish:
            return L10n.text("settings.language.es")
        case .french:
            return L10n.text("settings.language.fr")
        case .german:
            return L10n.text("settings.language.de")
        case .korean:
            return L10n.text("settings.language.ko")
        case .russian:
            return L10n.text("settings.language.ru")
        case .simplifiedChinese:
            return L10n.text("settings.language.zhHans")
        case .traditionalChinese:
            return L10n.text("settings.language.zhHant")
        case .japanese:
            return L10n.text("settings.language.ja")
        case .thai:
            return L10n.text("settings.language.th")
        }
    }
}

/// 启动时默认打开的位置。
///
/// `documents` / `movies` / `music` / `pictures` 都是 macOS 自动建好的用户常用目录，
/// 默认列出来比让用户每次选 Custom 再翻文件夹更顺手。
/// `custom` 表示用户在设置里挑了一个任意路径，实际路径放在 `Key.startupCustomLocationPath`。
enum StartupLocation: String, CaseIterable, Identifiable {
    case home
    case downloads
    case desktop
    case documents
    case movies
    case music
    case pictures
    case lastFolder
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return L10n.text("settings.startup.home")
        case .downloads:
            return L10n.text("settings.startup.downloads")
        case .desktop:
            return L10n.text("settings.startup.desktop")
        case .documents:
            return L10n.text("settings.startup.documents")
        case .movies:
            return L10n.text("settings.startup.movies")
        case .music:
            return L10n.text("settings.startup.music")
        case .pictures:
            return L10n.text("settings.startup.pictures")
        case .lastFolder:
            return L10n.text("settings.startup.lastFolder")
        case .custom:
            return L10n.text("settings.startup.custom")
        }
    }
}

/// 解压遇到同名文件时的默认处理方式。
enum OverwriteBehavior: String, CaseIterable, Identifiable {
    case ask
    case overwrite
    case skipExisting
    case replaceIfDifferent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:
            return L10n.text("settings.overwrite.ask")
        case .overwrite:
            return L10n.text("settings.overwrite.overwrite")
        case .skipExisting:
            return L10n.text("settings.overwrite.skipExisting")
        case .replaceIfDifferent:
            return L10n.text("conflict.replaceIfDifferent")
        }
    }
}

enum ArchiveSecurityDecision: String, CaseIterable, Identifiable {
    case ask
    case allow
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:
            return L10n.text("settings.security.ask")
        case .allow:
            return L10n.text("settings.security.allow")
        case .deny:
            return L10n.text("settings.security.deny")
        }
    }
}

/// 7-Zip 命令行后端来源。
/// 用户在「压缩」设置里选的 7-Zip 来源 —— 是「选择」不是「后端实现」。
/// 真正的 backend 实现在 `SevenZipBackend` (Core/Backends)。
enum SevenZipBackendChoice: String, CaseIterable, Identifiable {
    case automatic
    case bundled
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("settings.7zip.automatic")
        case .bundled:
            return L10n.text("settings.7zip.bundled")
        case .system:
            return L10n.text("settings.7zip.system")
        }
    }
}

/// 用户在「压缩」设置里选的 RAR 来源 —— 是「选择」不是「后端实现」。
/// 真正的 backend 实现将来在 `RarBackend` (Core/Backends，Phase 4 step 3c)。
enum RarBackendChoice: String, CaseIterable, Identifiable {
    case automatic
    case bundled
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("settings.rar.automatic")
        case .bundled:
            return L10n.text("settings.rar.bundled")
        case .system:
            return L10n.text("settings.rar.system")
        }
    }
}

/// UserDefaults 读写封装，集中管理偏好键，避免字符串散落在业务代码里。
enum AppPreferences {
    private nonisolated static var defaults: UserDefaults { UserDefaults.standard }

    enum Key {
        nonisolated static let startupLocation = "startupLocation"
        /// 当 `startupLocation == .custom` 时启动应该打开的具体文件夹路径。
        /// 与 `lastFolderPath` 不同 —— 这个是用户在设置里固定挑的位置，不会被「记住上次打开的文件夹」覆盖。
        /// 同时是 custom 历史列表里的「当前选中」指针。
        nonisolated static let startupCustomLocationPath = "startupCustomLocationPath"
        /// 用户挑过的所有 custom 路径（MRU 排序），让 Menu 有「记忆」功能。
        /// 容量受 Menu 总项数 cap 10 约束 —— 加新的会从末尾驱逐。
        nonisolated static let startupCustomLocationHistory = "startupCustomLocationHistory"
        nonisolated static let overwriteBehavior = "overwriteBehavior"
        nonisolated static let suspiciousPathPolicy = "suspiciousPathPolicy"
        nonisolated static let symbolicLinkPolicy = "symbolicLinkPolicy"
        nonisolated static let activeContentOpenPolicy = "activeContentOpenPolicy"
        nonisolated static let confirmBeforeDeletingFiles = "confirmBeforeDeletingFiles"
        nonisolated static let showHiddenFiles = "showHiddenFiles"
        nonisolated static let hiddenDetectionMode = "hiddenDetectionMode"
        nonisolated static let showSymbolicLinks = "showSymbolicLinks"
        /// 是否同步 Finder 侧栏「个人收藏」。默认关；开启后需要用户授权 Finder shared file list 目录。
        nonisolated static let finderFavoritesSyncEnabled = "finderFavoritesSyncEnabled"
        /// Finder shared file list 目录的 security-scoped bookmark。包含本机路径与授权信息，不导出备份。
        nonisolated static let finderFavoritesDirectoryBookmarkData = "finderFavoritesDirectoryBookmarkData"
        nonisolated static let folderInlineExpansion = "folderInlineExpansion"
        // 0.4.2：展开状态记忆开关（文件夹 / 分卷集，会话内跨刷新记忆；默认开）。
        nonisolated static let rememberFolderExpansion = "rememberFolderExpansion"
        nonisolated static let rememberVolumeSetExpansion = "rememberVolumeSetExpansion"
        nonisolated static let followFinderStructure = "followFinderApplicationStructure"
        nonisolated static let hiddenSuffixesEnabled = "hiddenSuffixesEnabled"
        nonisolated static let hiddenRecommendedSuffixes = "hiddenRecommendedSuffixes"
        nonisolated static let hiddenCustomSuffixes = "hiddenCustomSuffixes"
        // 0.2.0 隐藏文件折叠分组：折叠记忆策略（可导出的偏好）+ 两类展开状态（本机 UI 状态，不导出）。
        nonisolated static let hiddenGroupCollapseMode = "hiddenGroupCollapseMode"
        nonisolated static let hiddenGroupPerFolderExpanded = "hiddenGroupPerFolderExpanded"
        nonisolated static let hiddenGroupGlobalExpanded = "hiddenGroupGlobalExpanded"
        // 0.2.0 Group By 多重分类：文件 / 压缩包浏览各自的分类维度 + 隐藏文件与分类组的共存策略。
        nonisolated static let fileGroupBy = "fileGroupBy"
        nonisolated static let archiveGroupBy = "archiveGroupBy"
        nonisolated static let hiddenWithGrouping = "hiddenWithGrouping"
        nonisolated static let fileGroupingScope = "fileGroupingScope"
        // 每文件夹分组覆盖（path\tgroupBy 的 MRU 数组）。本机 UI 状态、含真实路径，默认不导出。
        nonisolated static let fileFolderGrouping = "fileFolderGrouping"
        // 导出备份时是否包含「按文件夹记忆」（per-folder 分组覆盖 + 隐藏组展开记忆）。默认关。
        nonisolated static let includePerFolderMemoryInBackup = "includePerFolderMemoryInBackup"
        // 0.2.0 列表显示密度（文件 / 压缩包浏览共用一档）。
        nonisolated static let rowDensity = "rowDensity"
        nonisolated static let rememberLastFolder = "rememberLastFolder"
        nonisolated static let lastFolderPath = "lastFolderPath"
        nonisolated static let checkForUpdatesOnLaunch = "checkForUpdatesOnLaunch"
        nonisolated static let betaUpdatesEnabled = "betaUpdatesEnabled"
        nonisolated static let showFileSizeColumn = "showFileSizeColumn"
        nonisolated static let showFileTypeColumn = "showFileTypeColumn"
        nonisolated static let showFileApplicationColumn = "showFileApplicationColumn"
        nonisolated static let showFileLastOpenedColumn = "showFileLastOpenedColumn"
        nonisolated static let showFileDateAddedColumn = "showFileDateAddedColumn"
        nonisolated static let showFileModifiedColumn = "showFileModifiedColumn"
        nonisolated static let showFileCreatedColumn = "showFileCreatedColumn"
        nonisolated static let showFileSymlinkColumn = "showFileSymlinkColumn"
        nonisolated static let showFilePermissionsColumn = "showFilePermissionsColumn"
        nonisolated static let showFileOwnerColumn = "showFileOwnerColumn"
        /// #115 每格式默认压缩设置（CompressionDefaultsStore 的存储 key）—— 备份导出 / 导入 / 恢复默认都覆盖它。
        nonisolated static let compressionFormatPresets = "SimpleZip.CompressionFormatPresets.v1"
        /// #18:发布助手的工作区预设(JSON Data,备份导出 / 导入 / 恢复默认与上面同款单独处理)。
        nonisolated static let releaseWorkspacePresets = "SimpleZip.ReleaseWorkspacePresets.v1"
        /// 0.4.4 #2:发布历史账本(JSON Data,上限 100 条)。
        nonisolated static let releaseLedger = "SimpleZip.ReleaseLedger.v1"
        nonisolated static let showArchiveKindColumn = "showArchiveKindColumn"
        nonisolated static let showArchiveSizeColumn = "showArchiveSizeColumn"
        nonisolated static let showArchiveModifiedColumn = "showArchiveModifiedColumn"
        nonisolated static let showArchiveMethodColumn = "showArchiveMethodColumn"
        // 0.1.10 起新加的 6 个可选列。默认 OFF（defaults.bool 未设置 = false）：
        // - kind/size/modified/method 是高频信息，默认 ON
        // - path/encrypted/packedSize/crc/created/attributes 偏专业，用户按需打开即可
        nonisolated static let showArchivePathColumn = "showArchivePathColumn"
        nonisolated static let showArchiveEncryptedColumn = "showArchiveEncryptedColumn"
        nonisolated static let showArchivePackedSizeColumn = "showArchivePackedSizeColumn"
        nonisolated static let showArchiveCrcColumn = "showArchiveCrcColumn"
        nonisolated static let showArchiveCreatedColumn = "showArchiveCreatedColumn"
        nonisolated static let showArchiveAttributesColumn = "showArchiveAttributesColumn"
        nonisolated static let showArchiveAccessedColumn = "showArchiveAccessedColumn"
        nonisolated static let showArchiveHostOSColumn = "showArchiveHostOSColumn"
        nonisolated static let showArchiveCharacteristicsColumn = "showArchiveCharacteristicsColumn"
        nonisolated static let showArchiveSymlinkColumn = "showArchiveSymlinkColumn"
        nonisolated static let showArchiveCommentColumn = "showArchiveCommentColumn"
        nonisolated static let appLanguage = "appLanguage"
        nonisolated static let sevenZipBackend = "sevenZipBackend"
        nonisolated static let rarBackend = "rarBackend"
        nonisolated static let pinnedSidebarPaths = "pinnedSidebarPaths"
        nonisolated static let recentSidebarPaths = "recentSidebarPaths"
        nonisolated static let fileColumnOrder = "fileColumnOrder"
        nonisolated static let archiveColumnOrder = "archiveColumnOrder"
        // 用户级便捷选项：
        // - finderOpenAutoExtract: Finder 双击打开压缩包时直接解压而不开浏览主窗口；
        // - presetPasswordEnabled: 「预设密码」开关，bool 放 UserDefaults 安全；
        //   实际密码内容存在 Keychain（见 PresetPasswordStore），不再放 UserDefaults。
        nonisolated static let finderOpenAutoExtract = "finderOpenAutoExtract"
        nonisolated static let presetPasswordEnabled = "presetPasswordEnabled"
        /// 外部入口（Finder 双击 / 打开方式）浏览压缩包或文件夹时，是在新标签页打开还是复用当前窗口/标签。
        nonisolated static let openExternalInNewTab = "openExternalInNewTab"
        /// 欢迎助手是否已经完成过一次 —— 控制「首次启动自动弹」逻辑。
        /// 用户从「SimpleZip 菜单 → 重新运行欢迎助手」入口可以重置回 false 让它再弹一次。
        nonisolated static let welcomeAssistantCompleted = "welcomeAssistantCompleted"
        /// 更新助手:已展示过的「更新卡片」id 集(JSON array)。未在集内的卡 = 老用户升级后该弹的新功能卡。
        nonisolated static let seenUpdateCards = "seenUpdateCards"
        /// 更新助手:老用户一次性迁移标记(把本版之前就存在的卡标记已看,避免升级后被全量更新助手轰炸)。
        nonisolated static let updateCardsMigrated = "updateCardsMigrated"
        nonisolated static let activityHistory = "activityHistory"
        nonisolated static let activityHistoryLimit = "activityHistoryLimit"
        nonisolated static let heavyTaskConcurrencyLimit = "heavyTaskConcurrencyLimit"
        nonisolated static let tasksOpenOnFailure = "tasksOpenOnFailure"
        /// 0.4.4 #1:自动化通道(CLI / Shortcuts)允许使用预设密码(默认 true 保持现行为)。
        nonisolated static let automationAllowPresetPassword = "automationAllowPresetPassword"
        /// URL scheme(simplezip://)动作执行前是否弹确认框(默认 true=安全)。**只对没带正确密钥的来源**生效;
        /// 带 `key=<urlSchemeAutomationKey>` 的 URL 视为可信、直接执行。
        /// 关掉此开关 = 信任本机所有进程发来的 simplezip://、不再弹框。
        nonisolated static let urlSchemeRequireConfirmation = "urlSchemeRequireConfirmation"
        /// 自动化「可信密钥」:随机生成、首次读取时落库(每装机一份;**不进备份**,换机重生成)。
        /// URL 带 `key=<它>` 即免确认直接执行。
        nonisolated static let urlSchemeAutomationKey = "urlSchemeAutomationKey"
        /// 0.4.4 macOS 26 AI:把发布包 / 活动中心任务捐献进 Spotlight 语义索引(默认 true = 便利;关 = 更私密)。
        nonisolated static let spotlightIndexingEnabled = "spotlightIndexingEnabled"
        /// 0.4.5 启动卡顿修复:Spotlight 索引**电源档**(`saver` / `normal` / `highPower`)。控制重查间隔(有效期)+
        /// 是否实时增量 —— 省电=一天才查一次、不实时,高耗能=近实时。**只求后台占用低,不保证不漏更新**。默认 `normal`。
        nonisolated static let spotlightIndexingPower = "spotlightIndexingPower"
        /// 0.4.4 macOS 26 AI:AI 报告助手主开关(总结风险 / 解释失败 / 建议标签 / Issue 草稿)。默认 true;
        /// 实际入口还要 macOS 26+ 且系统模型 available 才出现 —— 关掉则所有 AI 入口隐藏。
        nonisolated static let aiAssistantEnabled = "aiAssistantEnabled"
        /// 0.4.5:AI 建议子开关(文件浏览器抽屉里的一句话摘要 + 建议动作)。默认 true,**受 AI 主开关再门控**。
        /// 关掉 → 抽屉不显示 **且** 后台自动总结模块(`generateFileSuggestionsIfEnabled`)停跑。
        nonisolated static let aiSuggestionEnabled = "aiSuggestionEnabled"
        /// 0.4.5 #89:侧边栏是否显示后台发现的推荐 AI 工作区(白皮书 4513「允许侧边栏显示推荐工作区」)。
        /// 关闭后只显示用户创建的 AI 工作区。默认 true。
        nonisolated static let aiSidebarShowRecommended = "aiSidebarShowRecommended"
        /// 0.4.5 #89:侧边栏**系统自动生成**的推荐 AI 工作区数量上限(用户:别一次冒一堆)。默认 4,范围 1–8。
        nonisolated static let aiMaxRecommendedWorkspaces = "aiMaxRecommendedWorkspaces"
        /// 0.4.5 #89:后台本地 AI 活跃度(白皮书 4508)。off / power-saver / balanced / aggressive。
        /// **默认 off —— 后台预读/预索引完全 opt-in,不开则不扫任何目录。**
        nonisolated static let aiBackgroundActivityLevel = "aiBackgroundActivityLevel"
        /// 0.4.5 agent 调度:后台索引触发间隔(AIBackgroundIndexInterval rawValue)。默认 24h。
        nonisolated static let aiBackgroundIndexInterval = "aiBackgroundIndexInterval"
        /// 0.4.5 agent 调度:单次后台运行最长 timeout(秒,超时下次继续)。默认 300(5 分钟)。
        nonisolated static let aiBackgroundMaxRunSeconds = "aiBackgroundMaxRunSeconds"
        /// 0.4.5 agent 调度:**静默后台索引总开关**(App 关闭后 agent 是否继续后台索引)。默认 false —— 独立 opt-in,
        /// 和「打开应用时索引」分开:用户开 app 有预期,但不一定接受 app 关了还在后台跑。
        nonisolated static let aiBackgroundSilentIndexEnabled = "aiBackgroundSilentIndexEnabled"
        /// 0.4.5 #89:允许后台 AI 预读归档(白皮书 4510)。只在白名单目录只读列归档清单。默认 false(opt-in)。
        nonisolated static let aiAllowArchivePrefetch = "aiAllowArchivePrefetch"
        /// 0.4.5 #89:允许后台 AI 预索引文件夹(白皮书 4511)。只在白名单目录只读建文件/文件夹元数据索引。默认 false。
        nonisolated static let aiAllowFolderPreindex = "aiAllowFolderPreindex"
        /// 0.4.5 #89:允许后台 AI **预读内容**(文档内容摘要 + 压缩包内条目清单)。比元数据预索引**更高的隐私等级**,
        /// 独立 opt-in,默认 false。开启后:对「定主题」文档读头部产脱敏结构摘要、对归档只读列内部条目(进 Spotlight)。
        nonisolated static let aiAllowContentPreread = "aiAllowContentPreread"
        /// 0.4.5 #89:后台 AI 预读目录白名单(`[AIArchivePrefetchScope]` 的 JSON;用户配置,AIBackgroundIndexStore 持有)。
        nonisolated static let aiBackgroundIndexScopes = "SimpleZip.ai.backgroundIndex.scopes.v1"
        /// 0.4.5 #89:后台文件预索引(`AIFileMemoryIndex` 的 JSON;派生数据,不进偏好备份,恢复出厂 / 清空时清掉)。
        nonisolated static let aiFileMemoryIndexData = "SimpleZip.ai.fileMemoryIndex.v1"
        /// 0.4.5 #80:用户对 AI 建议「我不喜欢」的抑制 key 集合(`[String]` 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let aiSuggestionDislikedKeys = "SimpleZip.ai.suggestion.dislikedKeys.v1"
        /// 0.4.5 #80:跨表面 AI 反馈事件日志(`[AIFeedbackEvent]` 的 JSON;「我不喜欢」明确反馈;派生数据,不进偏好备份)。
        nonisolated static let aiFeedbackEventsData = "SimpleZip.ai.feedback.events.v1"
        /// 0.4.5 #80:文件夹批量分组建议缓存(`[String: [CachedFolderGroup]]` 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let aiFolderGroupsData = "SimpleZip.ai.folderGroups.v1"
        /// 0.4.5 #80 Task 7:文件夹「整理进新文件夹」建议缓存(`[String: CachedFolderGroup]` 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let aiOrganizeSuggestionsData = "SimpleZip.ai.organize.v1"
        /// 0.4.5 #80 建议六 v2 模块⑤:活动中心「建议筛选」chip 的模型排序缓存(`[String: CachedChipRanking]` 按任务分类;派生数据,不进偏好备份)。
        nonisolated static let aiWorkbenchChipRankingData = "SimpleZip.ai.workbenchChipRanking.v1"
        /// 0.4.5 #80 建议六 v2 模块1:活动中心「需要处理」卡的 AI 解读缓存(`[String: CachedExplanation]` 按任务分类;后台预烘焙、幂等;派生数据,不进偏好备份)。
        nonisolated static let aiWorkbenchNeedsAttentionData = "SimpleZip.ai.workbenchNeedsAttention.v1"
        /// 0.4.5 #80 建议六 v2 模块①:活动中心失败任务的「失败解释」缓存(`[String: CachedExplanation]` 按任务 id;后台预烘焙、幂等、随活失败任务集修剪;派生数据,不进偏好备份)。
        nonisolated static let aiWorkbenchFailureExplanationData = "SimpleZip.ai.workbenchFailureExplanation.v1"
        /// 0.4.5 #80 建议六 v2「真建议」:活动中心模型命名的真实聚集 chip 缓存(`[String: CachedClusterChips]` 按任务分类;后台预烘焙、幂等;派生数据,不进偏好备份)。
        nonisolated static let aiWorkbenchClusterChipsData = "SimpleZip.ai.workbenchClusterChips.v1"
        /// 0.4.5 #80:**任务记录投影**(`[AITaskRecord]` 的 JSON)——App 写历史时把任务投影到此共享键,供后台 agent
        /// (App 关闭时)读来跑活动中心工作台 pass(失败解释 / 真建议命名 / 需处理解读 / 筛选排序);派生数据,不进偏好备份。
        nonisolated static let aiTaskRecordProjection = "SimpleZip.ai.taskRecordProjection.v1"
        /// 0.4.5 #80:跨表面 AI 交互信号日志(`[AIInteractionSignalEvent]` 的 JSON;点击 / 打开建议等兴趣信号;派生数据,不进偏好备份)。
        nonisolated static let aiInteractionSignalsData = "SimpleZip.ai.interaction.signals.v1"
        /// 0.4.5 #80:用户兴趣事件日志(`[AIUserInterestEvent]` 的 JSON;归档打开等接触信号,喂后台调度 / 建议的位置亲和;派生数据,不进偏好备份)。
        nonisolated static let aiInterestEventsData = "SimpleZip.ai.interest.events.v1"
        /// 0.4.5 #80:只读自动检查 pending 队列(`AIPendingCheckQueue` 的 JSON;电池决策→插电执行;派生数据,不进偏好备份)。
        nonisolated static let aiPendingChecksData = "SimpleZip.ai.pendingChecks.v1"
        /// 0.4.4:压缩使用频率统计数据(CompressionUsageStore 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let compressionUsageStats = "compressionUsageStats"
        /// 0.4.4:是否记录压缩选项使用频率(供「按我最常用的来」)。默认 true;关 = 停止记录。
        nonisolated static let compressionUsageTrackingEnabled = "compressionUsageTrackingEnabled"
        /// 0.4.4 #71:解压习惯统计数据(ExtractionUsageStore 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let extractionUsageStats = "extractionUsageStats"
        /// 0.4.4 #71:是否记录解压习惯(供解压对话框「用你常用的设置」)。默认 true;关 = 停止记录。
        nonisolated static let extractionUsageTrackingEnabled = "extractionUsageTrackingEnabled"
        /// 0.4.5 #80 建议七:工具栏动作点击习惯统计(ToolbarActionUsageStore 的 JSON;派生数据,不进偏好备份)。
        nonisolated static let toolbarActionUsageStats = "SimpleZip.toolbarActionUsageStats.v1"
        /// 0.4.5 #80 建议七:是否记录工具栏动作点击习惯(供工具栏「习惯性排序」/ AI 习惯权重)。默认 true;关 = 停止记录。
        nonisolated static let toolbarActionUsageTrackingEnabled = "toolbarActionUsageTrackingEnabled"
        /// 0.4.4 #34:归档清单缓存(ArchiveListingCacheStore 的 JSON Data;派生数据,不进偏好备份,恢复出厂时清掉)。
        nonisolated static let archiveListingCache = "SimpleZip.ArchiveListingCache.v1"
        /// 0.4.4 #34:是否缓存打开过的归档的非加密条目名(供「文件 X 在哪个包」搜索)。默认 true;关 → 停止缓存并清空。
        nonisolated static let archiveListingCacheEnabled = "archiveListingCacheEnabled"
        /// 0.4.4 #34:最多缓存多少个归档的清单(默认 50,范围 1…500)。
        nonisolated static let archiveListingCacheMaxArchives = "archiveListingCacheMaxArchives"
        /// 0.4.4 #34:缓存条目多少天后过期(默认 30,范围 0…365;0 = 永不过期)。
        nonisolated static let archiveListingCacheTTLDays = "archiveListingCacheTTLDays"
        nonisolated static let tasksPlaySoundOnFinish = "tasksPlaySoundOnFinish"
        /// 0.4.4 #10:长任务完成后发系统通知(默认关;开 → 首次时请求通知授权)。只在 app 不在前台、任务够长时发。
        nonisolated static let tasksNotifyOnFinish = "tasksNotifyOnFinish"
        nonisolated static let collapseVolumeSets = "collapseVolumeSets"
        // 0.4.3 #7:写入后自动验证(改写族默认开 / 创建与转换默认关)。
        nonisolated static let verifyAfterArchiveRewrite = "verifyAfterArchiveRewrite"
        nonisolated static let verifyAfterArchiveCreate = "verifyAfterArchiveCreate"

        // GPG 集成主开关 —— 关 → 创建 / 解压 / 状态徽章里所有 GPG 入口隐藏；设置 pane 始终可见让用户能开它。
        nonisolated static let gpgEnabled = "gpgEnabled"
        // 智能卡 / OpenPGP 硬件 token 支持（GPG 高级特性，默认关）——
        // 多数用户不用智能卡，开启会显示「我的密钥（智能卡）」分组 + 「从智能卡导入公钥」按钮 + 一些卡相关错误提示。
        // 没有这把开关时如果用户的 keyring 里恰好有卡 stub，UI 仍然能看到（不会丢数据），只是不出现卡操作入口。
        nonisolated static let gpgSmartcardEnabled = "gpgSmartcardEnabled"
        // 默认签名密钥 fingerprint（40 字符 hex）—— 用户在 GPG 设置里手动指定。
        // 创建压缩包 / 签 .siz / 签 .szs 时若未显式选签名者，fallback 到这把。空 = 未设置，用 gpg default-key。
        nonisolated static let gpgDefaultSigningKeyFingerprint = "gpgDefaultSigningKeyFingerprint"
        // 签名密钥选择策略：false (默认) = 静默使用默认签名密钥；true = 每次创建压缩包时弹 picker 让用户选。
        // 多密钥用户（工作 / 私人 / 项目分别用不同 key）通常希望开启 ask 模式。单密钥用户保持静默更顺手。
        nonisolated static let gpgPromptForSigningKey = "gpgPromptForSigningKey"
    }

    nonisolated static var startupLocation: StartupLocation {
        StartupLocation(rawValue: defaults.string(forKey: Key.startupLocation) ?? "") ?? .home
    }

    nonisolated static var appLanguage: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
    }

    nonisolated static var overwriteBehavior: OverwriteBehavior {
        OverwriteBehavior(rawValue: defaults.string(forKey: Key.overwriteBehavior) ?? "") ?? .ask
    }

    nonisolated static var confirmBeforeDeletingFiles: Bool {
        defaults.bool(forKey: Key.confirmBeforeDeletingFiles)
    }

    /// 0.4.2:任务失败时自动弹出活动中心（默认关）。
    /// 0.4.4 #1:自动化通道是否允许用预设密码(关 = 无人值守只试空密码,绝不静默用预设)。
    nonisolated static var automationAllowPresetPassword: Bool {
        defaultTrueBool(forKey: Key.automationAllowPresetPassword)
    }

    /// URL scheme 动作执行前是否弹确认框(默认 true=安全)。只对**没带正确密钥**的来源生效;带密钥的 URL 直接执行。
    nonisolated static var urlSchemeRequireConfirmation: Bool {
        defaultTrueBool(forKey: Key.urlSchemeRequireConfirmation)
    }

    /// 自动化「可信密钥」—— 随机生成、首次读取即落库(每装机一份)。URL 带 `key=<它>` 即免确认。
    /// 不进备份(换机重生成)。空/缺失则即时生成并存。
    nonisolated static var urlSchemeAutomationKey: String {
        if let existing = defaults.string(forKey: Key.urlSchemeAutomationKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Key.urlSchemeAutomationKey)
        return generated
    }

    /// 0.4.4 macOS 26 AI:是否把发布包 / 活动中心任务捐献进 Spotlight 语义索引。
    /// 默认 true = 便利(可在 Spotlight 里搜到);关 = 更私密(且调用方负责清空已捐献索引)。仅 macOS 15+ 有实际效果。
    nonisolated static var spotlightIndexingEnabled: Bool {
        defaultTrueBool(forKey: Key.spotlightIndexingEnabled)
    }

    /// 0.4.5 启动卡顿修复:Spotlight 索引电源档 raw(`saver` / `normal` / `highPower`)。默认 `normal`。
    /// 枚举语义(重查间隔 / 实时增量)在 App 侧 `SpotlightIndexingPower` 解释。
    nonisolated static var spotlightIndexingPowerRaw: String {
        get { defaults.string(forKey: Key.spotlightIndexingPower) ?? "normal" }
        set { defaults.set(newValue, forKey: Key.spotlightIndexingPower) }
    }

    /// 0.4.4 macOS 26 AI:AI 报告助手主开关。默认 true;入口另需 macOS 26 + 模型 available。
    nonisolated static var aiAssistantEnabled: Bool {
        defaultTrueBool(forKey: Key.aiAssistantEnabled)
    }

    /// 0.4.5:AI 建议子开关(默认 true)。**有效与否还要 AI 主开关开**(`aiAssistantEnabled && aiSuggestionEnabled`)。
    /// 关掉 → 文件浏览器 AI 抽屉不显示 + 后台自动总结模块停跑。
    nonisolated static var aiSuggestionEnabled: Bool {
        defaultTrueBool(forKey: Key.aiSuggestionEnabled)
    }

    /// 0.4.5 #89:侧边栏显示后台发现的推荐 AI 工作区(白皮书 4513)。默认 true。
    nonisolated static var aiSidebarShowRecommended: Bool {
        defaultTrueBool(forKey: Key.aiSidebarShowRecommended)
    }

    /// 0.4.5 #89:系统自动生成的推荐 AI 工作区数量上限。默认 4,范围 1–8。
    nonisolated static var aiMaxRecommendedWorkspaces: Int {
        get {
            guard defaults.object(forKey: Key.aiMaxRecommendedWorkspaces) != nil else { return 4 }
            return min(max(defaults.integer(forKey: Key.aiMaxRecommendedWorkspaces), 1), 8)
        }
        set { defaults.set(min(max(newValue, 1), 8), forKey: Key.aiMaxRecommendedWorkspaces) }
    }

    /// 0.4.5 #89:后台本地 AI 活跃度(白皮书 4508)。**默认 off —— opt-in,不开则后台完全不扫。**
    nonisolated static var aiBackgroundActivityLevel: AIBackgroundActivityLevel {
        get { AIBackgroundActivityLevel(rawValue: defaults.string(forKey: Key.aiBackgroundActivityLevel) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.aiBackgroundActivityLevel) }
    }

    /// 0.4.5 agent 调度:后台索引触发间隔。默认 24h(daily)。
    nonisolated static var aiBackgroundIndexInterval: AIBackgroundIndexInterval {
        get { AIBackgroundIndexInterval(rawValue: defaults.string(forKey: Key.aiBackgroundIndexInterval) ?? "") ?? .daily }
        set { defaults.set(newValue.rawValue, forKey: Key.aiBackgroundIndexInterval) }
    }

    /// 0.4.5 agent 调度:单次后台运行最长 timeout(秒,超时下次继续)。默认 900(15 分钟,配 24h 间隔)、钳 60…3600。
    nonisolated static var aiBackgroundMaxRunSeconds: Int {
        get {
            guard defaults.object(forKey: Key.aiBackgroundMaxRunSeconds) != nil else { return 900 }
            return min(max(defaults.integer(forKey: Key.aiBackgroundMaxRunSeconds), 60), 3600)
        }
        set { defaults.set(min(max(newValue, 60), 3600), forKey: Key.aiBackgroundMaxRunSeconds) }
    }

    /// 0.4.5 agent 调度:**静默后台索引总开关**(App 关闭后是否继续)。默认 false —— 独立 opt-in,与「打开应用时索引」
    /// 分开;开了才有间隔 / 单次 timeout 意义。App 一拉起后台索引归 App 走现有电源管理,与此无关。
    nonisolated static var aiBackgroundSilentIndexEnabled: Bool {
        get { defaults.bool(forKey: Key.aiBackgroundSilentIndexEnabled) }
        set { defaults.set(newValue, forKey: Key.aiBackgroundSilentIndexEnabled) }
    }

    /// 0.4.5 #89:允许后台 AI 预读归档(白皮书 4510)。默认 false(opt-in)。
    nonisolated static var aiAllowArchivePrefetch: Bool {
        get { defaults.bool(forKey: Key.aiAllowArchivePrefetch) }
        set { defaults.set(newValue, forKey: Key.aiAllowArchivePrefetch) }
    }

    /// 0.4.5 #89:允许后台 AI 预索引文件夹(白皮书 4511)。默认 false(opt-in)。
    nonisolated static var aiAllowFolderPreindex: Bool {
        get { defaults.bool(forKey: Key.aiAllowFolderPreindex) }
        set { defaults.set(newValue, forKey: Key.aiAllowFolderPreindex) }
    }

    /// 0.4.5 #89:允许后台 AI 预读内容(文档摘要 + 压缩包条目清单)。比元数据预索引**更高隐私等级**,独立 opt-in,默认 false。
    nonisolated static var aiAllowContentPreread: Bool {
        get { defaults.bool(forKey: Key.aiAllowContentPreread) }
        set { defaults.set(newValue, forKey: Key.aiAllowContentPreread) }
    }

    /// 0.4.4:是否记录压缩选项使用频率(供「按我最常用的来」)。默认 true。
    nonisolated static var compressionUsageTrackingEnabled: Bool {
        defaultTrueBool(forKey: Key.compressionUsageTrackingEnabled)
    }

    /// 0.4.4 #71:是否记录解压习惯(供解压对话框「用你常用的设置」)。默认 true。
    nonisolated static var extractionUsageTrackingEnabled: Bool {
        defaultTrueBool(forKey: Key.extractionUsageTrackingEnabled)
    }

    /// 0.4.5 #80 建议七:是否记录工具栏动作点击习惯(供工具栏「习惯性排序」/ AI 习惯权重)。默认 true。
    nonisolated static var toolbarActionUsageTrackingEnabled: Bool {
        defaultTrueBool(forKey: Key.toolbarActionUsageTrackingEnabled)
    }

    /// 0.4.4 #34:是否缓存打开过的归档的非加密条目名(供「文件 X 在哪个包」搜索)。默认 true。
    nonisolated static var archiveListingCacheEnabled: Bool {
        defaultTrueBool(forKey: Key.archiveListingCacheEnabled)
    }

    /// 0.4.4 #34:归档清单缓存最多保留多少个归档(默认 50,范围 1…500)。
    nonisolated static var archiveListingCacheMaxArchives: Int {
        get {
            guard defaults.object(forKey: Key.archiveListingCacheMaxArchives) != nil else { return 50 }
            return min(max(defaults.integer(forKey: Key.archiveListingCacheMaxArchives), 1), 500)
        }
        set { defaults.set(min(max(newValue, 1), 500), forKey: Key.archiveListingCacheMaxArchives) }
    }

    /// 0.4.4 #34:归档清单缓存的过期天数(默认 30,范围 0…365;0 = 永不过期)。
    nonisolated static var archiveListingCacheTTLDays: Int {
        get {
            guard defaults.object(forKey: Key.archiveListingCacheTTLDays) != nil else { return 30 }
            return min(max(defaults.integer(forKey: Key.archiveListingCacheTTLDays), 0), 365)
        }
        set { defaults.set(min(max(newValue, 0), 365), forKey: Key.archiveListingCacheTTLDays) }
    }

    nonisolated static var tasksOpenOnFailure: Bool {
        defaults.bool(forKey: Key.tasksOpenOnFailure)
    }

    /// 0.4.2:任务结束播放提示音（成功 Glass / 失败 Basso,默认关）。
    nonisolated static var tasksPlaySoundOnFinish: Bool {
        defaults.bool(forKey: Key.tasksPlaySoundOnFinish)
    }

    /// 0.4.4 #10:长任务完成后发系统通知(默认关)。
    nonisolated static var tasksNotifyOnFinish: Bool {
        defaults.bool(forKey: Key.tasksNotifyOnFinish)
    }

    /// 0.4.2 #4:文件浏览里把分卷家族(.001/.002…)折叠成首卷一行(默认开,View 菜单可关)。
    nonisolated static var collapseVolumeSets: Bool {
        defaultTrueBool(forKey: Key.collapseVolumeSets)
    }

    /// 0.4.3 #7:归档**改写**(增删改条目 / 批量重命名 / 清理垃圾)后,替换原包前先在工作副本上
    /// 跑 `7zz t` 验证 —— 验证失败原包不动。高风险操作,默认开。
    nonisolated static var verifyAfterArchiveRewrite: Bool {
        defaultTrueBool(forKey: Key.verifyAfterArchiveRewrite)
    }

    /// 0.4.3 #7:创建 / 格式转换产出新包后自动测试产物。普通创建风险低、大包测试耗时,默认关。
    nonisolated static var verifyAfterArchiveCreate: Bool {
        defaults.bool(forKey: Key.verifyAfterArchiveCreate)
    }

    /// 队列管理②:重归档任务(解压/创建/转换/测试/哈希等)的并发上限,超出的排队等待。
    /// 0 = 不限制(关闭调度,旧行为)。默认 3 —— 大任务同时跑太多会互相拖慢且烤硬盘。
    nonisolated static var heavyTaskConcurrencyLimit: Int {
        get {
            guard defaults.object(forKey: Key.heavyTaskConcurrencyLimit) != nil else { return 3 }
            return min(max(defaults.integer(forKey: Key.heavyTaskConcurrencyLimit), 0), 16)
        }
        set {
            defaults.set(min(max(newValue, 0), 16), forKey: Key.heavyTaskConcurrencyLimit)
        }
    }

    nonisolated static var activityHistoryLimit: Int {
        get {
            let value = defaults.integer(forKey: Key.activityHistoryLimit)
            // 0.4.2:默认 50 → 200。50 条几次批量操作就滚没了,是用户「丢历史」体感的来源之一。
            return value > 0 ? min(max(value, 1), 500) : 200
        }
        set {
            defaults.set(min(max(newValue, 1), 500), forKey: Key.activityHistoryLimit)
        }
    }

    nonisolated static var suspiciousPathPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.suspiciousPathPolicy) ?? "") ?? .ask
    }

    nonisolated static var symbolicLinkPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.symbolicLinkPolicy) ?? "") ?? .ask
    }

    nonisolated static var activeContentOpenPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.activeContentOpenPolicy) ?? "") ?? .ask
    }

    nonisolated static var sevenZipBackend: SevenZipBackendChoice {
        SevenZipBackendChoice(rawValue: defaults.string(forKey: Key.sevenZipBackend) ?? "") ?? .automatic
    }

    nonisolated static var rarBackend: RarBackendChoice {
        RarBackendChoice(rawValue: defaults.string(forKey: Key.rarBackend) ?? "") ?? .automatic
    }

    nonisolated static var showHiddenFiles: Bool {
        defaults.bool(forKey: Key.showHiddenFiles)
    }

    /// 「什么算隐藏文件」判定方式。默认 `.dotfilesOnly`（仅 Unix dotfile）。
    nonisolated static var hiddenDetectionMode: FileBrowserOutline.HiddenDetectionMode {
        get { FileBrowserOutline.HiddenDetectionMode.parse(defaults.string(forKey: Key.hiddenDetectionMode)) }
        set { defaults.set(newValue.rawValue, forKey: Key.hiddenDetectionMode) }
    }

    nonisolated static var showSymbolicLinks: Bool {
        defaultTrueBool(forKey: Key.showSymbolicLinks)
    }

    /// 同步 Finder 个人收藏的显式 opt-in 开关。关闭时侧栏继续使用内置 fallback 位置。
    nonisolated static var finderFavoritesSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.finderFavoritesSyncEnabled) }
        set { defaults.set(newValue, forKey: Key.finderFavoritesSyncEnabled) }
    }

    /// 本机授权书签不参与偏好备份/恢复，避免把用户路径和 sandbox 授权状态带到其它机器。
    nonisolated static var finderFavoritesDirectoryBookmarkData: Data? {
        defaults.data(forKey: Key.finderFavoritesDirectoryBookmarkData)
    }

    nonisolated static var hasFinderFavoritesDirectoryBookmark: Bool {
        finderFavoritesDirectoryBookmarkData != nil
    }

    nonisolated static func storeFinderFavoritesDirectoryBookmark(_ data: Data) {
        defaults.set(data, forKey: Key.finderFavoritesDirectoryBookmarkData)
    }

    nonisolated static func clearFinderFavoritesDirectoryBookmark() {
        defaults.removeObject(forKey: Key.finderFavoritesDirectoryBookmarkData)
    }

    /// 文件浏览器里文件夹可原位展开（目录行带展开箭头）。默认开；关掉回到纯平铺列表。
    nonisolated static var folderInlineExpansion: Bool {
        defaultTrueBool(forKey: Key.folderInlineExpansion)
    }

    /// 列表刷新（FSEvents / 手动刷新 / 排序分组变化）后恢复已展开的文件夹。默认开；关掉每次刷新回到全折叠。
    nonisolated static var rememberFolderExpansion: Bool {
        defaultTrueBool(forKey: Key.rememberFolderExpansion)
    }

    /// 列表刷新后恢复已展开的分卷集（0.4.2 #4 折叠行）。默认开。
    nonisolated static var rememberVolumeSetExpansion: Bool {
        defaultTrueBool(forKey: Key.rememberVolumeSetExpansion)
    }

    nonisolated static var followFinderStructure: Bool {
        defaults.bool(forKey: Key.followFinderStructure)
    }

    nonisolated static var hiddenSuffixesEnabled: Bool {
        defaultTrueBool(forKey: Key.hiddenSuffixesEnabled)
    }

    nonisolated static let recommendedHiddenSuffixes = ["app", "prefPane", "framework", "bundle", "plugin"]

    nonisolated static var hiddenRecommendedSuffixes: [String] {
        if defaults.object(forKey: Key.hiddenRecommendedSuffixes) == nil {
            return recommendedHiddenSuffixes
        }
        let configured = normalizedHiddenSuffixes(defaults.stringArray(forKey: Key.hiddenRecommendedSuffixes) ?? [])
        return recommendedHiddenSuffixes.filter { configured.contains($0.lowercased()) }
    }

    nonisolated static var hiddenCustomSuffixes: [String] {
        let recommended = Set(recommendedHiddenSuffixes.map { $0.lowercased() })
        return normalizedHiddenSuffixes(defaults.stringArray(forKey: Key.hiddenCustomSuffixes) ?? [])
            .filter { !recommended.contains($0.lowercased()) }
    }

    nonisolated static var hiddenDisplaySuffixes: [String] {
        guard hiddenSuffixesEnabled else { return [] }
        return normalizedHiddenSuffixes(hiddenRecommendedSuffixes + hiddenCustomSuffixes)
    }

    // MARK: - 隐藏文件折叠分组（0.2.0）

    /// 列表显示密度（文件 / 压缩包浏览共用）。默认 `.standard`（行高 28，升级用户观感不变）。
    nonisolated static var rowDensity: FileBrowserOutline.RowDensity {
        get { FileBrowserOutline.RowDensity.parse(defaults.string(forKey: Key.rowDensity)) }
        set { defaults.set(newValue.rawValue, forKey: Key.rowDensity) }
    }

    /// 隐藏分组折叠记忆策略。默认 `.alwaysCollapsed`（每次进文件夹都折叠）。
    nonisolated static var hiddenGroupCollapseMode: FileBrowserOutline.CollapseMode {
        get { FileBrowserOutline.CollapseMode.parse(defaults.string(forKey: Key.hiddenGroupCollapseMode)) }
        set { defaults.set(newValue.rawValue, forKey: Key.hiddenGroupCollapseMode) }
    }

    /// `.rememberPerFolder` 模式下已展开过隐藏分组的文件夹路径集合（本机 UI 状态，不导出）。
    nonisolated static var hiddenGroupExpandedFolders: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenGroupPerFolderExpanded) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.hiddenGroupPerFolderExpanded) }
    }

    /// `.globalSticky` 模式下的全局展开开关（本机 UI 状态，不导出）。
    nonisolated static var hiddenGroupGlobalExpanded: Bool {
        get { defaults.bool(forKey: Key.hiddenGroupGlobalExpanded) }
        set { defaults.set(newValue, forKey: Key.hiddenGroupGlobalExpanded) }
    }

    // MARK: - Group By 多重分类（0.2.0）

    /// 文件浏览器分组范围：全局 / 按文件夹。默认全局。
    /// 「全局」= 所有文件夹用同一个全局默认；「按文件夹」= 各文件夹可右键单独覆盖，未覆盖的回落到全局默认。
    nonisolated static var fileGroupingScope: BrowserGrouping.GroupingScope {
        get { BrowserGrouping.GroupingScope.parse(defaults.string(forKey: Key.fileGroupingScope)) }
        set { defaults.set(newValue.rawValue, forKey: Key.fileGroupingScope) }
    }

    /// 文件浏览器**全局默认**分组方式（含 `.none` = 默认不分组）。不是「总开关」——
    /// 即便默认是 `.none`，按文件夹范围下用户仍可把某个文件夹单独设成分组。
    nonisolated static var fileGroupBy: BrowserGrouping.GroupBy {
        get { BrowserGrouping.GroupBy.parse(defaults.string(forKey: Key.fileGroupBy)) }
        set { defaults.set(newValue.rawValue, forKey: Key.fileGroupBy) }
    }

    /// 压缩包浏览器分组方式（含 `.none`）。压缩包无「按文件夹」，这就是它的全局值。
    nonisolated static var archiveGroupBy: BrowserGrouping.GroupBy {
        get { BrowserGrouping.GroupBy.parse(defaults.string(forKey: Key.archiveGroupBy)) }
        set { defaults.set(newValue.rawValue, forKey: Key.archiveGroupBy) }
    }

    /// 每文件夹分组覆盖的 MRU 条目（path\tgroupBy）。本机 UI 状态，不导出。
    nonisolated static var fileFolderGroupingEntries: [String] {
        get { defaults.stringArray(forKey: Key.fileFolderGrouping) ?? [] }
        set { defaults.set(newValue, forKey: Key.fileFolderGrouping) }
    }

    /// 某文件夹的分组覆盖；nil = 跟随全局默认。
    nonisolated static func fileFolderGroupBy(forKey key: String) -> BrowserGrouping.GroupBy? {
        BrowserGrouping.folderOverride(in: fileFolderGroupingEntries, forKey: key)
    }

    /// 设定 / 清除某文件夹的分组覆盖（nil = 清除，回到跟随全局默认）。
    nonisolated static func setFileFolderGroupBy(_ groupBy: BrowserGrouping.GroupBy?, forKey key: String) {
        fileFolderGroupingEntries = BrowserGrouping.upsertFolderOverride(fileFolderGroupingEntries, forKey: key, groupBy: groupBy)
    }

    /// 文件浏览器某文件夹「当前实际生效」的分组维度：
    /// 全局范围 → 全局默认；按文件夹范围 → 该文件夹覆盖（无覆盖则回落全局默认）。
    nonisolated static func effectiveFileGroupBy(forFolderKey key: String) -> BrowserGrouping.GroupBy {
        switch fileGroupingScope {
        case .global: return fileGroupBy
        case .perFolder: return fileFolderGroupBy(forKey: key) ?? fileGroupBy
        }
    }

    /// 压缩包浏览器「当前实际生效」的分组维度（就是它的全局值）。
    nonisolated static var effectiveArchiveGroupBy: BrowserGrouping.GroupBy {
        archiveGroupBy
    }

    /// Group By 开启时，隐藏文件与分类组怎么共存。默认 `.foldIntoGroups`（融进各分类组）。
    nonisolated static var hiddenWithGrouping: BrowserGrouping.HiddenWithGrouping {
        get { BrowserGrouping.HiddenWithGrouping.parse(defaults.string(forKey: Key.hiddenWithGrouping)) }
        set { defaults.set(newValue.rawValue, forKey: Key.hiddenWithGrouping) }
    }

    nonisolated static var rememberLastFolder: Bool {
        if defaults.object(forKey: Key.rememberLastFolder) == nil {
            return true
        }
        return defaults.bool(forKey: Key.rememberLastFolder)
    }

    /// 每次启动时静默检查更新（仅在发现新版时弹 Sparkle 提示）。默认关 —— opt-in，不改变现有行为。
    /// 注意这跟 Sparkle 自带的周期后台检查是叠加关系，不是替代。
    nonisolated static var checkForUpdatesOnLaunch: Bool {
        defaults.bool(forKey: Key.checkForUpdatesOnLaunch)
    }

    nonisolated static var showFileSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileSizeColumn)
    }

    nonisolated static var showFileTypeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileTypeColumn)
    }

    nonisolated static var showFileApplicationColumn: Bool {
        defaultTrueBool(forKey: Key.showFileApplicationColumn)
    }

    nonisolated static var showFileLastOpenedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileLastOpenedColumn)
    }

    nonisolated static var showFileDateAddedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileDateAddedColumn)
    }

    nonisolated static var showFileModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileModifiedColumn)
    }

    nonisolated static var showFileCreatedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileCreatedColumn)
    }

    nonisolated static var showFileSymlinkColumn: Bool {
        defaults.bool(forKey: Key.showFileSymlinkColumn)
    }

    nonisolated static var showFilePermissionsColumn: Bool {
        defaults.bool(forKey: Key.showFilePermissionsColumn)
    }

    nonisolated static var showFileOwnerColumn: Bool {
        defaults.bool(forKey: Key.showFileOwnerColumn)
    }

    nonisolated static var showArchiveKindColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveKindColumn)
    }

    nonisolated static var showArchiveSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveSizeColumn)
    }

    nonisolated static var showArchiveModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveModifiedColumn)
    }

    nonisolated static var showArchiveMethodColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveMethodColumn)
    }

    // 0.1.10 起的可选列：默认 OFF —— defaults.bool 未设置时返回 false，与「按需打开」语义一致。
    nonisolated static var showArchivePathColumn: Bool {
        defaults.bool(forKey: Key.showArchivePathColumn)
    }

    nonisolated static var showArchiveEncryptedColumn: Bool {
        defaults.bool(forKey: Key.showArchiveEncryptedColumn)
    }

    nonisolated static var showArchivePackedSizeColumn: Bool {
        defaults.bool(forKey: Key.showArchivePackedSizeColumn)
    }

    nonisolated static var showArchiveCrcColumn: Bool {
        defaults.bool(forKey: Key.showArchiveCrcColumn)
    }

    nonisolated static var showArchiveCreatedColumn: Bool {
        defaults.bool(forKey: Key.showArchiveCreatedColumn)
    }

    nonisolated static var showArchiveAttributesColumn: Bool {
        defaults.bool(forKey: Key.showArchiveAttributesColumn)
    }

    nonisolated static var showArchiveAccessedColumn: Bool {
        defaults.bool(forKey: Key.showArchiveAccessedColumn)
    }

    nonisolated static var showArchiveHostOSColumn: Bool {
        defaults.bool(forKey: Key.showArchiveHostOSColumn)
    }

    nonisolated static var showArchiveCharacteristicsColumn: Bool {
        defaults.bool(forKey: Key.showArchiveCharacteristicsColumn)
    }

    nonisolated static var showArchiveSymlinkColumn: Bool {
        defaults.bool(forKey: Key.showArchiveSymlinkColumn)
    }

    nonisolated static var showArchiveCommentColumn: Bool {
        defaults.bool(forKey: Key.showArchiveCommentColumn)
    }

    nonisolated static var lastFolderURL: URL? {
        guard let path = defaults.string(forKey: Key.lastFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func rememberLastFolder(_ url: URL) {
        guard rememberLastFolder else { return }
        defaults.set(url.path, forKey: Key.lastFolderPath)
        rememberRecentFolder(url)
    }

    nonisolated static var pinnedSidebarURLs: [URL] {
        urls(forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static var recentSidebarURLs: [URL] {
        urls(forKey: Key.recentSidebarPaths)
    }

    nonisolated static func pinSidebarURL(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []
        let path = url.standardized.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static func unpinSidebarURL(_ url: URL) {
        let path = url.standardized.path
        let paths = (defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static func stringArray(forKey key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    nonisolated static func setStringArray(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    nonisolated static func setHiddenRecommendedSuffixes(_ value: [String]) {
        let configured = Set(normalizedHiddenSuffixes(value))
        defaults.set(
            recommendedHiddenSuffixes.filter { configured.contains($0.lowercased()) },
            forKey: Key.hiddenRecommendedSuffixes
        )
    }

    nonisolated static func setHiddenCustomSuffixes(_ value: [String]) {
        let blocked = Set(recommendedHiddenSuffixes.map { $0.lowercased() })
        defaults.set(
            normalizedHiddenSuffixes(value).filter { !blocked.contains($0.lowercased()) },
            forKey: Key.hiddenCustomSuffixes
        )
    }

    nonisolated static func normalizedHiddenSuffix(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        return result.lowercased()
    }

    /// Finder 双击 / Services 等外部入口打开压缩包时是否直接解压而不开浏览窗口。
    /// 默认关，遵循「不出意外行为」的原则。
    nonisolated static var finderOpenAutoExtract: Bool {
        defaults.bool(forKey: Key.finderOpenAutoExtract)
    }

    /// 外部入口（Finder / 打开方式）浏览压缩包或文件夹时是否在新标签页打开。默认开 —— 不打扰当前正在看的内容。
    /// 关闭则复用当前窗口/标签（直接在当前标签里打开）。
    nonisolated static var openExternalInNewTab: Bool {
        get {
            if defaults.object(forKey: Key.openExternalInNewTab) == nil { return true }
            return defaults.bool(forKey: Key.openExternalInNewTab)
        }
        set { defaults.set(newValue, forKey: Key.openExternalInNewTab) }
    }

    /// 是否启用「预设密码」便捷功能。开启后：
    /// 1) 创建压缩包时若选了加密会自动填入；
    /// 2) 打开 / 解压压缩包时会先用预设尝试一次，失败再弹密码框。
    nonisolated static var presetPasswordEnabled: Bool {
        defaults.bool(forKey: Key.presetPasswordEnabled)
    }

    /// 是否启用 GPG 集成功能（**主开关**）。关 → 创建对话框 / 打开压缩包流程 / 所有相关入口隐藏；
    /// 设置 → GPG pane 始终可见，让用户在里面开它。默认 false（首次用户不会被打扰）。
    nonisolated static var gpgEnabled: Bool {
        defaults.bool(forKey: Key.gpgEnabled)
    }

    /// 是否启用智能卡 / OpenPGP 硬件 token 支持。默认 false —— 多数用户不用卡，避免 UI 多一堆「卡上密钥」「从智能卡导入」入口让人困惑。
    /// 开启时 GPGPane 高级区出现智能卡相关按钮 + 卡 stub 密钥单独分组。
    nonisolated static var gpgSmartcardEnabled: Bool {
        defaults.bool(forKey: Key.gpgSmartcardEnabled)
    }

    /// 默认签名密钥 fingerprint（40 字符）。空 = 未设置（fallback 到 gpg default-key）。
    /// 写入：用户在 GPG pane 点「设为默认」时 set；点「清除」时 set 成空串。
    nonisolated static var gpgDefaultSigningKeyFingerprint: String {
        defaults.string(forKey: Key.gpgDefaultSigningKeyFingerprint) ?? ""
    }

    /// 签名密钥选择策略 —— false 静默用默认密钥 / true 每次创建压缩包时弹 picker。
    /// 默认 false（单密钥用户体验保持不变）；多密钥用户在 GPG pane → 默认值 子项里改成 true。
    nonisolated static var gpgPromptForSigningKey: Bool {
        defaults.bool(forKey: Key.gpgPromptForSigningKey)
    }

    /// 预设密码的实际内容。空字符串等于「未配置」。
    /// 存储已迁到 Keychain（见 `PresetPasswordStore`）。本属性是业务侧（创建/解压自动填）
    /// 的静默读取入口，不会触发 Touch ID。
    nonisolated static var presetPassword: String {
        PresetPasswordStore.load()
    }

    /// 「预设密码」便捷功能是否真的可用 —— 必须既开启又填了内容。
    /// UI 用这个属性灰按钮，业务层 (auto-fill / auto-try) 用这个判断是否走预设路径。
    nonisolated static var hasUsablePresetPassword: Bool {
        presetPasswordEnabled && !presetPassword.isEmpty
    }

    /// 返回 true 表示 Keychain 真的落盘成功。
    /// UI 必须根据返回值显示「保存成功 / 失败」 —— 旧版本无脑显示成功，
    /// 失败时下次启动 load 仍然为空，把失败伪装成成功。
    @discardableResult
    nonisolated static func setPresetPassword(_ value: String) -> Bool {
        PresetPasswordStore.save(value) == errSecSuccess
    }

    /// 返回 true 表示 Keychain 真的删除成功（含「本来就不存在」）。
    /// UI 必须根据返回值显示「清除成功 / 失败」 —— 删失败时不能让 UI 误以为已经清了，
    /// 否则下次启动旧密码还在但 UI 状态对不上。
    @discardableResult
    nonisolated static func clearPresetPassword() -> Bool {
        PresetPasswordStore.clear() == errSecSuccess
    }

    /// 欢迎助手是否完成过一次。
    /// false → 首次启动时 ContentView 自动弹起助手；
    /// true  → 不再自动弹，只在用户点「重新运行欢迎助手」时才打开。
    nonisolated static var welcomeAssistantCompleted: Bool {
        defaults.bool(forKey: Key.welcomeAssistantCompleted)
    }

    /// 助手走完最后一步 / 用户点「开始使用」时调用。
    nonisolated static func markWelcomeAssistantCompleted() {
        defaults.set(true, forKey: Key.welcomeAssistantCompleted)
    }

    // MARK: - 更新助手卡片「已看」标记(通用 id 存储;具体卡片枚举在 App 层 UpdateAssistant)

    /// 已展示过的更新卡片 id 集。未在集内 = 老用户升级后该弹的新功能卡。
    nonisolated static var seenUpdateCards: Set<String> {
        Set((defaults.array(forKey: Key.seenUpdateCards) as? [String]) ?? [])
    }

    /// 把若干更新卡片 id 标记为已看(欢迎助手走完 = 全标;更新助手走完 = 标其展示的那些)。
    nonisolated static func markUpdateCardsSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        defaults.set(Array(seenUpdateCards.union(ids)), forKey: Key.seenUpdateCards)
    }

    /// 老用户一次性迁移是否已做。
    nonisolated static var updateCardsMigrated: Bool {
        defaults.bool(forKey: Key.updateCardsMigrated)
    }

    nonisolated static func markUpdateCardsMigrated() {
        defaults.set(true, forKey: Key.updateCardsMigrated)
    }

    /// DevTools 测试用:清空全部卡「已看」+ 迁移标记 → 下次启动老用户重新收到更新助手。
    nonisolated static func resetUpdateCardsSeen() {
        defaults.removeObject(forKey: Key.seenUpdateCards)
        defaults.removeObject(forKey: Key.updateCardsMigrated)
    }

    /// 用户在设置里挑的「当前活跃」自定义启动路径。空表示尚未挑选。
    /// 也是 history 列表里被点亮的那一项 —— 二者保持一致。
    nonisolated static var startupCustomLocationURL: URL? {
        guard let path = defaults.string(forKey: Key.startupCustomLocationPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func setStartupCustomLocation(_ url: URL?) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: Key.startupCustomLocationPath)
        } else {
            defaults.removeObject(forKey: Key.startupCustomLocationPath)
        }
    }

    /// 用户挑过的所有 custom 路径，按 MRU 顺序。
    nonisolated static var startupCustomLocationHistory: [URL] {
        (defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// 把一个新 / 已有的 custom 路径加进历史并设为当前活跃。
    /// 行为：移到列表头部（最近使用），若超过 `keepingAtMost` 项就裁掉末尾。
    nonisolated static func recordCustomStartupLocation(_ url: URL, keepingAtMost limit: Int) {
        let canonical = url.standardizedFileURL.path
        var paths = (defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? [])
        paths.removeAll { $0 == canonical }
        paths.insert(canonical, at: 0)
        if paths.count > limit {
            paths = Array(paths.prefix(limit))
        }
        defaults.set(paths, forKey: Key.startupCustomLocationHistory)
        defaults.set(canonical, forKey: Key.startupCustomLocationPath)
    }

    /// 从历史里移除一条（用户主动「忘记」某条），同时若它是当前活跃的也顺手清掉。
    nonisolated static func removeCustomStartupLocation(_ url: URL) {
        let canonical = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? []
        paths.removeAll { $0 == canonical }
        defaults.set(paths, forKey: Key.startupCustomLocationHistory)
        if defaults.string(forKey: Key.startupCustomLocationPath) == canonical {
            defaults.removeObject(forKey: Key.startupCustomLocationPath)
        }
    }

    /// 把启动配置恢复到默认（home）+ 清掉 custom 相关状态。
    /// 启动时弹窗里「重置」按钮、设置面板里未来可能的「恢复默认」入口都会用。
    // MARK: - 备份 / 还原

    /// 可以参与导出 / 导入 / 全部恢复默认的 key 名单。
    ///
    /// 故意手动登记 ——
    /// 1. 隐私字段（lastFolderPath / pinnedSidebarPaths / recentSidebarPaths）会暴露用户真实
    ///    本机路径，不导出；
    /// 2. 安全字段（旧版本可能存在的 legacy `presetPassword`）属于密码本身，绝不导出；
    /// 3. 导入时只接受登记过的 key，防止恶意 JSON 写不属于 SimpleZip 的 UserDefaults key
    ///    （比如 AppleLanguages 这种全局系统 key）。
    /// 添加新 settings key 时，记得来这里登记一下 + 同步更新 release-checklist.md。
    nonisolated static let exportableUserDefaultsKeys: [String] = [
        // 活动中心(0.4.2)
        Key.activityHistoryLimit,
        Key.heavyTaskConcurrencyLimit,
        Key.tasksOpenOnFailure,
        Key.tasksPlaySoundOnFinish,
        Key.tasksNotifyOnFinish,
        Key.automationAllowPresetPassword,
        Key.urlSchemeRequireConfirmation,
        Key.spotlightIndexingEnabled,
        Key.spotlightIndexingPower,
        Key.aiAssistantEnabled,
        Key.aiSuggestionEnabled,
        Key.aiSidebarShowRecommended,
        Key.aiMaxRecommendedWorkspaces,
        Key.aiBackgroundActivityLevel,
        Key.aiBackgroundIndexInterval,
        Key.aiBackgroundMaxRunSeconds,
        Key.aiBackgroundSilentIndexEnabled,
        Key.aiAllowArchivePrefetch,
        Key.aiAllowContentPreread,
        Key.aiAllowFolderPreindex,
        Key.compressionUsageTrackingEnabled,
        Key.extractionUsageTrackingEnabled,
        Key.toolbarActionUsageTrackingEnabled,
        Key.archiveListingCacheEnabled,
        Key.archiveListingCacheMaxArchives,
        Key.archiveListingCacheTTLDays,
        Key.collapseVolumeSets,
        Key.verifyAfterArchiveRewrite,
        Key.verifyAfterArchiveCreate,
        Key.appLanguage,
        Key.startupLocation,
        Key.startupCustomLocationPath,
        Key.startupCustomLocationHistory,
        Key.rememberLastFolder,
        Key.checkForUpdatesOnLaunch,
        Key.betaUpdatesEnabled,
        Key.overwriteBehavior,
        Key.confirmBeforeDeletingFiles,
        Key.finderOpenAutoExtract,
        Key.openExternalInNewTab,
        // 注意：只导 presetPasswordEnabled 开关，密码本身永远在 Keychain，不进导出文件。
        Key.presetPasswordEnabled,
        // GPG 集成主开关 + 智能卡支持开关 + 默认签名密钥 fingerprint；私钥 / 公钥都在 ~/.gnupg/ 或 SimpleZip 私有 ring，
        // 不进偏好导出文件。fingerprint 字符串属于「指向密钥的标识」，不是密钥本身，可导出。
        Key.gpgEnabled,
        Key.gpgSmartcardEnabled,
        Key.gpgDefaultSigningKeyFingerprint,
        Key.gpgPromptForSigningKey,
        Key.suspiciousPathPolicy,
        Key.symbolicLinkPolicy,
        Key.activeContentOpenPolicy,
        Key.sevenZipBackend,
        Key.rarBackend,
        Key.showHiddenFiles,
        Key.hiddenDetectionMode,
        Key.showSymbolicLinks,
        Key.folderInlineExpansion,
        Key.rememberFolderExpansion,
        Key.rememberVolumeSetExpansion,
        Key.followFinderStructure,
        Key.hiddenSuffixesEnabled,
        Key.hiddenRecommendedSuffixes,
        Key.hiddenCustomSuffixes,
        // 折叠记忆策略可导出；per-folder / global 展开状态是本机 UI 状态（含真实路径），不导出。
        Key.hiddenGroupCollapseMode,
        Key.fileGroupBy,
        Key.archiveGroupBy,
        Key.hiddenWithGrouping,
        Key.fileGroupingScope,
        Key.rowDensity,
        Key.showFileSizeColumn,
        Key.showFileTypeColumn,
        Key.showFileApplicationColumn,
        Key.showFileLastOpenedColumn,
        Key.showFileDateAddedColumn,
        Key.showFileModifiedColumn,
        Key.showFileCreatedColumn,
        Key.showFileSymlinkColumn,
        Key.showFilePermissionsColumn,
        Key.showFileOwnerColumn,
        Key.showArchiveKindColumn,
        Key.showArchiveSizeColumn,
        Key.showArchiveModifiedColumn,
        Key.showArchiveMethodColumn,
        Key.showArchivePathColumn,
        Key.showArchiveEncryptedColumn,
        Key.showArchivePackedSizeColumn,
        Key.showArchiveCrcColumn,
        Key.showArchiveCreatedColumn,
        Key.showArchiveAttributesColumn,
        Key.showArchiveAccessedColumn,
        Key.showArchiveHostOSColumn,
        Key.showArchiveCharacteristicsColumn,
        Key.showArchiveSymlinkColumn,
        Key.showArchiveCommentColumn,
        Key.fileColumnOrder,
        Key.archiveColumnOrder,
        // 「导出时是否包含按文件夹记忆」这个偏好本身也算用户选择，纳入备份。
        Key.includePerFolderMemoryInBackup
    ]

    /// 「按文件夹记忆」相关的本机 UI 状态 key（含真实路径）：每文件夹分组覆盖 + 隐藏组每文件夹展开记忆。
    /// 默认**不**导出（换台电脑导入不该背一堆本机废路径）；用户在备份面板勾选后才纳入导出。
    /// 导入 / 全部恢复时**始终**纳入处理（还原备份语义：备份没有就清掉本机现有的）。
    nonisolated static let perFolderMemoryKeys: [String] = [
        Key.fileFolderGrouping,
        Key.hiddenGroupPerFolderExpanded
    ]

    /// 导出时是否包含「按文件夹记忆」。默认关。
    nonisolated static var includePerFolderMemoryInBackup: Bool {
        get { defaults.bool(forKey: Key.includePerFolderMemoryInBackup) }
        set { defaults.set(newValue, forKey: Key.includePerFolderMemoryInBackup) }
    }

    /// 当前所有可导出 key 的**有效值**快照（含未写入 UserDefaults 时的代码默认值）。
    ///
    /// 直接读各 typed accessor —— 默认值来自 accessor 这一唯一真相源，**不在这里重复硬编码**。
    /// 旧实现用 `defaults.object(forKey:)` 逐个取，凡是还停在默认（从没被写过）的 key 就从导出文件里消失了
    /// （如 archiveGroupBy / hiddenWithGrouping / overwriteBehavior / rowDensity…），导致备份看着「根本不全」、
    /// 也不是一份能自解释的快照。这里改成无条件给每个 key 落一个有效值，导出 = 完整配置快照。
    ///
    /// ⚠️ 维护约束：新增可导出 key（进 `exportableUserDefaultsKeys`）时必须同步在这里补一行；
    /// 单测 `exportableSnapshotCoversAllExportableKeys` 会守住这个不变量。
    /// （`startupCustomLocationPath` 是可选路径，未设置时不落键 —— 该 key 不参与那条覆盖断言。）
    nonisolated static func exportableSnapshot() -> [String: Any] {
        var v: [String: Any] = [:]
        // 活动中心(0.4.2)
        v[Key.activityHistoryLimit] = activityHistoryLimit
        v[Key.heavyTaskConcurrencyLimit] = heavyTaskConcurrencyLimit
        v[Key.tasksOpenOnFailure] = tasksOpenOnFailure
        v[Key.automationAllowPresetPassword] = automationAllowPresetPassword
        v[Key.urlSchemeRequireConfirmation] = urlSchemeRequireConfirmation
        v[Key.spotlightIndexingEnabled] = spotlightIndexingEnabled
        v[Key.spotlightIndexingPower] = spotlightIndexingPowerRaw
        v[Key.aiAssistantEnabled] = aiAssistantEnabled
        v[Key.aiSuggestionEnabled] = aiSuggestionEnabled
        v[Key.aiSidebarShowRecommended] = aiSidebarShowRecommended
        v[Key.aiMaxRecommendedWorkspaces] = aiMaxRecommendedWorkspaces
        v[Key.aiBackgroundActivityLevel] = aiBackgroundActivityLevel.rawValue
        v[Key.aiBackgroundIndexInterval] = aiBackgroundIndexInterval.rawValue
        v[Key.aiBackgroundMaxRunSeconds] = aiBackgroundMaxRunSeconds
        v[Key.aiBackgroundSilentIndexEnabled] = aiBackgroundSilentIndexEnabled
        v[Key.aiAllowArchivePrefetch] = aiAllowArchivePrefetch
        v[Key.aiAllowContentPreread] = aiAllowContentPreread
        v[Key.aiAllowFolderPreindex] = aiAllowFolderPreindex
        v[Key.compressionUsageTrackingEnabled] = compressionUsageTrackingEnabled
        v[Key.extractionUsageTrackingEnabled] = extractionUsageTrackingEnabled
        v[Key.toolbarActionUsageTrackingEnabled] = toolbarActionUsageTrackingEnabled
        v[Key.archiveListingCacheEnabled] = archiveListingCacheEnabled
        v[Key.archiveListingCacheMaxArchives] = archiveListingCacheMaxArchives
        v[Key.archiveListingCacheTTLDays] = archiveListingCacheTTLDays
        v[Key.tasksPlaySoundOnFinish] = tasksPlaySoundOnFinish
        v[Key.tasksNotifyOnFinish] = tasksNotifyOnFinish
        v[Key.collapseVolumeSets] = collapseVolumeSets
        v[Key.verifyAfterArchiveRewrite] = verifyAfterArchiveRewrite
        v[Key.verifyAfterArchiveCreate] = verifyAfterArchiveCreate
        // 启动 / 语言
        v[Key.appLanguage] = appLanguage.rawValue
        v[Key.startupLocation] = startupLocation.rawValue
        if let path = defaults.string(forKey: Key.startupCustomLocationPath) {
            v[Key.startupCustomLocationPath] = path
        }
        v[Key.startupCustomLocationHistory] = stringArray(forKey: Key.startupCustomLocationHistory)
        v[Key.rememberLastFolder] = rememberLastFolder
        v[Key.checkForUpdatesOnLaunch] = checkForUpdatesOnLaunch
        v[Key.betaUpdatesEnabled] = defaults.bool(forKey: Key.betaUpdatesEnabled)
        // 解压 / 安全策略
        v[Key.overwriteBehavior] = overwriteBehavior.rawValue
        v[Key.confirmBeforeDeletingFiles] = confirmBeforeDeletingFiles
        v[Key.finderOpenAutoExtract] = finderOpenAutoExtract
        v[Key.openExternalInNewTab] = openExternalInNewTab
        v[Key.presetPasswordEnabled] = presetPasswordEnabled
        v[Key.suspiciousPathPolicy] = suspiciousPathPolicy.rawValue
        v[Key.symbolicLinkPolicy] = symbolicLinkPolicy.rawValue
        v[Key.activeContentOpenPolicy] = activeContentOpenPolicy.rawValue
        // GPG（开关 + 默认签名 fingerprint，私钥 / 公钥不导出）
        v[Key.gpgEnabled] = gpgEnabled
        v[Key.gpgSmartcardEnabled] = gpgSmartcardEnabled
        v[Key.gpgDefaultSigningKeyFingerprint] = gpgDefaultSigningKeyFingerprint
        v[Key.gpgPromptForSigningKey] = gpgPromptForSigningKey
        // 后端
        v[Key.sevenZipBackend] = sevenZipBackend.rawValue
        v[Key.rarBackend] = rarBackend.rawValue
        // 浏览 / 隐藏文件
        v[Key.showHiddenFiles] = showHiddenFiles
        v[Key.hiddenDetectionMode] = hiddenDetectionMode.rawValue
        v[Key.showSymbolicLinks] = showSymbolicLinks
        v[Key.folderInlineExpansion] = folderInlineExpansion
        v[Key.rememberFolderExpansion] = rememberFolderExpansion
        v[Key.rememberVolumeSetExpansion] = rememberVolumeSetExpansion
        v[Key.followFinderStructure] = followFinderStructure
        v[Key.hiddenSuffixesEnabled] = hiddenSuffixesEnabled
        v[Key.hiddenRecommendedSuffixes] = hiddenRecommendedSuffixes
        v[Key.hiddenCustomSuffixes] = hiddenCustomSuffixes
        v[Key.hiddenGroupCollapseMode] = hiddenGroupCollapseMode.rawValue
        // 分组 / 视图
        v[Key.fileGroupBy] = fileGroupBy.rawValue
        v[Key.archiveGroupBy] = archiveGroupBy.rawValue
        v[Key.hiddenWithGrouping] = hiddenWithGrouping.rawValue
        v[Key.fileGroupingScope] = fileGroupingScope.rawValue
        v[Key.rowDensity] = rowDensity.rawValue
        // 列可见性
        v[Key.showFileSizeColumn] = showFileSizeColumn
        v[Key.showFileTypeColumn] = showFileTypeColumn
        v[Key.showFileApplicationColumn] = showFileApplicationColumn
        v[Key.showFileLastOpenedColumn] = showFileLastOpenedColumn
        v[Key.showFileDateAddedColumn] = showFileDateAddedColumn
        v[Key.showFileModifiedColumn] = showFileModifiedColumn
        v[Key.showFileCreatedColumn] = showFileCreatedColumn
        v[Key.showFileSymlinkColumn] = showFileSymlinkColumn
        v[Key.showFilePermissionsColumn] = showFilePermissionsColumn
        v[Key.showFileOwnerColumn] = showFileOwnerColumn
        v[Key.showArchiveKindColumn] = showArchiveKindColumn
        v[Key.showArchiveSizeColumn] = showArchiveSizeColumn
        v[Key.showArchiveModifiedColumn] = showArchiveModifiedColumn
        v[Key.showArchiveMethodColumn] = showArchiveMethodColumn
        v[Key.showArchivePathColumn] = showArchivePathColumn
        v[Key.showArchiveEncryptedColumn] = showArchiveEncryptedColumn
        v[Key.showArchivePackedSizeColumn] = showArchivePackedSizeColumn
        v[Key.showArchiveCrcColumn] = showArchiveCrcColumn
        v[Key.showArchiveCreatedColumn] = showArchiveCreatedColumn
        v[Key.showArchiveAttributesColumn] = showArchiveAttributesColumn
        v[Key.showArchiveAccessedColumn] = showArchiveAccessedColumn
        v[Key.showArchiveHostOSColumn] = showArchiveHostOSColumn
        v[Key.showArchiveCharacteristicsColumn] = showArchiveCharacteristicsColumn
        v[Key.showArchiveSymlinkColumn] = showArchiveSymlinkColumn
        v[Key.showArchiveCommentColumn] = showArchiveCommentColumn
        v[Key.fileColumnOrder] = stringArray(forKey: Key.fileColumnOrder)
        v[Key.archiveColumnOrder] = stringArray(forKey: Key.archiveColumnOrder)
        // 备份元开关
        v[Key.includePerFolderMemoryInBackup] = includePerFolderMemoryInBackup
        return v
    }

    /// 拼一份导出 payload（完整配置快照），可直接 JSONSerialization 序列化。
    /// 勾了「包含按文件夹记忆」才把 perFolderMemoryKeys（含真实路径）一并导出。
    nonisolated static func exportablePayload() -> [String: Any] {
        var values = exportableSnapshot()
        if includePerFolderMemoryInBackup {
            values[Key.fileFolderGrouping] = fileFolderGroupingEntries
            values[Key.hiddenGroupPerFolderExpanded] = Array(hiddenGroupExpandedFolders)
        }
        // #115 默认压缩设置：存的是 JSON Data,转成 JSON 对象塞进 payload（Data 本身不是 JSON 可序列化类型）。
        if let presets = compressionFormatPresetsExportValue() {
            values[Key.compressionFormatPresets] = presets
        }
        // #18 工作区预设:同款 JSON Data → JSON 对象。
        if let workspaces = jsonDataExportValue(forKey: Key.releaseWorkspacePresets) {
            values[Key.releaseWorkspacePresets] = workspaces
        }
        // 0.4.4 #2 发布账本:同款 JSON Data → JSON 对象。
        if let ledger = jsonDataExportValue(forKey: Key.releaseLedger) {
            values[Key.releaseLedger] = ledger
        }
        // AI 后台索引白名单目录(JSON 数组 Data,同款处理)—— 用户配置、应可随备份迁移(A21:导出 / 恢复出厂都要覆盖)。
        if let scopes = jsonDataExportValue(forKey: Key.aiBackgroundIndexScopes) {
            values[Key.aiBackgroundIndexScopes] = scopes
        }
        return PreferencesPayloadCodec.makePayload(values: values)
    }

    /// 「JSON Data 存盘 → payload JSON 对象」的通用还原(#115 / #18 共用形态)。
    nonisolated static func jsonDataExportValue(forKey key: String) -> Any? {
        guard let data = defaults.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    /// 默认压缩设置的导出值：把存盘的 JSON Data 还原成 JSON 对象（[String: Any]）以便进 payload;
    /// 没存过 / 损坏返回 nil。导入时再 `JSONSerialization` 写回 Data（见 `importPayload`）。
    nonisolated static func compressionFormatPresetsExportValue() -> Any? {
        guard let data = defaults.data(forKey: Key.compressionFormatPresets),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    /// 把一份外部 payload 写回 UserDefaults。
    ///
    /// 语义是「还原备份」，不是「打补丁」：先把所有白名单 key 抹掉，让没出现在 payload 里的
    /// 项目回落到代码默认值，再写 payload 里有的 key。
    /// 旧实现只覆盖 payload 里有的 key，没出现的就保留导入前的旧值，导致用户「换了一个
    /// 简化版备份」之后还是带着上次的零散设置，根本对不上备份原状态。
    /// 只接受白名单里的 key（防御 payload 里出现 AppleLanguages 这种全局系统 key）。
    /// 导入完成后调用方应让相关 UI 刷新。
    /// 一个值是否能安全写进 `UserDefaults`(属性列表标量 / 集合)。**显式拒 `NSNull`**(JSON null 解码所得 ——
    /// `defaults.set(NSNull())` 会 Foundation abort);集合递归校验,挡住嵌套 null / 非 plist 值。
    private nonisolated static func isStorablePreferenceValue(_ value: Any) -> Bool {
        switch value {
        case is NSNull:
            return false
        case is String, is NSNumber, is Date, is Data:
            return true
        case let array as [Any]:
            return array.allSatisfy(isStorablePreferenceValue)
        case let dict as [String: Any]:
            return dict.values.allSatisfy(isStorablePreferenceValue)
        default:
            return false
        }
    }

    /// 导入按文件夹记忆始终纳入处理（还原备份语义）：备份里有就写、没有就清掉本机现有的。
    nonisolated static func importPayload(_ payload: [String: Any]) throws {
        let values = try PreferencesPayloadCodec.decode(payload)
        let importKeys = exportableUserDefaultsKeys + perFolderMemoryKeys
        let allowed = Set(importKeys)
        for key in importKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values where allowed.contains(key) {
            // 安全:只写**可存进 UserDefaults 的属性列表标量/集合**。损坏 / 恶意备份可能给某白名单 key 配 JSON null
            // (解码成 NSNull)→ `defaults.set(NSNull(), forKey:)` 触发 Foundation abort 崩溃。非 plist 值一律跳过。
            guard Self.isStorablePreferenceValue(value) else { continue }
            defaults.set(value, forKey: key)
        }
        // #115 默认压缩设置（JSON 对象 → Data）。还原备份语义:备份里有就写、没有就清掉本机现有的。
        // 它不在 `exportableUserDefaultsKeys` 里（存的是 Data 而非简单标量,得 JSON 重编码），故在此单独处理。
        defaults.removeObject(forKey: Key.compressionFormatPresets)
        if let presetsObject = values[Key.compressionFormatPresets],
           JSONSerialization.isValidJSONObject(presetsObject),
           let data = try? JSONSerialization.data(withJSONObject: presetsObject) {
            defaults.set(data, forKey: Key.compressionFormatPresets)
        }
        // #18 工作区预设:同款 JSON 对象 → Data。
        defaults.removeObject(forKey: Key.releaseWorkspacePresets)
        if let workspacesObject = values[Key.releaseWorkspacePresets],
           JSONSerialization.isValidJSONObject(workspacesObject),
           let data = try? JSONSerialization.data(withJSONObject: workspacesObject) {
            defaults.set(data, forKey: Key.releaseWorkspacePresets)
        }
        // 0.4.4 #2 发布账本:同款 JSON 对象 → Data。
        defaults.removeObject(forKey: Key.releaseLedger)
        if let ledgerObject = values[Key.releaseLedger],
           JSONSerialization.isValidJSONObject(ledgerObject),
           let data = try? JSONSerialization.data(withJSONObject: ledgerObject) {
            defaults.set(data, forKey: Key.releaseLedger)
        }
        // AI 后台索引白名单目录(JSON 数组 → Data,同款还原)。
        defaults.removeObject(forKey: Key.aiBackgroundIndexScopes)
        if let scopesObject = values[Key.aiBackgroundIndexScopes],
           JSONSerialization.isValidJSONObject(scopesObject),
           let data = try? JSONSerialization.data(withJSONObject: scopesObject) {
            defaults.set(data, forKey: Key.aiBackgroundIndexScopes)
        }
    }

    /// 把所有可导出 key + 按文件夹记忆全部抹掉 + 顺手把 Keychain 里的预设密码也清掉。
    /// 「全部恢复默认」按钮调；用户应该被警告这是不可逆操作。
    /// 返回 **Keychain 预设密码是否真的清掉了** —— 调用方据此决定提示「已恢复」还是「偏好已清但钥匙串里
    /// 的密码没删掉」(否则会误报成功、把密码留在钥匙串)。UserDefaults 侧的清除不会失败,不参与该返回值。
    @discardableResult
    nonisolated static func restoreAllDefaultsToFactory() -> Bool {
        for key in exportableUserDefaultsKeys + perFolderMemoryKeys {
            defaults.removeObject(forKey: key)
        }
        // #115 默认压缩设置不在白名单里（单独 JSON 处理），恢复默认时也要一并清掉。#18 工作区预设 / #2 发布账本同理。
        defaults.removeObject(forKey: Key.compressionFormatPresets)
        defaults.removeObject(forKey: Key.releaseWorkspacePresets)
        defaults.removeObject(forKey: Key.releaseLedger)
        // AI 后台索引白名单目录(用户配置,恢复出厂应清掉 —— A21)。
        defaults.removeObject(forKey: Key.aiBackgroundIndexScopes)
        // #34 归档清单缓存是派生数据(不在白名单),恢复出厂时一并清掉。缓存已迁文件后端(0.4.5,见
        // ArchiveListingCacheStore)—— 必须清**文件后端**(`clear()`),再顺手抹掉遗留在 standard 的旧 key;
        // 只删 standard 会让含非加密条目名的缓存文件在恢复出厂后残留。
        ArchiveListingCacheStore().clear()
        defaults.removeObject(forKey: Key.archiveListingCache)
        defaults.removeObject(forKey: Key.finderFavoritesDirectoryBookmarkData)
        defaults.removeObject(forKey: Key.finderFavoritesSyncEnabled)
        // `errSecItemNotFound` = 本来就没存过预设密码 → 也算「已清干净」。其它非 0 状态才是真失败。
        let status = PresetPasswordStore.clear()
        return status == errSecSuccess || status == errSecItemNotFound
    }

    nonisolated static func resetStartupLocationToDefault() {
        defaults.set(StartupLocation.home.rawValue, forKey: Key.startupLocation)
        defaults.removeObject(forKey: Key.startupCustomLocationPath)
        defaults.removeObject(forKey: Key.startupCustomLocationHistory)
    }

    /// 给定一个枚举 case，返回它对应的具体 URL（不带「不存在时回落到 home」语义）。
    /// .custom 用当前活跃 custom 路径，.lastFolder 用上次打开的文件夹。
    /// 返回 nil 表示对应的具体路径没配过 / 当前不可解析。
    nonisolated static func resolvedURL(for location: StartupLocation, fileManager: FileManager = .default) -> URL? {
        switch location {
        case .home:
            return fileManager.homeDirectoryForCurrentUser
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        case .movies:
            return fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
        case .music:
            return fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
        case .pictures:
            return fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .lastFolder:
            return lastFolderURL
        case .custom:
            return startupCustomLocationURL
        }
    }

    /// app 启动时校验：当前 startupLocation 是否指向一个不可达目录？
    /// .lastFolder 还没配过（首次启动）不算「失效」—— 静默回落到 home 即可，不打扰用户。
    /// 其它 case 路径配过但消失了 = 失效。
    nonisolated static var startupLocationIsMissing: Bool {
        let location = startupLocation
        switch location {
        case .lastFolder:
            guard let url = lastFolderURL else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        case .custom:
            guard let url = startupCustomLocationURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        default:
            guard let url = resolvedURL(for: location) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// 启动早期（`SimpleZipApp.init()`）调一次：把当前 `appLanguage` 偏好同步写到
    /// `AppleLanguages`，让 AppKit 在构造顶部菜单栏（File / Edit / Window / Help…）和
    /// Quit / Hide / Services 这些 native 项时就拿到正确语言。
    /// 用户在「通用 → 语言」里改值并重启后，下次启动这一步会用新值，菜单栏自然跟随。
    nonisolated static func applyAppleLanguagesOverrideAtLaunch() {
        let language = appLanguage
        if let code = language.appleLanguageCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            // .system 分支：清掉强制覆盖，让 AppKit 回到系统语言。
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    nonisolated static func defaultStartupURL(fileManager: FileManager = .default) -> URL {
        // 各分支统一回落到 home 目录 —— 即便对应系统目录被用户手动删了 / 自定义路径已经
        // 不存在了，app 也要起得来，而不是崩在「没法打开任何位置」。
        let fallback = fileManager.homeDirectoryForCurrentUser
        switch startupLocation {
        case .home:
            return fallback
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fallback
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fallback
        case .documents:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fallback
        case .movies:
            return fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fallback
        case .music:
            return fileManager.urls(for: .musicDirectory, in: .userDomainMask).first ?? fallback
        case .pictures:
            return fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first ?? fallback
        case .lastFolder:
            return lastFolderURL ?? fallback
        case .custom:
            // 自定义路径可能在用户改完之后又被外部删了 / 移走了；找不到时回落而不是报错。
            if let url = startupCustomLocationURL,
               fileManager.fileExists(atPath: url.path) {
                return url
            }
            return fallback
        }
    }

    private nonisolated static func defaultTrueBool(forKey key: String) -> Bool {
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    private nonisolated static func normalizedHiddenSuffixes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalizedHiddenSuffix(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private nonisolated static func rememberRecentFolder(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.recentSidebarPaths) ?? []
        let path = url.standardized.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(8)), forKey: Key.recentSidebarPaths)
    }

    private nonisolated static func urls(forKey key: String) -> [URL] {
        // URL(fileURLWithPath:) without isDirectory: maps to directoryHint:.checkFileSystem on
        // macOS 26 Swift Foundation, which calls lstat() for every path. On network volumes this
        // blocks the main thread (dev9 sample: 2384/2384 samples on lstat via recentSidebarURLs
        // at app-activate). Use .inferFromPath — no filesystem access, infers from trailing slash.
        (defaults.stringArray(forKey: key) ?? []).map { URL(filePath: $0, directoryHint: .inferFromPath) }
    }
}
