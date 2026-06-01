//
//  AppDelegate.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation
import SwiftUI

/// AppKit 代理：接收 Finder 或“打开方式”传入的文件路径。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApp.applicationIconImage = icon
        }
        NSApp.servicesProvider = self
        // 尽早固化「会话开始时间」—— 手动清理临时文件只删早于此刻的陈旧项，保护本次会话在用的 staging。
        let sessionStart = TemporaryResourceManager.sessionStart
        // 启动时单次清理上次会话残留的「打开压缩包内文件」解压目录（stale-only，只删早于本次会话的）。
        // 之前放在 ArchiveBrowserModel.init 且无条件删整个根目录，多窗口时会误删在用解压目录。
        TemporaryResourceManager.cleanStaleOpenedArchiveItems(olderThan: sessionStart)
        // 「每次启动时检查更新」（通用设置 opt-in）：发现新版才弹提示，已最新则静默。
        SparkleUpdater.shared.checkForUpdatesOnLaunchIfEnabled()

        // #64 冷启动不弹窗修复：app 由「Finder 打开文件」触发启动时，`WindowGroup` 上的
        // `.handlesExternalEvents(matching: [])` 会让 SwiftUI 拒绝创建初始窗口（点 Dock 触发 reopen 才补窗）。
        // 这里在 SwiftUI 做完自己的建窗决定之后（async-to-main）兜底：**只有**在「有待处理外部打开」且
        // 「不存在任何主内容窗口」时，才手动建一个宿主 ContentView 的窗口。
        // 用「有 pending」作门控 —— 正常启动（点图标、无文件）队列为空，绝不会误建多余窗口。
        DispatchQueue.main.async { [weak self] in
            self?.ensureWindowForPendingExternalOpens()
        }
    }

    /// reopen（点 Dock 图标 / 无可见窗口时被激活）让 SwiftUI 重建主窗口 —— 标准做法，
    /// 也覆盖「热运行但所有标签都关了之后又点 Dock」的场景。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newTab = NSMenuItem(title: L10n.text("menu.newTab"), action: #selector(openDockNewTab), keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)

        let newWindow = NSMenuItem(title: L10n.text("menu.newWindow"), action: #selector(openDockNewWindow), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)
        return menu
    }

    @objc private func openDockNewTab() {
        MainWindowFactory.open(asTab: true)
    }

    @objc private func openDockNewWindow() {
        MainWindowFactory.open(asTab: false)
    }

    /// 若启动时有待处理的外部打开（文件 / Finder 服务）但 SwiftUI 没建出任何主内容窗口，手动补一个。
    /// 新窗口宿主 `ContentView`，其 `onAppear` 会跑现有的 `ExternalFileOpenQueue.drain()`，把文件打开；
    /// 设共享 `tabbingIdentifier` 以免变成游离窗口、后续新标签能并入。
    /// 若有待处理的外部打开（文件 / Finder 服务）但当前**没有任何主内容窗口**，手动补一个独立窗口。
    /// 覆盖两种场景：① 冷启动（启动期 SwiftUI 没建窗）；② app 在后台运行但所有窗口都关了。
    /// 已有窗口时跳过 —— 那种情况由 ContentView 的 `.onReceive(.openExternalFile)` 处理（开新标签）。
    /// 新窗口的 `ContentView.onAppear` 会跑现有 drain 把文件打开。
    private func ensureWindowForPendingExternalOpens() {
        let hasPending = !ExternalFileOpenQueue.shared.peek().isEmpty
            || !FinderServiceActionQueue.shared.peek().isEmpty
        guard hasPending else { return }
        guard !NSApp.windows.contains(where: { MainWindow.isMainContentWindow($0) }) else { return }
        MainWindowFactory.open(asTab: false)
    }

    /// 入队后异步排一次「无窗则补窗」检查。async-to-main 让已存在窗口的 ContentView 先有机会处理通知
    /// （开新标签）；只有真的没窗口时才落到这里建窗。
    private func scheduleEnsureWindowForPendingExternalOpens() {
        DispatchQueue.main.async { [weak self] in
            self?.ensureWindowForPendingExternalOpens()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ExternalFileOpenQueue.shared.enqueue(URL(fileURLWithPath: filename))
        scheduleEnsureWindowForPendingExternalOpens()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames
            .map { URL(fileURLWithPath: $0) }
            .forEach { ExternalFileOpenQueue.shared.enqueue($0) }
        scheduleEnsureWindowForPendingExternalOpens()
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if !FinderServiceActionQueue.shared.enqueue(fromCallbackURL: url) {
                ExternalFileOpenQueue.shared.enqueue(url)
            }
        }
        scheduleEnsureWindowForPendingExternalOpens()
    }

    @objc func addToArchiveFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.addToArchive"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.addToArchive(urls))
        }
    }

    @objc func calculateHashFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.hash"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.calculateHash(urls))
        }
    }

    private func handleFinderService(
        _ pasteboard: NSPasteboard,
        actionName: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>,
        enqueue: ([URL]) -> Void
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = ((pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]) ?? [])
            .compactMap { $0 as URL }

        guard !urls.isEmpty else {
            error.pointee = L10n.format("finderService.error.noFiles", actionName) as NSString
            return
        }

        enqueue(urls)
        NSApp.activate(ignoringOtherApps: true)
        scheduleEnsureWindowForPendingExternalOpens()
    }
}
