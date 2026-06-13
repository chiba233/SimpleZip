//
//  OpenArchiveFilePresenter.swift
//  SimpleZip
//
//  0.4.4 #11:外部文件变更感知。盯**单个已打开的归档文件**有没有被 Finder / 其他 App
//  移动、删除、替换或改写。
//
//  为什么用 NSFilePresenter 而不是复用 FSEvents 文件夹监视:FilePresenter 只为这一个文件的
//  协调写入 / 移动 / 删除回调,不是「文件夹每动一下就 reload」那条 @Published 风暴雷区(A17)。
//  回调来自后台 operationQueue,转交给主 actor 的 onEvent;主 actor 侧再跟列表时的 FileStateStamp
//  比对、相等不发布(见 ArchiveBrowserModel.handleOpenArchiveFileEvent)。
//

import Foundation

/// 已打开归档相对「列表那一刻」发生的外部改动。
enum OpenArchiveExternalChange: Equatable {
    case modified   // 内容被改写(大小 / 修改时间变了)
    case removed    // 被移动 / 改名 / 删除 —— 原路径已不是当初那个文件
}

/// `nonisolated`:app target 默认 MainActor 隔离,但 NSFilePresenter 的回调来自后台 operationQueue,
/// presenter 本身不碰主 actor 状态(只转发事件)—— 整类标 nonisolated,deinit / 后台都能直接 stop。
nonisolated final class OpenArchiveFilePresenter: NSObject, NSFilePresenter {
    enum Event: Sendable { case changed, movedOrDeleted }

    var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onEvent: @Sendable (Event) -> Void

    init(url: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.presentedItemURL = url
        self.onEvent = onEvent
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    /// 必须显式停 —— NSFileCoordinator 会一直强持有 presenter,不移除就泄漏 + 收幽灵回调。
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        onEvent(.changed)
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        onEvent(.movedOrDeleted)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onEvent(.movedOrDeleted)
        completionHandler(nil)
    }
}
