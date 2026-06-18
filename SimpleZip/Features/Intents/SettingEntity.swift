//
//  SettingEntity.swift
//  SimpleZip
//
//  0.4.4 #30:把**具体设置项**暴露成 AppEntity + 索引进 Spotlight,让用户在系统 Spotlight 里搜一个设置名
//  (如「Spotlight 索引」「归档内容缓存」)就能直接跳到设置里那一项并高亮(走 #29 的深链 + 滚动定位基建)。
//
//  数据源 = `SettingsCatalog`(纯静态目录:锚点 id / 所在 pane / 标题 L10n key / 关键词 / 是否可直接开关)。
//  绝不索引任何设置的「值」—— 只索引设置项的**名字**,方便检索;点开后由用户自己在设置里看 / 改。
//  Spotlight 捐献受 `spotlightIndexingEnabled` gate(同发布包 / 任务 / 归档内容)。
//
//  #31 会复用 `isToggleable` 标记:只有明确标安全的布尔开关才允许 Siri/Spotlight 直接切,绝不放行安全 / 破坏类设置。
//

import AppIntents
import CoreSpotlight
import Foundation

/// 一条「可被搜索 / 跳转」的设置项目录记录。纯数据,无副作用。
nonisolated struct SettingsCatalogItem: Identifiable, Sendable {
    /// 锚点 id —— 同时是 Spotlight / AppEntity 的稳定 id,与 pane 里 `.settingsAnchor(id)` 一致。
    let id: String
    /// 所在设置 pane(点开后深链到这页 + 滚到本项)。
    let pane: SettingsPane
    /// 设置项显示名的 L10n key(索引 / 展示时取当前语言)。
    let titleKey: String
    /// 额外搜索关键词(英文;Spotlight 标题已带本地化名字,这里补常见搜法)。
    let keywords: [String]
    /// #31:能不能经 Siri/Spotlight **直接开关**(只标安全的布尔开关;false = 只能跳转过去自己改)。
    let isToggleable: Bool
}

