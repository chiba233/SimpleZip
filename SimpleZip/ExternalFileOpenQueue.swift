//
//  ExternalFileOpenQueue.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

extension Notification.Name {
    static let openExternalFile = Notification.Name("openExternalFile")
}

/// 外部打开事件队列：解决冷启动时文件事件早于 SwiftUI 窗口初始化的问题。
final class ExternalFileOpenQueue {
    static let shared = ExternalFileOpenQueue()

    private let lock = NSLock()
    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        lock.lock()
        pendingURLs.append(url)
        lock.unlock()
        NotificationCenter.default.post(name: .openExternalFile, object: url)
    }

    func drain() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }
}
