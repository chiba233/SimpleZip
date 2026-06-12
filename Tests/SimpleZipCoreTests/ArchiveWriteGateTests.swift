import Foundation
import Testing
@testable import SimpleZipCore

/// 0.4.3 #2/#3:归档写入闸门 —— 同包写锁的互斥语义 + 外部改动检测的快照戳。
/// 数据安全核心:两个写任务绝不并发改同一个包;打开后被外部改过的包,写回必须被拦下。
struct ArchiveWriteGateTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SZWriteGateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - FileStateStamp

    @Test func stampDetectsContentRewrite() throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("a.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)

        let stamp = try FileStateStamp.capture(file)
        try stamp.ensureUnchanged(at: file)   // 没动 → 不抛

        // 原子改写(atomically:true 走临时文件 rename,inode 必变)。
        try "two".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ArchiveError.self) {
            try stamp.ensureUnchanged(at: file)
        }
    }

    @Test func stampDetectsDeletion() throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("a.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let stamp = try FileStateStamp.capture(file)
        try FileManager.default.removeItem(at: file)
        #expect(throws: ArchiveError.self) {
            try stamp.ensureUnchanged(at: file)
        }
    }

    // MARK: - ArchiveWriteLock

    /// 两个「持锁临界区」绝不重叠:并发跑 N 个递增任务,锁内读-改-写一个非原子计数器,
    /// 若互斥失效会丢更新(经典竞态),最终计数 < N。
    @Test func lockSerializesCriticalSections() async throws {
        let lock = ArchiveWriteLock()
        let url = URL(fileURLWithPath: "/tmp/SZWriteGateTest-lock-\(UUID().uuidString).zip")
        let box = CounterBox()
        let iterations = 64
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    try await lock.acquire(url)
                    let value = box.value
                    await Task.yield()          // 给竞态让出窗口
                    box.value = value + 1
                    await lock.release(url)
                }
            }
            try await group.waitForAll()
        }
        #expect(box.value == iterations)
    }

    /// 不同路径互不阻塞:A 持锁期间,B(另一个文件)能立即拿到锁。
    @Test func differentURLsDoNotContend() async throws {
        let lock = ArchiveWriteLock()
        let a = URL(fileURLWithPath: "/tmp/SZWriteGateTest-a-\(UUID().uuidString).zip")
        let b = URL(fileURLWithPath: "/tmp/SZWriteGateTest-b-\(UUID().uuidString).zip")
        try await lock.acquire(a)
        try await lock.acquire(b)   // 若按路径互斥失效(全局单锁),这里会死等
        await lock.release(b)
        await lock.release(a)
    }

    /// 等待方在锁被占时收到 onWait 回调,且锁释放后按序拿到锁。
    @Test func waiterIsReportedAndResumed() async throws {
        let lock = ArchiveWriteLock()
        let url = URL(fileURLWithPath: "/tmp/SZWriteGateTest-wait-\(UUID().uuidString).zip")
        try await lock.acquire(url)

        let waited = CounterBox()
        let waiter = Task {
            try await lock.acquire(url, onWait: { waited.value += 1 })
            await lock.release(url)
        }
        // 等待方挂起后释放 —— 它应被唤醒并跑完。
        try await Task.sleep(nanoseconds: 100_000_000)
        await lock.release(url)
        try await waiter.value
        #expect(waited.value == 1)
    }

    /// 队列管理③写锁可视化:快照如实反映「谁持有 / 谁在排队」,全部释放后清空。
    @Test func snapshotTracksHolderAndWaiters() async throws {
        let lock = ArchiveWriteLock()
        let url = URL(fileURLWithPath: "/tmp/SZWriteGateTest-snap-\(UUID().uuidString).zip")
        let holderID = UUID()
        let waiterID = UUID()

        try await lock.acquire(url, operationID: holderID)
        var snapshot = await lock.snapshot()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.holderOperationID == holderID)
        #expect(snapshot.entries.first?.waiterOperationIDs.isEmpty == true)

        let waiter = Task {
            try await lock.acquire(url, operationID: waiterID)
            await lock.release(url)
        }
        // 等待方真正挂进队列后,快照里能看到它。
        var sawWaiter = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await lock.snapshot()
            if snapshot.entries.first?.waiterOperationIDs == [waiterID] {
                sawWaiter = true
                break
            }
        }
        #expect(sawWaiter)

        await lock.release(url)   // 移交队首 → 等待方持锁、跑完、释放
        try await waiter.value
        snapshot = await lock.snapshot()
        #expect(snapshot.entries.isEmpty)
    }

    /// P2 修复:排队等锁的任务被取消 → 立刻以 CancellationError 摘除,绝不在前任释放后
    /// "复活"继续写包;取消后锁的移交也跳过它,全释放后登记表干净。
    @Test func cancelledWaiterNeverAcquires() async throws {
        let lock = ArchiveWriteLock()
        let url = URL(fileURLWithPath: "/tmp/SZWriteGateTest-cancel-\(UUID().uuidString).zip")
        try await lock.acquire(url)

        let outcome = CounterBox()   // 1 = 不该发生的「拿到锁」,2 = 正确的取消
        let waiter = Task {
            do {
                try await lock.acquire(url)
                outcome.value = 1
                await lock.release(url)
            } catch is CancellationError {
                outcome.value = 2
            } catch {
                outcome.value = 3   // 意外错误类型 —— 测试该挂
            }
        }
        // 确认真排进了队列再取消。
        var queued = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if await lock.snapshot().entries.first?.waiterOperationIDs.count == 1 {
                queued = true
                break
            }
        }
        #expect(queued)
        waiter.cancel()
        await waiter.value
        #expect(outcome.value == 2)

        // 持有者释放:被取消的等待者不应复活;锁应彻底空闲。
        await lock.release(url)
        let snapshot = await lock.snapshot()
        #expect(snapshot.entries.isEmpty)
    }

    // MARK: - 写引擎集成:过期戳拦截真实写回

    @Test func deleteEntriesRejectsStaleStamp() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        // 造一个真实 zip。
        let source = temp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "A".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: source.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        var options = ArchiveCreationOptions()
        options.format = .zip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        let archive = temp.appendingPathComponent("test.zip")
        try await ArchiveService.createArchive(from: [source], destination: archive, options: options)

        // 「打开」时的戳。
        let openStamp = try FileStateStamp.capture(archive)
        let bytesBeforeExternalEdit = try Data(contentsOf: archive)

        // 外部修改:原子换掉整个包(模拟 Finder / 其他 App)。
        let replacement = temp.appendingPathComponent("replacement.zip")
        try bytesBeforeExternalEdit.write(to: replacement)   // 内容相同也无妨,inode 已变
        _ = try FileManager.default.replaceItemAt(archive, withItemAt: replacement)
        let bytesAfterExternalEdit = try Data(contentsOf: archive)

        // 带着过期戳写回 → 必须被拦,且包一个字节不动。
        await #expect(throws: ArchiveError.self) {
            try await ArchiveService.deleteEntries(
                from: archive,
                entryPaths: ["source/a.txt"],
                expectedStamp: openStamp
            )
        }
        #expect(try Data(contentsOf: archive) == bytesAfterExternalEdit)

        // 用新鲜戳重试 → 正常成功(等价「重新载入后重试」)。
        let freshStamp = try FileStateStamp.capture(archive)
        try await ArchiveService.deleteEntries(
            from: archive,
            entryPaths: ["source/a.txt"],
            expectedStamp: freshStamp
        )
        let listed = try await ArchiveService.list(archive)
        #expect(!listed.contains { $0.name.hasSuffix("a.txt") })
        #expect(listed.contains { $0.name.hasSuffix("b.txt") })
    }
}

/// 测试用的非原子计数器(类引用语义,故意不加锁 —— 竞态由 ArchiveWriteLock 防)。
private final class CounterBox: @unchecked Sendable {
    var value = 0
}