/// 设置项静态目录。新增可搜设置 = 在 pane 里给该项加 `.settingsAnchor(id)` + 这里补一条(id 对应)。
nonisolated enum SettingsCatalog {
    static let items: [SettingsCatalogItem] = [
        SettingsCatalogItem(
            id: "automation.spotlight", pane: .automation,
            titleKey: "settings.automation.spotlight.title",
            keywords: ["spotlight", "index", "indexing", "search"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "automation.cache", pane: .automation,
            titleKey: "settings.automation.cache.enabled.title",
            keywords: ["cache", "archive contents", "remember", "search"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "automation.ai", pane: .ai,
            titleKey: "settings.automation.ai.title",
            keywords: ["ai", "assistant", "apple intelligence", "report"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "automation.allowPresetPassword", pane: .automation,
            titleKey: "settings.automation.allowPresetPassword",
            // 安全相关:控制「无人值守自动化可用预设密码」—— 一句话 / 语音 / Shortcuts 翻转它 = 两步提权
            // (先开它 → 再跑解压 intent 用预设密码解加密包)。与删除确认 / 可疑路径 / GPG 一致,**只 UI 手动改**,
            // 绝不进可经 NL/自动化翻转的白名单(`isToggleable:false` → 三个翻转面都拿不到 accessor)。
            keywords: ["password", "preset", "automation", "unattended"], isToggleable: false
        ),
        // 通用
        SettingsCatalogItem(
            id: "general.rememberLastFolder", pane: .general,
            titleKey: "settings.rememberLastFolder",
            keywords: ["startup", "last folder", "remember"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "general.confirmDelete", pane: .general,
            titleKey: "settings.confirmBeforeDeletingFiles",
            // 安全确认开关 —— 可搜索 / 可跳转,但**不**允许 Siri/Spotlight 直接关(关掉降低安全,红线)。
            keywords: ["delete", "confirm", "trash"], isToggleable: false
        ),
        SettingsCatalogItem(
            id: "general.autoExtract", pane: .general,
            titleKey: "settings.finderOpenAutoExtract",
            keywords: ["finder", "auto extract", "open", "unzip"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "general.newTab", pane: .general,
            titleKey: "settings.openExternalInNewTab",
            keywords: ["new tab", "open", "window"], isToggleable: true
        ),
        // #71:记录解压习惯(非敏感行为开关,可经设置搜索/语音切;停录即停学)。
        SettingsCatalogItem(
            id: "general.extractionUsageTracking", pane: .general,
            titleKey: "settings.defaults.extractionUsageTracking",
            keywords: ["extract", "usage", "learn", "habits", "most used"], isToggleable: true
        ),
        // 归档
        SettingsCatalogItem(
            id: "archive.verifyAfterRewrite", pane: .archive,
            titleKey: "settings.verifyAfterRewrite",
            keywords: ["verify", "rewrite", "edit", "integrity"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "archive.verifyAfterCreate", pane: .archive,
            titleKey: "settings.verifyAfterCreate",
            keywords: ["verify", "create", "test", "integrity"], isToggleable: true
        ),
        // 通用(其余)
        SettingsCatalogItem(id: "general.language", pane: .general, titleKey: "settings.language",
                            keywords: ["language", "locale", "interface"], isToggleable: false),
        SettingsCatalogItem(id: "general.startupLocation", pane: .general, titleKey: "settings.startupLocation",
                            keywords: ["startup", "open at launch", "default folder"], isToggleable: false),
        SettingsCatalogItem(id: "general.overwriteBehavior", pane: .general, titleKey: "settings.overwriteBehavior",
                            keywords: ["overwrite", "conflict", "replace", "skip"], isToggleable: false),
        // 安全确认 / 预设密码:可搜可跳,但不允许 Siri/Spotlight 直接开关(红线)。
        SettingsCatalogItem(id: "general.confirmDelete", pane: .general, titleKey: "settings.confirmBeforeDeletingFiles",
                            keywords: ["delete", "confirm", "trash"], isToggleable: false),
        SettingsCatalogItem(id: "general.presetPassword", pane: .general, titleKey: "settings.presetPasswordEnabled",
                            keywords: ["preset password", "keychain", "default password"], isToggleable: false),
        // 归档(其余):安全策略(picker,不可直接切)+ 压缩使用统计(可切)。
        SettingsCatalogItem(id: "archive.suspiciousPaths", pane: .archive, titleKey: "settings.security.suspiciousPaths",
                            keywords: ["suspicious paths", "path traversal", "security"], isToggleable: false),
        SettingsCatalogItem(id: "archive.symbolicLinks", pane: .archive, titleKey: "settings.security.symbolicLinks",
                            keywords: ["symbolic links", "symlink", "security"], isToggleable: false),
        SettingsCatalogItem(id: "archive.activeContent", pane: .archive, titleKey: "settings.security.activeContent",
                            keywords: ["active content", "executable", "app bundle", "security"], isToggleable: false),
        SettingsCatalogItem(id: "archive.compressionUsageTracking", pane: .archive, titleKey: "settings.defaults.usageTracking",
                            keywords: ["compression", "usage", "learn", "most used"], isToggleable: true),
        // 浏览器
        SettingsCatalogItem(id: "browser.showHidden", pane: .browser, titleKey: "settings.showHiddenFiles",
                            keywords: ["hidden files", "dotfiles", "show hidden"], isToggleable: true),
        SettingsCatalogItem(id: "browser.hiddenDetection", pane: .browser, titleKey: "settings.hiddenDetection",
                            keywords: ["hidden detection", "dotfile", "uf_hidden"], isToggleable: false),
        SettingsCatalogItem(id: "browser.showSymlinks", pane: .browser, titleKey: "settings.showSymbolicLinks",
                            keywords: ["symbolic links", "symlink", "show"], isToggleable: true),
        SettingsCatalogItem(id: "browser.followFinder", pane: .browser, titleKey: "settings.followFinderStructure",
                            keywords: ["finder", "structure", "follow"], isToggleable: true),
        // 视图(列 / 密度 / 分组 / 展开)
        SettingsCatalogItem(id: "view.rowDensity", pane: .view, titleKey: "settings.rowDensity",
                            keywords: ["row density", "compact", "spacing"], isToggleable: false),
        SettingsCatalogItem(id: "view.hiddenGroupCollapse", pane: .view, titleKey: "settings.hiddenGroupCollapse",
                            keywords: ["hidden group", "collapse"], isToggleable: false),
        SettingsCatalogItem(id: "view.hiddenWithGrouping", pane: .view, titleKey: "settings.hiddenWithGrouping",
                            keywords: ["hidden", "grouping", "separate", "inline"], isToggleable: false),
        SettingsCatalogItem(id: "view.folderInlineExpansion", pane: .view, titleKey: "settings.folderInlineExpansion",
                            keywords: ["folder", "inline", "expand"], isToggleable: true),
        SettingsCatalogItem(id: "view.rememberFolderExpansion", pane: .view, titleKey: "settings.rememberFolderExpansion",
                            keywords: ["remember", "folder", "expansion"], isToggleable: true),
        SettingsCatalogItem(id: "view.rememberVolumeSetExpansion", pane: .view, titleKey: "settings.rememberVolumeSetExpansion",
                            keywords: ["remember", "volume set", "expansion", "split"], isToggleable: true),
        // 两块列开关折叠组(关键词带上各列名,搜「size column」「crc 列」能命中并跳到该组)。
        SettingsCatalogItem(id: "view.fileColumns", pane: .view, titleKey: "settings.columns.fileBrowser",
                            keywords: ["columns", "size", "kind", "application", "date added", "modified",
                                       "created", "permissions", "owner", "last opened"], isToggleable: false),
        SettingsCatalogItem(id: "view.archiveColumns", pane: .view, titleKey: "settings.columns.archiveBrowser",
                            keywords: ["columns", "size", "kind", "path", "packed size", "method", "crc",
                                       "attributes", "encrypted", "host os", "comment", "characteristics"], isToggleable: false),
        // GPG 主开关(可搜可跳,但不允许 Siri 直接切 —— 启用加密子系统,红线)。
        SettingsCatalogItem(id: "gpg.enabled", pane: .gpg, titleKey: "settings.gpg.enabledTitle",
                            keywords: ["gpg", "pgp", "signing", "encryption"], isToggleable: false),
        // 软件更新
        SettingsCatalogItem(id: "updates.checkOnLaunch", pane: .updates, titleKey: "settings.checkForUpdatesOnLaunch",
                            keywords: ["updates", "check", "launch"], isToggleable: true),
        SettingsCatalogItem(id: "updates.autoDownload", pane: .updates, titleKey: "updates.autoDownload",
                            keywords: ["updates", "auto download", "automatic"], isToggleable: true),
        // 备份
        SettingsCatalogItem(id: "backup.includePerFolderMemory", pane: .backup, titleKey: "backup.includePerFolderMemory",
                            keywords: ["backup", "per folder", "memory", "export"], isToggleable: true),
        // 0.4.4 #31 扩充:补齐此前漏掉的设置项,让「几乎全部选项」都能在 Spotlight 搜到 + 跳转定位
        // (避免「中途半端」让用户不信任)。视图:分组 / 隐藏后缀。
        SettingsCatalogItem(id: "view.grouping", pane: .view, titleKey: "settings.grouping.groupBy",
                            keywords: ["grouping", "group by", "sort into groups", "per folder"], isToggleable: false),
        SettingsCatalogItem(id: "view.hiddenSuffixes", pane: .view, titleKey: "settings.hiddenSuffixesEnabled",
                            keywords: ["hidden suffixes", "hide extension", "hidden extensions", "suffix"], isToggleable: true),
        // 归档:压缩默认值 + 后端引擎(picker,只跳转)。
        SettingsCatalogItem(id: "archive.compressionDefaults", pane: .archive, titleKey: "settings.defaults.title",
                            keywords: ["compression defaults", "format defaults", "default level", "presets"], isToggleable: false),
        SettingsCatalogItem(id: "archive.sevenZipBackend", pane: .archive, titleKey: "settings.7zip.backend",
                            keywords: ["7-zip backend", "7zip", "p7zip", "engine", "backend"], isToggleable: false),
        SettingsCatalogItem(id: "archive.rarBackend", pane: .archive, titleKey: "settings.rar.backend",
                            keywords: ["rar backend", "unrar", "rar engine", "backend"], isToggleable: false),
        // GPG:签名策略 + 智能卡(安全子系统,只跳转不直接切)。
        SettingsCatalogItem(id: "gpg.signing", pane: .gpg, titleKey: "settings.gpg.defaults.signingStrategy.label",
                            keywords: ["signing key", "signing strategy", "default signing", "sign"], isToggleable: false),
        SettingsCatalogItem(id: "gpg.smartcard", pane: .gpg, titleKey: "settings.gpg.smartcard.enableTitle",
                            keywords: ["smartcard", "smart card", "yubikey", "openpgp card", "hardware key", "token"], isToggleable: false),
        // 自动化:命令行工具 / 快捷指令 / 发布路径健康。
        SettingsCatalogItem(id: "automation.cli", pane: .automation, titleKey: "settings.cli.title",
                            keywords: ["command line", "cli", "terminal", "simplezip command", "install command line tool"], isToggleable: false),
        SettingsCatalogItem(id: "automation.shortcuts", pane: .automation, titleKey: "settings.automation.shortcuts.title",
                            keywords: ["shortcuts", "siri", "automation actions", "shortcut"], isToggleable: false),
        SettingsCatalogItem(id: "automation.pathHealth", pane: .automation, titleKey: "settings.automation.pathHealth.title",
                            keywords: ["path health", "release paths", "missing folders", "saved paths"], isToggleable: false),
        // 文件关联 / 健康 / 备份(动作区:可搜可跳,非开关)。
        SettingsCatalogItem(id: "fileAssociations", pane: .fileAssociations, titleKey: "settings.section.fileAssociations",
                            keywords: ["file associations", "default app", "open with", "set default", "default application"], isToggleable: false),
        SettingsCatalogItem(id: "health", pane: .health, titleKey: "settings.section.health",
                            keywords: ["health check", "diagnostics", "environment", "backend status", "temp files"], isToggleable: false),
        SettingsCatalogItem(id: "backup.export", pane: .backup, titleKey: "backup.export.title",
                            keywords: ["export settings", "backup settings", "import settings", "transfer settings"], isToggleable: false),
        SettingsCatalogItem(id: "backup.factoryReset", pane: .backup, titleKey: "backup.restore.title",
                            keywords: ["factory reset", "restore defaults", "reset settings", "erase settings"], isToggleable: false)
    ]

    static func item(id: String) -> SettingsCatalogItem? {
        items.first { $0.id == id }
    }
}

/// 一个设置项实体(id = 目录里的锚点 id)。
struct SettingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Setting")
    static let defaultQuery = SettingQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    /// 所在 pane 的 rawValue —— 打开时还原成 SettingsPane 深链。不作 @Property 暴露。
    let paneRaw: String
    let keywords: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(SettingsPane(rawValue: paneRaw)?.title ?? "")",
            image: .init(systemName: "gearshape")
        )
    }

    init(item: SettingsCatalogItem) {
        id = item.id
        paneRaw = item.pane.rawValue
        keywords = item.keywords
        name = L10n.text(item.titleKey)
    }
}

struct SettingQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SettingEntity] {
        identifiers.compactMap { SettingsCatalog.item(id: $0).map(SettingEntity.init(item:)) }
    }

    func suggestedEntities() async throws -> [SettingEntity] {
        SettingsCatalog.items.map(SettingEntity.init(item:))
    }
}

// MARK: - 打开设置项(OpenIntent:点 Spotlight 结果 → 深链到设置那一项并高亮)

/// 点 Spotlight 里搜到的设置项 → 打开设置窗口、切到它所在 pane、滚到这一项并闪一圈(#29 基建)。
struct OpenSettingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Setting in SimpleZip"

    @Parameter(title: "Setting")
    var target: SettingEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let pane = SettingsPane(rawValue: target.paneRaw) {
            SettingsDeepLink.open(pane, anchor: target.id)
        }
        return .result()
    }
}

