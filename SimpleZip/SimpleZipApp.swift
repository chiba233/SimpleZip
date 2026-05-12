//
//  SimpleZipApp.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

@main
struct SimpleZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
}

extension Notification.Name {
    static let openExternalFile = Notification.Name("openExternalFile")
}

final class ExternalFileOpenQueue {
    static let shared = ExternalFileOpenQueue()

    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingURLs.append(url)
        NotificationCenter.default.post(name: .openExternalFile, object: url)
    }

    func drain() -> [URL] {
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }
}
