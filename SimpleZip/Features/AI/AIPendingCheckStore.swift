//
//  AIPendingCheckStore.swift
//  SimpleZip
//
//  0.4.5 #80:只读自动检查 pending 队列的 **app 侧持久 store**(两阶段架构,阶段 B/C 用)。
//
//  持有 `AIPendingCheckQueue`(纯值逻辑在 Core),负责落盘 / 读取 / 计数 / 清空。**派生数据,不进偏好备份**,
//  随「清空后台索引」一并抹掉。入队(阶段 B,电池侧)与执行(阶段 C,插电侧)都经过这里。
//

import Combine
import Foundation

@MainActor
final class AIPendingCheckStore: ObservableObject {
    static let shared = AIPendingCheckStore()

    private(set) var queue: AIPendingCheckQueue
    private let defaults: UserDefaults
    /// done / failed 条目保留期(7 天)—— 过期清掉,内联结果也随之失效需重判。
    private let doneRetention: TimeInterval = 7 * 86_400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queue = AIPendingCheckStore.load(from: defaults)
    }

    // MARK: - 入队(阶段 B,电池侧)

    /// 幂等入队一条只读自动检查。文件没改(同指纹)且已做过就不重排。返回是否有新增 / 变更。
    @discardableResult
    func enqueue(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String, now: Date = Date()) -> Bool {
        let changed = queue.enqueue(path: path, behavior: behavior, fingerprint: fingerprint, now: now)
        if changed { persist(); objectWillChange.send() }
        return changed
    }

    /// 批量入队(阶段 B 一轮扫描)——只在结尾落盘一次,避免逐条重编码整列队。
    func enqueueBatch(_ items: [(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String)],
                      now: Date = Date()) {
        var changed = false
        for item in items where queue.enqueue(path: item.path, behavior: item.behavior,
                                              fingerprint: item.fingerprint, now: now) {
            changed = true
        }
        if changed { persist(); objectWillChange.send() }
    }

    // MARK: - 执行(阶段 C,插电侧)

    func nextPending() -> AIPendingCheck? { queue.nextPending() }

    func markDone(id: String, now: Date = Date()) {
        queue.mark(id: id, status: .done, executedAt: now)
        persist(); objectWillChange.send()
    }

    func markFailed(id: String, now: Date = Date()) {
        queue.mark(id: id, status: .failed, executedAt: now)
        persist(); objectWillChange.send()
    }

    /// 该 (path, behavior, 指纹) 是否已做完 —— 给入队幂等 / 内联结果有效性判断。
    func isDone(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String) -> Bool {
        queue.isDone(path: path, behavior: behavior, fingerprint: fingerprint)
    }

    /// 修剪过期 done / failed(每轮入队 / 执行后调一次即可)。
    func prune(now: Date = Date()) {
        queue.prune(doneRetention: doneRetention, now: now)
        persist()
    }

    // MARK: - DevTools / 清空

    var counts: (pending: Int, done: Int) { (queue.pendingCount, queue.doneCount) }

    func clearAll() {
        guard !queue.checks.isEmpty else { return }
        queue = AIPendingCheckQueue()
        defaults.removeObject(forKey: AppPreferences.Key.aiPendingChecksData)
        objectWillChange.send()
    }

    // MARK: - 持久化

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: AppPreferences.Key.aiPendingChecksData)
        }
    }

    private static func load(from defaults: UserDefaults) -> AIPendingCheckQueue {
        guard let data = defaults.data(forKey: AppPreferences.Key.aiPendingChecksData),
              let decoded = try? JSONDecoder().decode(AIPendingCheckQueue.self, from: data) else {
            return AIPendingCheckQueue()
        }
        return decoded
    }
}