// MARK: - Spotlight 语义索引(macOS 15+)

@available(macOS 15.0, *)
extension SettingEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = name
        set.displayName = name
        if let paneTitle = SettingsPane(rawValue: paneRaw)?.title {
            set.contentDescription = L10n.format("spotlight.setting.in", paneTitle)
        }
        set.keywords = ["SimpleZip", "Settings"] + keywords
        return set
    }
}

/// 把设置项目录同步进 Spotlight。受 `spotlightIndexingEnabled` gate;旧系统 no-op;失败静默。
/// 目录是静态的 —— 启动重建一次即可;开关切换时也调(关 → 清空)。
nonisolated enum SettingsSpotlightIndexer {
    static func reindex() {
        Task.detached(priority: .utility) {
            guard #available(macOS 15.0, *) else { return }
            await reindexIfNeeded()
        }
    }

    /// 串行协调器调用。设置目录是**静态**的(代码生成)→ 指纹 = app 版本,**版本没变就跳过**(启动卡顿修复)。
    @available(macOS 15.0, *)
    static func reindexIfNeeded() async {
        let key = "settings"
        guard AppPreferences.spotlightIndexingEnabled else {
            await clearIndex()
            SpotlightReindexGuard.reset(key: key)
            return
        }
        let fp = SpotlightReindexGuard.appVersionFingerprint
        guard !SpotlightReindexGuard.isUpToDate(key: key, fingerprint: fp) else { return }
        if await performReindex() {
            SpotlightReindexGuard.markIndexed(key: key, fingerprint: fp)
        }
    }

    /// DevTools 全量 dump 用:返回当前会捐献的全部设置条目(与 performReindex 同源)。
    @available(macOS 15.0, *)
    static func dumpItems() -> [CSSearchableItem] {
        SettingsCatalog.items.map { item in
            makeSpotlightItem(route: .setting(anchorID: item.id, paneRaw: item.pane.rawValue),
                              attributeSet: SettingEntity(item: item).attributeSet)
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async -> Bool {
        // #73:手动 CSSearchableItem(uniqueIdentifier 编码 pane+锚点),点击 → 深链到设置那一项并高亮。
        let items = dumpItems()
        let index = CSSearchableIndex.default()
        do {
            try? await index.deleteAppEntities(ofType: SettingEntity.self)  // #73 迁移:清旧 indexAppEntities 残留
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.setting])
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
            return true
        } catch {
            return false   // 索引失败不影响 app;不记指纹,下轮重试。
        }
    }

    @available(macOS 15.0, *)
    private static func clearIndex() async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.setting])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}

