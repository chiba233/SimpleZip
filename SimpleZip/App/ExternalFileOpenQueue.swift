//
//  ExternalFileOpenQueue.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let openExternalFile = Notification.Name("openExternalFile")
    static let finderServiceAction = Notification.Name("finderServiceAction")
    /// 用户从 File 菜单触发「创建签名清单」—— ContentView 收到后弹 `CreateSZSSheet`。
    static let openCreateSZSSheet = Notification.Name("openCreateSZSSheet")
}

/// 从 `NSItemProvider` 数组里异步提取 file URL，主线程回调结果。
///
/// 共享给「主区域拖入」和「侧栏固定区拖入」两个 `.onDrop` 回调用 —— 之前两边各写一份 25 行
/// filter / NSLock / DispatchGroup / loadDataRepresentation 样板。返回 false 表示 providers
/// 里压根没有 file URL，调用方据此决定是否接受拖放（`.onDrop` 的返回值约定）。
@discardableResult
func extractDroppedFileURLs(
    from providers: [NSItemProvider],
    completion: @escaping ([URL]) -> Void
) -> Bool {
    let fileURLProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileURLProviders.isEmpty else { return false }

    var urls = Array<URL?>(repeating: nil, count: fileURLProviders.count)
    let lock = NSLock()
    let group = DispatchGroup()

    for (index, provider) in fileURLProviders.enumerated() {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            defer { group.leave() }
            if let data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                lock.lock()
                urls[index] = url
                lock.unlock()
            }
        }
    }

    group.notify(queue: .main) {
        completion(urls.compactMap { $0 })
    }
    return true
}

/// 外部打开事件队列：解决冷启动时文件事件早于 SwiftUI 窗口初始化的问题。
final class ExternalFileOpenQueue {
    static let shared = ExternalFileOpenQueue()

    private let lock = NSLock()
    private var pendingURLs: [URL] = []
    /// 「路由认领」用的世代计数：每次 `enqueue` +1。多标签下所有 ContentView 都收到 `.openExternalFile`，
    /// 但只有第一个 `claimRouting()` 返回 true 的视图负责决定「原地处理 / 开新标签」，其余直接 return，
    /// 保证一个外部打开事件只产生一个新标签（不依赖 keyWindow，后台无 key 窗也不漏）。
    private var routingGeneration = 0
    private var lastClaimedGeneration = 0

    private init() {}

    func enqueue(_ url: URL) {
        lock.lock()
        pendingURLs.append(url)
        routingGeneration += 1
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

    /// 非破坏性查看当前待处理 URL（不清空队列）——用于在 drain 前对这批待打开项做分类决策
    /// （比如「是否全是 Finder 自动解压浮窗类」→ 决定原地处理还是开新标签）。
    func peek() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return pendingURLs
    }

    /// 路由认领：当前世代尚未被认领时置位并返回 true（首个调用者）；其余调用返回 false。
    /// 同一批 enqueue（同一世代）只会有一个认领者，避免多标签时每个 ContentView 各开一个新标签。
    func claimRouting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard routingGeneration > lastClaimedGeneration else { return false }
        lastClaimedGeneration = routingGeneration
        return true
    }
}

enum FinderServiceAction {
    case addToArchive([URL])
    case calculateHash([URL])
    case extract([URL])
    /// 「用 SimpleZip 创建 ▸ ZIP/7z/…」—— 按默认设置直接出包，无对话框。
    case quickCreate(ArchiveCreateFormat, [URL])
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
        case "extract":
            enqueue(.extract(urls))
        case "createZip":
            enqueue(.quickCreate(.zip, urls))
        case "create7z":
            enqueue(.quickCreate(.sevenZip, urls))
        case "createTarGz":
            enqueue(.quickCreate(.tarGzip, urls))
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

    /// 非破坏性查看当前待处理动作（不清空）—— 冷启动建窗判定「是否有 pending」用。
    func peek() -> [FinderServiceAction] {
        lock.lock()
        defer { lock.unlock() }
        return pendingActions
    }
}
