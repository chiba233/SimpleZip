//
//  AppDelegate.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation

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
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ExternalFileOpenQueue.shared.enqueue(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames
            .map { URL(fileURLWithPath: $0) }
            .forEach { ExternalFileOpenQueue.shared.enqueue($0) }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if !FinderServiceActionQueue.shared.enqueue(fromCallbackURL: url) {
                ExternalFileOpenQueue.shared.enqueue(url)
            }
        }
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
    }
}