// MARK: - #31:经 Siri/Spotlight 无 UI 直接开关安全布尔设置

/// 切换动作:开 / 关 / 翻转。`.toggle` 是默认值 —— 用户只说设置名时翻转当前值。
enum SettingToggleState: String, AppEnum {
    case on
    case off
    case toggle

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Setting State")
    static let caseDisplayRepresentations: [SettingToggleState: DisplayRepresentation] = [
        .on: "Turn On",
        .off: "Turn Off",
        .toggle: "Toggle"
    ]
}

/// **只暴露可安全直接开关**的设置项实体(`SettingsCatalog` 里 `isToggleable == true` 的子集)。
/// 与索引用的 `SettingEntity`(全量、用于「搜+跳转」)刻意分开:`ChangeSettingIntent` 的参数只认这个类型,
/// 所以 Siri / Shortcuts 的参数选择面**根本不会**列出安全 / 破坏类设置(确认删除 / GPG 启用 / 预设密码 /
/// 路径策略),从源头杜绝语音改到危险开关(红线)。`init?` 对非 toggleable 项直接返回 nil,是第二道闸。
struct ToggleableSettingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Setting")
    static let defaultQuery = ToggleableSettingQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    let paneRaw: String
    let keywords: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(SettingsPane(rawValue: paneRaw)?.title ?? "")",
            image: .init(systemName: "switch.2")
        )
    }

    /// 非 toggleable 的目录项不构成实体 —— 把白名单约束焊死在类型里。
    init?(item: SettingsCatalogItem) {
        guard item.isToggleable else { return nil }
        id = item.id
        paneRaw = item.pane.rawValue
        keywords = item.keywords
        name = L10n.text(item.titleKey)
    }
}

