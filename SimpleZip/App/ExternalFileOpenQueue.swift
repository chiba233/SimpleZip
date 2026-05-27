//
//  ExternalFileOpenQueue.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

extension Notification.Name {
    static let openExternalFile = Notification.Name("openExternalFile")
    static let finderServiceAction = Notification.Name("finderServiceAction")
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

enum FinderServiceAction {
    case addToArchive([URL])
    case calculateHash([URL])
}

/// Finder 服务事件队列：服务回调可能早于 SwiftUI 主窗口完成初始化。
final class FinderServiceActionQueue {
    static let shared = FinderServiceActionQueue()

    private let lock = NSLock()
    private var pendingActions: [FinderServiceAction] = []

    private init() {}

    func enqueue(_ action: FinderServiceAction) {
        lock.lock()
        pendingActions.append(action)
        lock.unlock()
        NotificationCenter.default.post(name: .finderServiceAction, object: nil)
    }

    func drain() -> [FinderServiceAction] {
        lock.lock()
        defer { lock.unlock() }
        let actions = pendingActions
        pendingActions.removeAll()
        return actions
    }
}
