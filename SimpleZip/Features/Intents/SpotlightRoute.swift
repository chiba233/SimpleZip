//
//  SpotlightRoute.swift
//  SimpleZip
//
//  0.4.4 #73:Spotlight 结果**点击跳转**的统一路由。
//
//  之前用 `indexAppEntities` + `OpenIntent` 自动触发 —— 结果能显示,但 macOS 上点击不可靠地不调起 OpenIntent
//  (用户实测:设置项 / 活动中心任务 / 发布包 / 归档 / 单文件 全都跳不过去)。改成**自己掌控**的经典做法:
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

    /// 字段分隔符:SOH(U+0001),正常路径 / id 里不会出现。
    private static let sep = "\u{1}"

    enum Domain {
        static let setting = "com.simplezip.spotlight.setting"
        static let task = "com.simplezip.spotlight.task"
        static let release = "com.simplezip.spotlight.release"
        static let archive = "com.simplezip.spotlight.archive"
        static let file = "com.simplezip.spotlight.file"
        static let all = [setting, task, release, archive, file]
    }

    var domain: String {
        switch self {
        case .setting: return Domain.setting
        case .task: return Domain.task
        case .release: return Domain.release
        case .archive: return Domain.archive
        case .archiveFile: return Domain.file
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
        case "file" where parts.count == 3:
            return .archiveFile(archivePath: parts[1], entryPath: parts[2])
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
        }
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
        // 冷启动:窗口 / SettingsOpenerBridge 可能还没就绪 —— 延一拍再跳。
        DispatchQueue.main.async { route.perform() }
    }
}
