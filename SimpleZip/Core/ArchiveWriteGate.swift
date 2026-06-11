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

/// 0.4.3 #4:磁盘空间预检。「复制原包 → 工作副本 → 原子替换」族操作需要约 2~3 倍原包的
/// 空间;不足时后端会以各种难懂的方式半途失败 —— 开工前显式拦截,
/// 报错明确给出「至少需要约 X,当前剩余 Y」。
public enum DiskSpacePreflight {
    /// url 所在卷的可用容量(importantUsage 口径:含系统可清除空间,与 Finder 显示一致)。
    /// 取不到(罕见)返回 nil —— 调用方不拦截,宁可放行也不误杀。
    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 确保 url 所在卷至少有 estimatedBytes 可用,否则抛 `insufficientDiskSpace`。
    /// estimatedBytes <= 0(未知大小)或容量读不到 → 不检查。
    public static func ensure(estimatedBytes: Int64, at url: URL) throws {
        guard estimatedBytes > 0, let available = availableCapacity(at: url) else { return }
        if available < estimatedBytes {
            throw ArchiveError.insufficientDiskSpace(needed: estimatedBytes, available: available)
        }
    }
}

/// 0.4.3 #8:写回失败的「恢复区」。两类失败时工作副本有价值,不该随 staging 一起焚毁:
/// - 外部改动拦截(替换前发现包被别人改了)→ 副本是**基于旧版的完整改写成果**,用户的编辑没白做;
/// - 写后验证失败 → 副本是诊断样本(什么样的输入让 7zz 写坏了)。
/// 恢复区在 Application Support 下(临时目录会被系统清);成功的操作照旧随 staging 即焚,
/// 不会越积越多。入口:设置 → 关于 → 开发者工具(显示 / 一键清理),失败信息里也带路径。
public enum ArchiveRecoveryArea {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SimpleZip/Recovery", isDirectory: true)
    }

    /// 把工作副本搬进恢复区,返回落点(失败返回 nil —— 恢复是尽力而为,绝不让保全动作掩盖原始错误)。
    /// 命名:`<原包名>-<标签>-<短ID>.<扩展名>`,一眼能对回原包。
    public static func preserve(_ workCopy: URL, for archiveURL: URL, label: String) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = archiveURL.deletingPathExtension().lastPathComponent
            let ext = archiveURL.pathExtension
            let shortID = UUID().uuidString.prefix(8)
            let name = ext.isEmpty ? "\(stem)-\(label)-\(shortID)" : "\(stem)-\(label)-\(shortID).\(ext)"
            let destination = directory.appendingPathComponent(name)
            try fm.moveItem(at: workCopy, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// 恢复区当前内容(不存在 = 空)。
    public static func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// 一键清空恢复区。
    public static func clear() throws {
        let fm = FileManager.default
        for url in contents() {
            try fm.removeItem(at: url)
        }
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
