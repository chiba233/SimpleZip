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
        )
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
        let entities = SettingsCatalog.items.map(SettingEntity.init(item:))
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: SettingEntity.self)
            if !entities.isEmpty {
                try await index.indexAppEntities(entities)
            }
        } catch {
            // 索引失败不影响 app。
        }
    }

    @available(macOS 15.0, *)
    private static func clearIndex() async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(ofType: SettingEntity.self)
        } catch {
            // 清索引失败不影响 app。
        }
    }
}
