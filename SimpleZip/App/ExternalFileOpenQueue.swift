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
    /// SimpleZip 内点 `.siz` 时 `ArchiveBrowserModel.open` 发的通知 —— ContentView 监听后走 handleSIZOpen。
    /// 不能走 `NSWorkspace.shared.open` 因为 .siz 的 UTI 注册到了 SimpleZip 自己，会循环创建新窗口。
    static let openSIZContainer = Notification.Name("openSIZContainer")

    /// 用户在文件浏览器选中 `.siz` + 点 Extract 时 `ArchiveBrowserModel.extractArchive` 发的通知 ——
    /// ContentView 监听后做「unwrap → 验签 sheet → 把内层 archive 解压到 `<.siz basename>.unwrapped/`
    /// 同时落一份 `SIZ_SIGNATURE.txt` 签名信息」。
    /// object = 选中的 .siz URL。
    static let extractSIZContainer = Notification.Name("extractSIZContainer")
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

private struct FinderServiceActionPayload: Decodable {
    let fileURLs: [String]
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

    @discardableResult
    func enqueue(fromCallbackURL url: URL) -> Bool {
        guard url.scheme == "simplezip", url.host == "finder-action",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let actionValue = components.queryItems?.first(where: { $0.name == "action" })?.value,
              let payloadPath = components.queryItems?.first(where: { $0.name == "payload" })?.value
        else {
            return false
        }

        let payloadURL = URL(fileURLWithPath: payloadPath)
        guard payloadURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            return false
        }

        defer {
            try? FileManager.default.removeItem(at: payloadURL)
        }

        guard let data = try? Data(contentsOf: payloadURL),
              let payload = try? JSONDecoder().decode(FinderServiceActionPayload.self, from: data)
        else {
            return false
        }

        let urls = payload.fileURLs.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return false }

        switch actionValue {
        case "addToArchive":
            enqueue(.addToArchive(urls))
        case "hash":
            enqueue(.calculateHash(urls))
        default:
            return false
        }
        return true
    }

    func drain() -> [FinderServiceAction] {
        lock.lock()
        defer { lock.unlock() }
        let actions = pendingActions
        pendingActions.removeAll()
        return actions
    }
}