struct ToggleableSettingQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ToggleableSettingEntity] {
        identifiers.compactMap { SettingsCatalog.item(id: $0).flatMap(ToggleableSettingEntity.init(item:)) }
    }

    func suggestedEntities() async throws -> [ToggleableSettingEntity] {
        SettingsCatalog.items.compactMap(ToggleableSettingEntity.init(item:))
    }
}

/// 把一个可开关设置项的 id 映射到它的**读 / 写访问器**,并附带该设置必要的副作用(与设置面板里的
/// `.onChange` 同口径:Spotlight 捐献维护 / 浏览器刷新 / Sparkle)。
///
/// 安全护栏:`accessor(for:)` 先核对目录项确实 `isToggleable`,任何非白名单 id 一律返回 nil ——
/// 加上 `ToggleableSettingEntity.init?` 与 `ChangeSettingIntent.perform` 里的复核,共三道闸。
/// 这里**绝不**出现确认删除 / GPG 启用 / 预设密码 / 路径安全策略等设置(它们在目录里就是 `isToggleable: false`)。
///
/// 写入直接落 `UserDefaults.standard`(= `AppPreferences` 与 `@AppStorage` 共用的存储),所以正在打开的
/// 设置页会经 `@AppStorage` 的 KVO 实时跟随;值本身则在下次被读到时生效。
@MainActor
enum SettingToggleRegistry {
    struct Accessor {
        let get: @MainActor () -> Bool
        let set: @MainActor (Bool) -> Void
    }

