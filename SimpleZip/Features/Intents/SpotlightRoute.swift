//
//  SpotlightRoute.swift
//  SimpleZip
//
//  0.4.4 #73:Spotlight 结果**点击跳转**的统一路由。
//
//  之前用 `indexAppEntities` + `OpenIntent` 自动触发 —— 结果能显示,但 macOS 上点击不可靠地不调起 OpenIntent
//  (分析确认:设置项 / 活动中心任务 / 发布包 / 归档 / 单文件 全都跳不过去)。改成**自己掌控**的经典做法:
//  手动 `CSSearchableItem`(uniqueIdentifier 由本类型编码,我说了算)+ 在 AppDelegate 里处理
//  `CSSearchableItemActionType` 续期活动 → 解出 identifier → `perform()` 执行跳转。
//
//  AppEntity / EntityQuery / OpenIntent 仍保留给 Shortcuts / Siri(它们走 EntityQuery,不依赖这条索引)。
//

import AppKit
import CoreSpotlight
import Foundation

/// 一条可被 Spotlight 索引 + 点击跳转的目标。`identifier` 编码进 CSSearchableItem 的 uniqueIdentifier,
/// 点击时从续期活动里解回来再 `perform()`。`domain` 用于按类型批量删除索引。
nonisolated enum SpotlightRoute {
    case setting(anchorID: String, paneRaw: String)
    case task(id: UUID, categoryRaw: String)
    case release(artifactPath: String)
    case archive(archivePath: String)
    case archiveFile(archivePath: String, entryPath: String)
    /// #31:活动中心(独立窗口,非设置窗口)里的「设置 / 临时工作区」选项。`paneRouteKey` 决定跳哪页,
    /// `itemID` 仅保证同页多项的 uniqueIdentifier 各不相同(否则 Spotlight 会把同 id 的多条去重成一条)。
    case activity(paneRouteKey: String, itemID: String)

    /// 字段分隔符:SOH(U+0001),正常路径 / id 里不会出现。
    private static let sep = "\u{1}"

    enum Domain {
        static let setting = "com.simplezip.spotlight.setting"
        static let task = "com.simplezip.spotlight.task"
        static let release = "com.simplezip.spotlight.release"
        static let archive = "com.simplezip.spotlight.archive"
        static let file = "com.simplezip.spotlight.file"
        static let activity = "com.simplezip.spotlight.activity"
        static let all = [setting, task, release, archive, file, activity]
    }

    var domain: String {
        switch self {
        case .setting: return Domain.setting
        case .task: return Domain.task
        case .release: return Domain.release
        case .archive: return Domain.archive
        case .archiveFile: return Domain.file
        case .activity: return Domain.activity
        }
    }

    var identifier: String {
        let s = Self.sep
        switch self {
        case .setting(let anchor, let pane): return "setting\(s)\(pane)\(s)\(anchor)"
        case .task(let id, let category): return "task\(s)\(category)\(s)\(id.uuidString)"
        case .release(let path): return "release\(s)\(path)"
        case .archive(let path): return "archive\(s)\(path)"
        case .archiveFile(let archivePath, let entryPath): return "file\(s)\(archivePath)\(s)\(entryPath)"
        case .activity(let paneRouteKey, let itemID): return "activity\(s)\(paneRouteKey)\(s)\(itemID)"
        }
    }

    static func decode(_ identifier: String) -> SpotlightRoute? {
        let parts = identifier.components(separatedBy: sep)
        guard let tag = parts.first else { return nil }
        switch tag {
        case "setting" where parts.count == 3:
            return .setting(anchorID: parts[2], paneRaw: parts[1])
        case "task" where parts.count == 3:
            guard let id = UUID(uuidString: parts[2]) else { return nil }
            return .task(id: id, categoryRaw: parts[1])
        case "release" where parts.count == 2:
            return .release(artifactPath: parts[1])
        case "archive" where parts.count == 2:
            return .archive(archivePath: parts[1])
        case "file" where parts.count >= 3:
            // entryPath 是不可信归档条目名,可能含分隔符 \u{1};它是最后一段 → 取 parts[2...] 拼回原样,
            // archivePath(parts[1])是磁盘路径不含分隔符。整段等 count==3 会让含控制字符的条目路由失败。
            return .archiveFile(archivePath: parts[1], entryPath: parts[2...].joined(separator: sep))
        case "activity" where parts.count == 3:
            return .activity(paneRouteKey: parts[1], itemID: parts[2])
        default:
            return nil
        }
    }

    /// 执行跳转。由 AppDelegate 在收到 Spotlight 点击续期活动时调(已切到主线程、app 已激活)。
    @MainActor
    func perform() {
        switch self {
        case .setting(let anchor, let paneRaw):
            guard let pane = SettingsPane(rawValue: paneRaw) else { return }
            SettingsDeepLink.open(pane, anchor: anchor)
        case .task(let id, let categoryRaw):
            ActivityWindowController.shared.show(category: OperationTask.Category(rawValue: categoryRaw), locateTaskID: id)
        case .release(let artifactPath):
            let url = URL(fileURLWithPath: artifactPath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        case .archive(let archivePath):
            let url = URL(fileURLWithPath: archivePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            AppDelegate.openExternalArchive(url)
        case .archiveFile(let archivePath, let entryPath):
            let url = URL(fileURLWithPath: archivePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if AppPreferences.finderOpenAutoExtract {
                Task { try? await ArchiveSingleFileExtractor.extractAndReveal(archiveURL: url, entryPath: entryPath) }
            } else {
                AppDelegate.openExternalArchive(url, revealEntryPath: entryPath)
            }
        case .activity(let paneRouteKey, _):
            // 打开活动中心(独立窗口)并切到对应分页 —— settings / workspace 都短,展示在该页即可见。
            guard let pane = ActivityPane.pane(spotlightRouteKey: paneRouteKey) else { return }
            ActivityWindowController.shared.show(pane: pane)
        }
    }
}

/// 统一触发全部 5 类 Spotlight 索引(启动 / 设置「强制重新索引」用)+ 统计。
@MainActor
enum SpotlightReindex {
    struct Stats: Sendable {
        let releases: Int
        let tasks: Int
        let archives: Int
        let archiveFiles: Int
        let settings: Int
        var total: Int { releases + tasks + archives + archiveFiles + settings }
    }

    /// 各类各自重建(内部按门控分支:开→建、关→清)。启动、设置开关变动调它。
    static func all() {
        ReleasePackageSpotlightIndexer.reindex()
        ArchiveTaskSpotlightIndexer.reindex()
        CachedArchiveSpotlightIndexer.reindex()
        ArchiveFileSpotlightIndexer.reindex()
        SettingsSpotlightIndexer.reindex()
        ActivitySpotlightIndexer.reindex()
    }

    /// 强制:先把本 app 在 Spotlight 的**全部**捐献清掉(新旧两种、所有类型一次清干净),再全量重建。
    /// 给「索引不全 / 不稳定」时用户手动兜底。
    static func force() {
        guard #available(macOS 15.0, *) else { return }
        Task.detached(priority: .utility) {
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            await MainActor.run { all() }
        }
    }

    /// 当前**会被索引**的条目数(展示用 —— 实际进系统索引是异步的,这是上界估计)。
    nonisolated static func stats() -> Stats {
        let cache = ArchiveListingCacheStore().loadAll()
        let files = cache.reduce(0) { $0 + min($1.fileEntryCount, ArchiveFileSpotlightIndexer.perArchiveLimit) }
        return Stats(
            releases: ReleaseLedgerStore().loadAll().count,
            tasks: ActivityHistoryStore.snapshot().count,
            archives: cache.count,
            archiveFiles: files,
            // 设置项 + 活动中心(设置 / 临时工作区)条目 —— 都归「设置」这一档展示。
            settings: SettingsCatalog.items.count + ActivitySpotlightCatalog.items.count
        )
    }

    /// DevTools 全量 dump:**每一条**会捐献的 Spotlight item 的可读快照(各 indexer `dumpItems()` 汇总,不门控、与索引同源)。
    /// 读 attributeSet 的关键字段 —— 给开发者看「到底进了什么」。隐藏调试区,含完整真实标识 / 标题 / 关键字。
    @available(macOS 15.0, *)
    static func dumpAllItems() -> [IndexedItemDump] {
        let groups: [(String, [CSSearchableItem])] = [
            ("release", ReleasePackageSpotlightIndexer.dumpItems()),
            ("task", ArchiveTaskSpotlightIndexer.dumpItems()),
            ("archive", CachedArchiveSpotlightIndexer.dumpItems()),
            ("archiveFile", ArchiveFileSpotlightIndexer.dumpItems()),
            ("setting", SettingsSpotlightIndexer.dumpItems()),
            ("activity", ActivitySpotlightIndexer.dumpItems())
        ]
        return groups.flatMap { domainLabel, items in
            items.map { item -> IndexedItemDump in
                let a = item.attributeSet
                return IndexedItemDump(
                    domainLabel: domainLabel,
                    domainIdentifier: item.domainIdentifier,
                    uniqueIdentifier: item.uniqueIdentifier,
                    title: a.title,
                    displayName: a.displayName,
                    contentDescription: a.contentDescription,
                    keywords: a.keywords,
                    path: a.path ?? a.contentURL?.path
                )
            }
        }
    }

    /// dump 出来的单条 Spotlight item 可读快照(给 DevTools 复制 JSON)。
    nonisolated struct IndexedItemDump: Encodable, Sendable {
        let domainLabel: String
        let domainIdentifier: String?
        let uniqueIdentifier: String
        let title: String?
        let displayName: String?
        let contentDescription: String?
        let keywords: [String]?
        let path: String?
    }
}

/// 把一个路由 + 属性集打成手动 CSSearchableItem(uniqueIdentifier 我说了算,点击能解回来)。
/// CSSearchableItem 本身是老 API,不需门控;`attributeSet` 由调用方(macOS 15 索引上下文)构造。
nonisolated func makeSpotlightItem(route: SpotlightRoute, attributeSet: CSSearchableItemAttributeSet) -> CSSearchableItem {
    CSSearchableItem(uniqueIdentifier: route.identifier, domainIdentifier: route.domain, attributeSet: attributeSet)
}

/// Spotlight 点击的统一入口 —— AppDelegate `continue:` 与 ContentView `.onContinueUserActivity` 都调它(双保险:
/// SwiftUI app 的续期活动有时走 AppDelegate、有时走场景)。带 1.5s 去重,避免两路都触发时跳两次。
@MainActor
enum SpotlightTapDispatcher {
    private static var lastIdentifier: String?
    private static var lastTime = Date.distantPast

    /// 从续期活动里取出 uniqueIdentifier 并路由(非 Spotlight 活动 / 解不出路由 → 忽略)。
    static func handle(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        handle(identifier: identifier)
    }

    static func handle(identifier: String) {
        guard let route = SpotlightRoute.decode(identifier) else { return }
        let now = Date()
        if identifier == lastIdentifier, now.timeIntervalSince(lastTime) < 1.5 { return }
        lastIdentifier = identifier
        lastTime = now
        NSApp.activate(ignoringOtherApps: true)
        // 冷启动:窗口可能还没就绪 —— 延一拍再跳(SettingsWindowController.show 会按需建窗,深链照样落地)。
        DispatchQueue.main.async { route.perform() }
    }
}

// MARK: - #31:活动中心(独立窗口)的「设置 / 临时工作区」选项进 Spotlight

/// 活动中心是独立窗口、不在设置窗口里,所以它的设置 / 临时工作区选项之前完全没进 Spotlight。
/// 这里把它们也捐出去:搜得到、点了跳进活动中心对应分页(走 `ActivityWindowController`,非 `SettingsDeepLink`)。
nonisolated struct ActivitySpotlightItem: Sendable {
    /// 跳哪页:"settings" / "workspace"(对应 `ActivityPane`)。
    let paneRouteKey: String
    /// 稳定后缀,拼进 uniqueIdentifier 保证同页多项各不相同。
    let itemID: String
    /// 显示名的 L10n key(复用活动中心里那一行的标题)。
    let titleKey: String
    let keywords: [String]
}

nonisolated enum ActivitySpotlightCatalog {
    static let items: [ActivitySpotlightItem] = [
        // 活动中心 → 设置
        ActivitySpotlightItem(paneRouteKey: "settings", itemID: "activity.concurrency",
                              titleKey: "settings.tasks.concurrencyLimit",
                              keywords: ["activity center", "concurrency", "parallel tasks", "queue limit", "simultaneous tasks"]),
        ActivitySpotlightItem(paneRouteKey: "settings", itemID: "activity.notify",
                              titleKey: "tasks.settings.notify",
                              keywords: ["activity center", "notification", "notify", "long tasks", "task finished"]),
        ActivitySpotlightItem(paneRouteKey: "settings", itemID: "activity.playSound",
                              titleKey: "tasks.settings.playSound",
                              keywords: ["activity center", "sound", "chime", "finished sound"]),
        ActivitySpotlightItem(paneRouteKey: "settings", itemID: "activity.openOnFailure",
                              titleKey: "tasks.settings.openOnFailure",
                              keywords: ["activity center", "open on failure", "failed task", "pop up"]),
        // 活动中心 → 临时工作区
        ActivitySpotlightItem(paneRouteKey: "workspace", itemID: "activity.workspace",
                              titleKey: "tasks.workspaceSection",
                              keywords: ["temporary workspace", "scratch", "temp files", "clean up"]),
        ActivitySpotlightItem(paneRouteKey: "workspace", itemID: "activity.workspace.volume",
                              titleKey: "workspace.volume.title",
                              keywords: ["encrypted scratch volume", "secure temp", "scratch volume", "mounted"]),
        ActivitySpotlightItem(paneRouteKey: "workspace", itemID: "activity.workspace.artifacts",
                              titleKey: "workspace.artifacts.title",
                              keywords: ["temporary artifacts", "temp files", "clean up", "disk usage"])
    ]
}

/// 把活动中心的设置 / 临时工作区选项捐进 Spotlight。受同一把 `spotlightIndexingEnabled` 总开关管;
/// 旧系统 no-op;失败静默。目录静态 —— 启动 / 开关切换时重建即可。
@MainActor
enum ActivitySpotlightIndexer {
    static func reindex() {
        Task.detached(priority: .utility) {
            guard #available(macOS 15.0, *) else { return }
            await reindexIfNeeded()
        }
    }

    /// 串行协调器调用。活动选项目录是**静态**的(代码生成、标题本地化)→ 指纹 = app 版本 + 语言,没变就跳过。
    @available(macOS 15.0, *)
    static func reindexIfNeeded() async {
        let key = "activity"
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

    /// DevTools 全量 dump 用:返回当前会捐献的全部活动选项条目(与 performReindex 同源)。
    @available(macOS 15.0, *)
    static func dumpItems() -> [CSSearchableItem] {
        ActivitySpotlightCatalog.items.map { item in
            let set = CSSearchableItemAttributeSet(contentType: .content)
            let name = L10n.text(item.titleKey)
            set.title = name
            set.displayName = name
            set.contentDescription = L10n.text("spotlight.activity.in")
            set.keywords = ["SimpleZip", "Activity Center"] + item.keywords
            return makeSpotlightItem(route: .activity(paneRouteKey: item.paneRouteKey, itemID: item.itemID),
                                     attributeSet: set)
        }
    }

    @available(macOS 15.0, *)
    private static func performReindex() async -> Bool {
        let items = dumpItems()
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.activity])
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
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightRoute.Domain.activity])
        } catch {
            // 清索引失败不影响 app。
        }
    }
}
