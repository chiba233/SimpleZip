//
//  FolderWatcher.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/31.
//
//  0.2.0：用 FSEvents 监视当前文件夹，内容一变（外部增删改 / 本应用自己的增删改）就自动刷新列表。
//  在此之前列表只在导航 / 操作后 / ⌘R 时才刷新，外部改动看不到。引入 watcher 后，文件操作（粘贴 /
//  删除 / 重命名 / 拖放）不再各自手动 reload —— 统一交给 watcher，少一类「忘了刷新」的 bug。
//

import CoreServices
import Foundation

/// 监视**单个目录**内容变化的 FSEvents 封装（非递归：只关心该目录直接子项的增删改）。
/// 变化经 0.2s 原生合并后在主线程回调。生命周期由持有者（ArchiveBrowserModel）管理：
/// 进 `.folder` 模式 `watch(_:)`，离开（archive / tag）`stop()`，同一路径重复 watch 是 no-op。
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    /// 当前监视路径（标准化）。用于「同路径重复 watch 直接跳过」，避免重建 stream。
    private(set) var watchedPath: String?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // 只做 C 层 stream 拆除，不碰 MainActor 状态 —— deinit 可能不在主 actor 执行。
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 开始监视 `url`（已在内部标准化）。若已在监视同一路径则什么都不做。
    func watch(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path == watchedPath, stream != nil { return }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // @convention(c) 回调不能捕获上下文，靠 info 指针取回 self；不能是 MainActor 隔离的闭包，
        // 所以在里面用 assumeIsolated 跳回主 actor（dispatch queue 已设成 .main，确实在主线程）。
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                watcher.onChange()
            }
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency：原生合并 0.2s 内的连续事件，少触发几次刷新。
            UInt32(kFSEventStreamCreateFlagNone)
        ) else {
            watchedPath = nil
            return
        }

        stream = newStream
        watchedPath = path
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    /// 停止监视并释放 stream。
    func stop() {
        guard let stream else {
            watchedPath = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPath = nil
    }
}