    static func accessor(for id: String) -> Accessor? {
        // 第三道闸(运行期):即便 id 不知怎么绕过了实体层,这里也只认目录里 isToggleable 的项。
        guard SettingsCatalog.item(id: id)?.isToggleable == true else { return nil }
        switch id {
        case "automation.spotlight":
            return Accessor(get: { AppPreferences.spotlightIndexingEnabled },
                            set: { setBool($0, AppPreferences.Key.spotlightIndexingEnabled); SpotlightReindex.all() })
        case "automation.cache":
            return Accessor(get: { AppPreferences.archiveListingCacheEnabled },
                            set: {
                                setBool($0, AppPreferences.Key.archiveListingCacheEnabled)
                                if !$0 { ArchiveListingCacheStore().clear() }   // 关 = 立即清缓存(隐私)
                                CachedArchiveSpotlightIndexer.reindex()
                                ArchiveFileSpotlightIndexer.reindex()
                            })
        case "automation.ai":
            return Accessor(get: { AppPreferences.aiAssistantEnabled },
                            set: { setBool($0, AppPreferences.Key.aiAssistantEnabled) })
        // automation.allowPresetPassword 故意**没有** accessor:它是安全相关开关(无人值守用预设密码),
        // 只在设置 UI 手动改,绝不让 NL/语音/Shortcuts 翻转(见 SettingsCatalog 那条的注释)。`isToggleable:false`
        // 已让上面的 guard 拦住,这里不再列 case,双保险。
        case "general.rememberLastFolder":
            return Accessor(get: { AppPreferences.rememberLastFolder },
                            set: { setBool($0, AppPreferences.Key.rememberLastFolder) })
        case "general.autoExtract":
            return Accessor(get: { AppPreferences.finderOpenAutoExtract },
                            set: { setBool($0, AppPreferences.Key.finderOpenAutoExtract) })
        case "general.newTab":
            return Accessor(get: { AppPreferences.openExternalInNewTab },
                            set: { setBool($0, AppPreferences.Key.openExternalInNewTab) })
        case "archive.verifyAfterRewrite":
            return Accessor(get: { AppPreferences.verifyAfterArchiveRewrite },
                            set: { setBool($0, AppPreferences.Key.verifyAfterArchiveRewrite) })
        case "archive.verifyAfterCreate":
            return Accessor(get: { AppPreferences.verifyAfterArchiveCreate },
                            set: { setBool($0, AppPreferences.Key.verifyAfterArchiveCreate) })
        case "archive.compressionUsageTracking":
            return Accessor(get: { AppPreferences.compressionUsageTrackingEnabled },
                            set: { setBool($0, AppPreferences.Key.compressionUsageTrackingEnabled) })
        case "general.extractionUsageTracking":
            return Accessor(get: { AppPreferences.extractionUsageTrackingEnabled },
                            set: { setBool($0, AppPreferences.Key.extractionUsageTrackingEnabled) })
        case "browser.showHidden":
            return Accessor(get: { AppPreferences.showHiddenFiles },
                            set: { setBool($0, AppPreferences.Key.showHiddenFiles); notifyBrowser() })
        case "browser.showSymlinks":
            return Accessor(get: { AppPreferences.showSymbolicLinks },
                            set: { setBool($0, AppPreferences.Key.showSymbolicLinks); notifyBrowser() })
        case "browser.followFinder":
            return Accessor(get: { AppPreferences.followFinderStructure },
                            set: { setBool($0, AppPreferences.Key.followFinderStructure); notifyBrowser() })
        case "view.folderInlineExpansion":
            return Accessor(get: { AppPreferences.folderInlineExpansion },
                            set: { setBool($0, AppPreferences.Key.folderInlineExpansion); notifyBrowser() })
        case "view.rememberFolderExpansion":
            return Accessor(get: { AppPreferences.rememberFolderExpansion },
                            set: { setBool($0, AppPreferences.Key.rememberFolderExpansion); notifyBrowser() })
        case "view.rememberVolumeSetExpansion":
            return Accessor(get: { AppPreferences.rememberVolumeSetExpansion },
                            set: { setBool($0, AppPreferences.Key.rememberVolumeSetExpansion); notifyBrowser() })
        case "view.hiddenSuffixes":
            return Accessor(get: { AppPreferences.hiddenSuffixesEnabled },
                            set: { setBool($0, AppPreferences.Key.hiddenSuffixesEnabled); notifyBrowser() })
        case "updates.checkOnLaunch":
            return Accessor(get: { AppPreferences.checkForUpdatesOnLaunch },
                            set: { setBool($0, AppPreferences.Key.checkForUpdatesOnLaunch) })
        case "updates.autoDownload":
            // 真值在 Sparkle 里(它自行持久化)—— 走 SparkleUpdater 的薄壳,本层不碰 Sparkle 类型。
            return Accessor(get: { SparkleUpdater.shared.automaticallyDownloadsUpdates },
                            set: { SparkleUpdater.shared.automaticallyDownloadsUpdates = $0 })
        case "backup.includePerFolderMemory":
            return Accessor(get: { AppPreferences.includePerFolderMemoryInBackup },
                            set: { setBool($0, AppPreferences.Key.includePerFolderMemoryInBackup) })
        default:
            return nil
        }
    }

    private static func setBool(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 与设置面板 `notifyBrowserRefresh()` 同口径:让正在浏览的文件 / 归档列表按新偏好重新呈现。
    private static func notifyBrowser() {
        NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
    }
}
