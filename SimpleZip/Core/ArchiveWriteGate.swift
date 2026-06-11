//
//  ArchiveWriteGate.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.3 #2/#3:归档写入的统一闸门 —— 同一目标文件的写互斥锁 + 外部改动检测。
//
//  为什么是统一层而不是各功能自防:批量重命名 / 注释编辑 / 清理垃圾 / 归档内编辑都做
//  「复制原包 → 副本上干活 → 原子替换」,两个写任务同时跑会各自基于旧包生成新包,后替换的
//  把先替换的成果整个覆盖掉(丢数据)。读(list / 解压 / 测试)无需加锁 —— 原子替换保证
//  读到的永远是某个完整版本。
//
//  外部改动检测(快照戳):打开归档时记 size+mtime+inode,写回前核对 —— Finder / 其他 App /
//  另一个 SimpleZip 进程不走我们的进程内锁,只能靠「写前确认还是用户看到的那个文件」兜底。
//  与 UndoFileSnapshot 的思路一致,这里扩到归档写回。
//

import Foundation

/// 文件的轻量状态戳:大小 + 修改时间 + inode。
/// 任何常规修改至少会动其中之一(原子替换必换 inode;原地写必动 mtime/size)。
public struct FileStateStamp: Equatable, Sendable {
    public let size: Int64
    public let modified: Date
    public let inode: UInt64

    /// 抓取当前状态。文件不存在 / 不可读时抛错。
    public static func capture(_ url: URL) throws -> FileStateStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStateStamp(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// 写回前的守门:当前状态与本戳不一致(包括文件已消失)→ 抛「已被外部修改」。
    public func ensureUnchanged(at url: URL) throws {
        guard let current = try? Self.capture(url), current == self else {
            throw ArchiveError.archiveExternallyModified(url.lastPathComponent)
        }
    }
}

/// 进程内的「按目标文件互斥」写锁。写任务排队(FIFO),不拒绝;等待时回调上报,
/// 让任务详情能显示「等待归档释放」。
public actor ArchiveWriteLock {
    public static let shared = ArchiveWriteLock()

    private var heldKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// 锁按「解析符号链接后的标准化路径」记 —— 同一个包经不同路径(symlink)写也互斥。
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 取得 url 的独占写权。已被占用时挂起排队(先到先得),挂起前回调 `onWait` 一次。
    public func acquire(_ url: URL, onWait: (@Sendable () -> Void)? = nil) async {
        let key = Self.key(for: url)
        if !heldKeys.contains(key) {
            heldKeys.insert(key)
            return
        }
        onWait?()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
        // release() 把锁直接移交给队首(heldKeys 保持占用),醒来即持锁。
    }

    /// 释放写权:有人排队则移交队首,否则摘除占用标记。
    public func release(_ url: URL) {
        let key = Self.key(for: url)
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            heldKeys.remove(key)
        }
    }

    /// `defer { … }` 友好的释放入口(defer 里不能 await)。Task 化的延迟不影响互斥正确性,
    /// 只是下一个等待者稍晚被唤醒。
    public nonisolated func scheduleRelease(_ url: URL) {
        Task { await self.release(url) }
    }
}

public extension Notification.Name {
    /// 某归档刚被安全写回(原子替换完成)。打开同一归档的其他窗口 / 标签页应刷新列表。
    /// userInfo["path"] = 标准化路径。主线程派发。
    static let simpleZipArchiveDidRewrite = Notification.Name("SimpleZip.archiveDidRewrite")
}

extension ArchiveService {
    /// 写回成功后的统一广播(主线程)。
    static func notifyArchiveRewritten(_ url: URL) {
        let path = url.standardizedFileURL.path
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .simpleZipArchiveDidRewrite,
                object: nil,
                userInfo: ["path": path]
            )
        }
    }
}
