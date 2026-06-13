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
            id: "automation.ai", pane: .automation,
            titleKey: "settings.automation.ai.title",
            keywords: ["ai", "assistant", "apple intelligence", "report"], isToggleable: true
        ),
        SettingsCatalogItem(
            id: "automation.allowPresetPassword", pane: .automation,
            titleKey: "settings.automation.allowPresetPassword",
            keywords: ["password", "preset", "automation", "unattended"], isToggleable: true
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
                            keywords: ["backup", "per folder", "memory", "export"], isToggleable: true)
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
        guard #available(macOS 15.0, *) else { return }
        let allowed = AppPreferences.spotlightIndexingEnabled
        Task.detached(priority: .utility) {
            if allowed {
                await performReindex()
            } else {
                await clearIndex()
            }
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async {
        // #73:手动 CSSearchableItem(uniqueIdentifier 编码 pane+锚点),点击 → 深链到设置那一项并高亮。
        let items = SettingsCatalog.items.map { item -> CSSearchableItem in
            makeSpotlightItem(route: .setting(anchorID: item.id, paneRaw: item.pane.rawValue),
                              attributeSet: SettingEntity(item: item).attributeSet)
        }
        let index = CSSearchableIndex.default()
        do {
            try? await index.deleteAppEntities(ofType: SettingEntity.self)  // #73 迁移:清旧 indexAppEntities 残留
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.setting])
            if !items.isEmpty {
                try await index.indexSearchableItems(items)
            }
        } catch {
            // 索引失败不影响 app。
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
