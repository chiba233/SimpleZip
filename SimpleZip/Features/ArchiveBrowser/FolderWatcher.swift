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
/// 同一路径重复 `watch(_:)` 是 no-op；切目录 / 离开浏览用 `stop()`。变化经 `onChange` 回调
/// （回调里自行跳到正确 actor —— 见 ArchiveBrowserModel 传入的闭包）。
///
/// **内存安全（关键）**：用 `passRetained` + context 的 release 回调，让 FSEvent stream 持有本对象
/// 一个强引用，直到 `stop()`（`FSEventStreamRelease`）触发 release 回调才放掉。这样即便有 callback
/// 在 invalidate 前后排队，`self` 也保证存活，不会变悬空指针 —— 这是 FSEvents + Swift 对象的稳妥写法
/// （旧版用 `passUnretained` 有悬空风险）。
///
/// 因此本类**非 `@MainActor`**：
/// - `watch` / `stop` 都由持有者（`ArchiveBrowserModel`，主 actor）调用，天然串行，无数据竞争；
/// - C 回调只读 `info` 指针 + 调 `onChange`，不碰 `stream` / `watchedPath`；
/// - 非隔离让持有者的 `deinit` 能直接调 `stop()` 打破「stream 持有 self」的存活链（否则 self 永不释放）。
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    /// 当前监视路径（标准化）。用于「同路径重复 watch 直接跳过」，避免重建 stream。
    private(set) var watchedPath: String?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // 正常情况下持有者会先调 stop()（释放 stream → 放掉 passRetained 的 +1 → 本对象才可能 deinit），
        // 所以走到这里 stream 一般已是 nil；保底再 stop 一次。
        stop()
    }

    /// 开始监视 `url`（已在内部标准化）。若已在监视同一路径则什么都不做。
    func watch(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path == watchedPath, stream != nil { return }
        stop()

        // passRetained：stream 持有 self 一个强引用，release 回调里对称放掉。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // @convention(c) 回调不能捕获上下文，靠 info 指针取回 self（stream 持有强引用，期间保证存活）。
        // onChange 内部负责跳回主 actor（用 Task { @MainActor } 比 assumeIsolated 更经得起 Swift 6 / 未来运行时检查）。
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
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
            // stream 没建成 → 手动放掉刚才 passRetained 的 +1，避免泄漏。
            if let info = context.info {
                Unmanaged<FolderWatcher>.fromOpaque(info).release()
            }
            watchedPath = nil
            return
        }

        stream = newStream
        watchedPath = path
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    /// 停止监视并释放 stream（release 回调会对称放掉 passRetained 的 +1）。
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
