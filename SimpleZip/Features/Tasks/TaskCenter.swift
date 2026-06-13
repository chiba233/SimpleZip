//
//  TaskCenter.swift
//  SimpleZip
//

import AppKit
import Combine
import Foundation

@MainActor
final class TaskCenter: ObservableObject {
    static let shared = TaskCenter()

    @Published private(set) var active: [OperationTask] = []
    @Published private(set) var history: [OperationTask] = []

    /// 0.4.3 #5:任务运行期间的系统活动断言 —— 阻止系统空闲睡眠 + 禁用 sudden termination,
    /// 大任务不再因为合盖 / 闲置被腰斩。非 nil = 正在持有。
    private var activityAssertion: NSObjectProtocol?
    /// 0.4.3 #5:「完成后退出」已被用户选择(applicationShouldTerminate 返回 terminateLater 中)。
    private(set) var quitAfterTasksFinish = false

    /// 队列管理①:「全部完成后睡眠」—— 会话内开关(与「完成后退出」同性质,不持久化)。
    /// 活动中心在有任务运行时给开关;最后一个任务收尾时整机睡眠,开关自动复位。
    @Published var sleepWhenAllTasksFinish = false

    /// 队列管理③:写锁可视化 —— ArchiveWriteLock 的最新快照(谁占着哪个包的写锁/谁在排队)。
    /// 只在写任务 acquire/release 时变化(低频),活动中心据此渲染「归档写入锁」一节。
    @Published private(set) var writeLockSnapshot = ArchiveWriteLockSnapshot(entries: [])

    /// 0.4.4 F4:队列级暂停 —— 用户在活动中心一键暂停整个队列。@Published:只随用户点击翻转,
    /// 不在 reload 路径上。**不持久化、重启不自动恢复**(冻着的子进程不会跨会话存活)。
    @Published private(set) var isQueuePaused = false
    /// 被「队列暂停」按下去的任务 id —— 恢复时只恢复这批;用户单独手动暂停的任务不被殃及。
    private var queuePausedTaskIDs: Set<UUID> = []

    private var historyLimit: Int {
        AppPreferences.activityHistoryLimit
    }

    init() {
        history = Self.loadPersistedHistory()
        trimHistoryToLimit()
        // CLI companion:接收 `simplezip` 进程发来的已完成任务记录(分布式通知,真·跨进程,
        // 不在 A3 禁区)。app 在跑时 CLI 走这条道,记录实时进活动中心;没在跑时 CLI 直接写偏好域。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveExternalCLITaskRecord(_:)),
            name: Notification.Name(Self.cliTaskNotificationName),
            object: nil
        )
        // 队列管理③:订阅写锁状态 —— actor 回调跳回主 actor 后落进发布属性。
        Task { [weak self] in
            await ArchiveWriteLock.shared.setObserver { snapshot in
                Task { @MainActor in
                    self?.writeLockSnapshot = snapshot
                }
            }
        }
    }

    /// operationID → 运行中任务标题(写锁可视化用;不在跑的返回 nil)。
    func taskTitle(forOperationID operationID: UUID?) -> String? {
        guard let operationID else { return nil }
        return active.first(where: { $0.operationID == operationID })?.title
    }

    /// CLI → app 的任务记录通知名。本地任何进程都能发 —— 它只影响历史记录展示,
    /// 与直接改偏好 plist 同级,不构成新的攻击面。
    nonisolated static let cliTaskNotificationName = "SimpleZip.cli.taskRecord"

    /// app 侧:收 CLI 进程的已完成任务记录 → 插历史 + 持久化。分布式通知投递在主运行循环。
    @objc private func receiveExternalCLITaskRecord(_ notification: Notification) {
        guard let json = notification.userInfo?["record"] as? String,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(PersistedTask.self, from: data) else { return }
        history.insert(snapshot.task, at: 0)
        trimHistoryToLimit()
        persistHistory()
    }

    /// CLI 进程侧:把一条**已完成**的命令记录同步进活动中心。
    /// app 正在运行 → 发分布式通知(上面的 observer 接住,实时可见);
    /// 没运行 → 直接合并写进 app 的偏好域(`activityHistory`),下次启动出现在历史里。
    /// CLI 进程经 PATH 符号链接运行时 `Bundle.main` 不指向 app bundle(实测),所以偏好域与
    /// 「app 是否在跑」都以显式传入的 bundleID 为准。两个 CLI 进程同时直写有理论竞态 ——
    /// 后写覆盖、只影响一条历史记录,接受;app 在跑时统一走通知,无竞态。
    nonisolated static func recordExternalCLITask(
        appBundleID: String,
        category: OperationTask.Category,
        kind: OperationTask.Kind,
        title: String,
        detail: String?,
        startedAt: Date,
        succeeded: Bool,
        failureMessage: String?,
        rawOutput: String
    ) {
        let now = Date()
        let record = PersistedTask(
            id: UUID(),
            category: category,
            kind: kind,
            source: .cli,
            title: title,
            detail: detail,
            startedAt: startedAt,
            status: succeeded ? .succeeded(nil) : .failed(failureMessage ?? "failed"),
            finishedAt: now,
            progress: PersistedProgress(progress: ArchiveProgressState()),
            details: rawOutput.isEmpty ? nil : PersistedDetails(title: title, rawOutput: rawOutput, finishedAt: now),
            hashReport: nil,
            hashComparisons: nil,
            transferLog: nil
        )
        let appIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
        if appIsRunning {
            guard let payload = try? JSONEncoder().encode(record),
                  let json = String(data: payload, encoding: .utf8) else { return }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(cliTaskNotificationName),
                object: nil,
                userInfo: ["record": json],
                deliverImmediately: true
            )
            return
        }
        guard let defaults = UserDefaults(suiteName: appBundleID) else { return }
        var snapshots: [PersistedTask] = []
        if let data = defaults.data(forKey: AppPreferences.Key.activityHistory),
           let existing = try? JSONDecoder().decode([LossyTask].self, from: data) {
            snapshots = existing.compactMap(\.value)
        }
        snapshots.insert(record, at: 0)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: AppPreferences.Key.activityHistory)
        // CLI 进程随即 exit —— 强制把 CFPreferences 缓冲落盘,不然记录可能丢。
        defaults.synchronize()
    }

    var runningCount: Int {
        active.count
    }

    var primaryActiveCategory: OperationTask.Category? {
        active.first?.category
    }

    var aggregateFraction: Double? {
        let fractions = active.compactMap(\.progress.fraction)
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    var primaryProgressText: String? {
        active.lazy.compactMap { task -> String? in
            if let statusText = task.progress.statusText, !statusText.isEmpty {
                return statusText
            }
            if let currentFile = task.progress.currentFile, !currentFile.isEmpty {
                return currentFile
            }
            return nil
        }.first
    }

    @discardableResult
    func begin(
        category: OperationTask.Category,
        kind: OperationTask.Kind,
        source: OperationTask.Source = .app,
        title: String,
        detail: String? = nil,
        cancellable: Bool,
        detailsSession: ArchiveOperationDetailsSession? = nil,
        operationID: UUID? = nil
    ) -> OperationTask {
        let task = OperationTask(
            category: category,
            kind: kind,
            source: source,
            title: title,
            detail: detail,
            cancellable: cancellable,
            detailsSession: detailsSession,
            operationID: operationID
        )
        // 新任务插到最前：活动中心列表整体「越新越靠上」（历史也是 insert(at: 0)），用户一眼能看到刚建的任务。
        active.insert(task, at: 0)
        updateActivityAssertion()
        return task
    }

    /// 0.4.3 #5:有任务在跑 → 持系统活动断言（防空闲睡眠 + 防 sudden termination）；清零 → 释放。
    private func updateActivityAssertion() {
        if active.isEmpty {
            if let assertion = activityAssertion {
                ProcessInfo.processInfo.endActivity(assertion)
                activityAssertion = nil
            }
        } else if activityAssertion == nil {
            activityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "SimpleZip archive tasks running"
            )
        }
    }

    /// 0.4.3 #5:「完成后退出」—— applicationShouldTerminate 返回 `.terminateLater` 后由这里接管:
    /// 全部任务收尾时回 `reply(toApplicationShouldTerminate: true)` 完成退出。
    func quitWhenAllTasksFinish() {
        quitAfterTasksFinish = true
        completeQuitIfIdle()
    }

    private func completeQuitIfIdle() {
        guard quitAfterTasksFinish, active.isEmpty else { return }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func finish(_ task: OperationTask, outcome: OperationTask.Status) {
        guard let index = active.firstIndex(where: { $0.id == task.id }) else { return }
        // F4:任务在队列暂停期间收尾(取消 / 进程内阶段跑完)→ 摘掉暂停登记,id 不残留。
        queuePausedTaskIDs.remove(task.id)
        let finishedTask = active.remove(at: index)
        finishedTask.status = outcome
        finishedTask.finishedAt = Date()
        finishedTask.detailsSession?.finishedAt = finishedTask.finishedAt
        history.insert(finishedTask, at: 0)
        trimHistoryToLimit()
        persistHistory()
        // 0.4.4 macOS 26 AI:收尾任务单条增量进 Spotlight(macOS 15+ / 开关开才生效;后台、失败静默)。
        ArchiveTaskSpotlightIndexer.index(finishedTask)
        // 0.4.2 活动中心设置:失败自动弹出 / 完成提示音(都默认关,纯可选行为)。
        if case .failed = outcome, AppPreferences.tasksOpenOnFailure {
            ActivityWindowController.shared.show()
        }
        if AppPreferences.tasksPlaySoundOnFinish {
            switch outcome {
            case .succeeded: NSSound(named: "Glass")?.play()
            case .failed: NSSound(named: "Basso")?.play()
            default: break
            }
        }
        // 0.4.3 #5:断言随任务清零释放;「完成后退出」在最后一个任务收尾时兑现。
        updateActivityAssertion()
        completeQuitIfIdle()
        completeSleepIfIdle()
    }

    /// 「全部完成后睡眠」兑现:走 System Events 的标准睡眠事件 —— 普通权限可用
    /// (首次触发 macOS 弹一次自动化授权);不用 `pmset sleepnow`(部分系统要 root,失败还无声)。
    /// 开关用后即复位,绝不让下一批任务意外把机器睡过去。
    private func completeSleepIfIdle() {
        guard sleepWhenAllTasksFinish, active.isEmpty else { return }
        sleepWhenAllTasksFinish = false
        var errorInfo: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to sleep")?
            .executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("SimpleZip: sleep-when-done failed: %@", errorInfo)
        }
    }

    func cancelAll() {
        for task in active {
            task.cancel?()
        }
    }

    /// 0.4.4 F4:暂停 / 恢复整个队列。
    /// 暂停 = 调度器闸门关上(新重任务全部入队等待)+ 对所有「可暂停且在跑」的任务逐个 SIGSTOP;
    /// 恢复 = 闸门打开 + 只恢复**被本开关暂停的**那批(用户单独手动暂停的不动)。
    /// 不可暂停的种类(哈希 / 拆分合并 / 文件操作)继续跑完 —— UI 文案如实说明,不假装能冻住。
    func setQueuePaused(_ paused: Bool) {
        guard paused != isQueuePaused else { return }
        isQueuePaused = paused
        if paused {
            HeavyTaskScheduler.shared.pauseQueue()
            for task in active where task.status.isRunning && !task.isPaused && task.pause != nil && !task.isAwaitingSlot {
                task.pause?()
                queuePausedTaskIDs.insert(task.id)
            }
        } else {
            HeavyTaskScheduler.shared.resumeQueue()
            for task in active where queuePausedTaskIDs.contains(task.id) && task.isPaused {
                task.resume?()
            }
            queuePausedTaskIDs.removeAll()
        }
    }

    /// 队列暂停期间新起的「可暂停但不走并发槽」的任务(目前只有 compare):装好闭包后立即补停,
    /// 不然它会无视暂停直接跑。startManagedArchiveTask 在注入 pause/resume 后调用。
    func applyQueuePauseIfNeeded(to task: OperationTask) {
        guard isQueuePaused, task.status.isRunning, !task.isPaused, let pause = task.pause else { return }
        pause()
        queuePausedTaskIDs.insert(task.id)
    }

    func notifyTaskChanged() {
        objectWillChange.send()
    }

    /// 0.4.4(用户反馈「看到一个消一个」):某张失败卡进入活动中心视口 = 这条失败「已看过」。
    /// 只标这一条,侧栏红点随之减一;failureSeen 随历史持久化,重启不复亮。幂等(已看/非失败直接返回)。
    func markFailureSeen(_ task: OperationTask) {
        guard case .failed = task.status, !task.failureSeen else { return }
        task.failureSeen = true
        objectWillChange.send()
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    /// 0.4.4 D:只清成功(含「相同已跳过」)的历史 —— 失败 / 取消留着排查。
    func clearSucceededHistory() {
        history.removeAll { task in
            switch task.status {
            case .succeeded, .skipped: return true
            default: return false
            }
        }
        persistHistory()
    }

    func applyHistoryLimitChange() {
        trimHistoryToLimit()
        persistHistory()
    }

    private func trimHistoryToLimit() {
        // 0.4.3 用户纠正:上限是**每个分类各自**最多 N 条,不是全部分类合计 N 条 ——
        // 否则一轮批量文件操作就把归档操作的历史全挤掉。history 已是新→旧,各分类保留最新的 N 条。
        let limit = historyLimit
        var countByCategory: [OperationTask.Category: Int] = [:]
        var kept: [OperationTask] = []
        kept.reserveCapacity(history.count)
        for task in history {
            let count = countByCategory[task.category, default: 0]
            guard count < limit else { continue }
            countByCategory[task.category] = count + 1
            kept.append(task)
        }
        if kept.count != history.count {
            history = kept
        }
    }

    /// 历史持久化串行队列：编码 + 写盘放后台，避免「任务完成瞬间」在主线程同步 JSON 编码大段历史
    /// （含大量哈希值 / 路径）卡 UI。串行保证多次快速完成时的写入顺序，不会用旧快照覆盖新快照。
    private static let persistQueue = DispatchQueue(label: "com.simplezip.taskcenter.persist", qos: .utility)

    private func persistHistory() {
        // 快照在主 actor 上取（读 OperationTask 的隔离状态），编码/写盘丢到后台串行队列。
        let snapshots = history.map(PersistedTask.init(task:))
        let key = AppPreferences.Key.activityHistory
        Self.persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshots) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 退出前同步落盘 —— persistQueue 的异步写在 terminate 时可能没跑完，最后一批完成的任务会丢。
    /// applicationWillTerminate 调它（sync 等队列排空即可，写本身极快）。
    func flushHistoryNow() {
        Self.persistQueue.sync { }
    }

    /// 0.4.2 修「经常丢历史」：以前 `try? decode([PersistedTask])` **一条解码失败 = 整段历史归零**，
    /// 而且下一次任务完成就把空数组写回盘（新旧版本混用时新枚举 case 必触发）。
    /// 现在逐条 lossy 解码：坏的丢、好的留；配合 Kind / TransferAction 的未知值降级，单条也很难再坏。
    private nonisolated struct LossyTask: Decodable {
        let value: PersistedTask?
        init(from decoder: Decoder) throws {
            value = try? PersistedTask(from: decoder)
        }
    }

    private static func loadPersistedHistory() -> [OperationTask] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.Key.activityHistory),
              let lossy = try? JSONDecoder().decode([LossyTask].self, from: data)
        else { return [] }
        let snapshots = lossy.compactMap(\.value)
        return snapshots.map { snapshot in
            let task = snapshot.task
            // 0.4.2 #23：上次会话退出时仍在运行的任务 = 被中断。恢复成明确的「已中断」失败态，
            // 不再在历史里永远转圈 —— 这本身也是「上次没退干净」的可见痕迹。
            if task.status.isRunning {
                task.status = .failed(L10n.text("tasks.interruptedPreviousSession"))
                if task.finishedAt == nil { task.finishedAt = task.startedAt }
            }
            return task
        }
    }
}

/// 队列管理②:重归档任务的并发调度器 —— 同时运行的重任务不超过用户上限(0 = 不限),
/// 超出的排队等待(任务在活动中心保持可见,状态行显示「等待空闲槽」,随时可取消)。
/// 公平 FIFO;上限实时读偏好,调大后下一次 release 按新上限放行。
@MainActor
final class HeavyTaskScheduler {
    static let shared = HeavyTaskScheduler()

    /// 算「重任务」的归档操作 —— 大 CPU / 大 IO,同时跑太多互相拖慢。compare(纯列表)等轻活不进队。
    nonisolated static let heavyKinds: Set<OperationTask.Kind> = [
        .extract, .compress, .create, .convert, .test, .hash, .split, .combine, .benchmark, .duplicate
    ]

    private var runningCount = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    private var limit: Int { AppPreferences.heavyTaskConcurrencyLimit }

    /// 等待中的任务数(调度展示用)。
    var waitingCount: Int { waiters.count }

    /// 0.4.4 F4:队列级暂停 —— 暂停期间不放行任何新重任务(两条快路径 + release 补放全部入队等待)。
    /// 已在跑的任务不归这里管(TaskCenter.setQueuePaused 对它们逐个 SIGSTOP)。不持久化。
    private(set) var isQueuePaused = false

    func pauseQueue() {
        isQueuePaused = true
    }

    func resumeQueue() {
        isQueuePaused = false
        dispenseWaiters()
    }

    /// 取槽:有空位立即返回;满了挂起直到有任务收尾。任务被取消时以 CancellationError 恢复。
    /// **两条快路径都必须过暂停闸门** —— 否则暂停期间 unlimited / 有空位的新任务直接穿过去。
    func acquire(taskID: UUID) async throws {
        if !isQueuePaused {
            guard limit > 0 else {
                runningCount += 1
                return
            }
            if runningCount < limit {
                runningCount += 1
                return
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((taskID, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                Self.shared.cancelWaiter(taskID)
            }
        }
    }

    /// 还槽:按 FIFO 放行下一个等待者(若调小了上限,等到 runningCount 降到新上限以下才放)。
    func release() {
        runningCount = max(0, runningCount - 1)
        dispenseWaiters()
    }

    /// 按 FIFO 放行等待者直到上限;队列暂停期间一个都不放(恢复时统一补放)。
    private func dispenseWaiters() {
        guard !isQueuePaused else { return }
        while !waiters.isEmpty, limit == 0 || runningCount < limit {
            let next = waiters.removeFirst()
            runningCount += 1
            next.continuation.resume()
        }
    }

    /// 等待中被取消:从队列摘除并抛 CancellationError(已被放行的自然找不到,no-op)。
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// `nonisolated`(本组持久化类型同此):CLI companion 进程在非主隔离上下文构造/编码这些记录,
/// 历史持久化也在后台队列编码 —— 隔离开销与限制都不需要。读 @MainActor 状态的成员单独标回 @MainActor。
private nonisolated struct PersistedTask: Codable {
    let id: UUID
    let category: OperationTask.Category
    let kind: OperationTask.Kind
    /// 0.4.4 F1:任务来源。Optional —— 旧版本存的 JSON 没有这个键,decodeIfPresent 容错(nil → .app)。
    let source: OperationTask.Source?
    let title: String
    let detail: String?
    let startedAt: Date
    let status: PersistedStatus
    let finishedAt: Date?
    let progress: PersistedProgress
    let details: PersistedDetails?
    // 哈希结果 / 粘贴·移动的哈希对比：持久化下来，重启后历史里仍能展开看格式化详情。
    // 都用 Optional：旧版本存的 JSON 没有这两个键，可选才能 decodeIfPresent 容错，不至于整段历史解码失败丢失。
    let hashReport: HashReport?
    let hashComparisons: [HashOverwriteResult]?
    let transferLog: [TransferLogEntry]?
    /// 0.4.4(用户报「重启后比较详情丢了」):归档比较的结构化结果一并落盘。Optional 容错同上。
    let diffReport: ArchiveDiffReport?
    /// 0.4.4:报告类任务(发布检查/元数据)的报告本体 —— 重启后「打开报告」仍可用。
    let reportAttachment: TaskReportAttachment?
    /// 0.4.4:失败红点「看过即灭」标记。
    let failureSeen: Bool?

    @MainActor
    init(task: OperationTask) {
        id = task.id
        category = task.category
        kind = task.kind
        source = task.source
        title = task.title
        detail = task.detail
        startedAt = task.startedAt
        status = PersistedStatus(status: task.status)
        finishedAt = task.finishedAt
        progress = PersistedProgress(progress: task.progress)
        if let session = task.detailsSession {
            details = PersistedDetails(title: session.title, rawOutput: session.rawOutput, finishedAt: session.finishedAt)
        } else {
            details = nil
        }
        hashReport = task.hashReport
        hashComparisons = task.hashComparisons.isEmpty ? nil : task.hashComparisons
        transferLog = task.transferLog.isEmpty ? nil : task.transferLog
        // 体积闸:条目过万的比较不落盘(UserDefaults 历史不该被一次 diff 撑爆)——
        // 这类任务跟以前一样只在本次会话可看详情。
        diffReport = (task.diffReport?.totalEntryCount ?? 0) <= 10_000 ? task.diffReport : nil
        reportAttachment = task.reportAttachment
        failureSeen = task.failureSeen ? true : nil
    }

    /// CLI companion 的直构 init —— CLI 进程里没有(也不能有)@MainActor 的 OperationTask,
    /// 记录字段直接给。显式 init(task:) 抑制了 memberwise,这里补一份。
    nonisolated init(
        id: UUID,
        category: OperationTask.Category,
        kind: OperationTask.Kind,
        source: OperationTask.Source?,
        title: String,
        detail: String?,
        startedAt: Date,
        status: PersistedStatus,
        finishedAt: Date?,
        progress: PersistedProgress,
        details: PersistedDetails?,
        hashReport: HashReport?,
        hashComparisons: [HashOverwriteResult]?,
        transferLog: [TransferLogEntry]?,
        diffReport: ArchiveDiffReport? = nil,
        reportAttachment: TaskReportAttachment? = nil,
        failureSeen: Bool? = nil
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.source = source
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.status = status
        self.finishedAt = finishedAt
        self.progress = progress
        self.details = details
        self.hashReport = hashReport
        self.hashComparisons = hashComparisons
        self.transferLog = transferLog
        self.diffReport = diffReport
        self.reportAttachment = reportAttachment
        self.failureSeen = failureSeen
    }

    @MainActor
    var task: OperationTask {
        let restored = OperationTask(
            id: id,
            category: category,
            kind: kind,
            source: source ?? .app,
            title: title,
            detail: detail,
            startedAt: startedAt,
            cancellable: false,
            detailsSession: details?.session,
            status: status.status,
            progress: progress.progress,
            finishedAt: finishedAt
        )
        restored.hashReport = hashReport
        restored.hashComparisons = hashComparisons ?? []
        restored.transferLog = transferLog ?? []
        restored.diffReport = diffReport
        restored.reportAttachment = reportAttachment
        restored.failureSeen = failureSeen ?? false
        return restored
    }
}

private nonisolated struct PersistedProgress: Codable {
    let fraction: Double?
    let currentFile: String?
    let statusText: String?
    let completedUnitCount: Int?
    let totalUnitCount: Int?

    nonisolated init(progress: ArchiveProgressState) {
        fraction = progress.fraction
        currentFile = progress.currentFile
        statusText = progress.statusText
        completedUnitCount = progress.completedUnitCount
        totalUnitCount = progress.totalUnitCount
    }

    var progress: ArchiveProgressState {
        ArchiveProgressState(
            fraction: fraction,
            currentFile: currentFile,
            statusText: statusText,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }
}

private nonisolated struct PersistedDetails: Codable {
    let title: String
    let rawOutput: String
    let finishedAt: Date?

    /// 显式 nonisolated 构造 —— CLI 进程在非主隔离上下文组装记录(默认 MainActor 隔离下,
    /// 隐式 memberwise init 会被钉在主 actor 上)。
    nonisolated init(title: String, rawOutput: String, finishedAt: Date?) {
        self.title = title
        self.rawOutput = rawOutput
        self.finishedAt = finishedAt
    }

    @MainActor
    var session: ArchiveOperationDetailsSession {
        ArchiveOperationDetailsSession(title: title, rawOutput: rawOutput, finishedAt: finishedAt)
    }
}

private nonisolated enum PersistedStatus: Codable {
    case succeeded(URL?)
    case skipped(String?)
    case failed(String)
    case cancelled

    init(status: OperationTask.Status) {
        switch status {
        case .running:
            self = .cancelled
        case .succeeded(let url):
            self = .succeeded(url)
        case .skipped(let reason):
            self = .skipped(reason)
        case .failed(let message):
            self = .failed(message)
        case .cancelled:
            self = .cancelled
        }
    }

    var status: OperationTask.Status {
        switch self {
        case .succeeded(let url):
            return .succeeded(url)
        case .skipped(let reason):
            return .skipped(reason)
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return .cancelled
        }
    }
}

// MARK: - 只读历史查询面(App Intents)

/// 一条历史任务的**只读快照**,只含 App Intents 实体需要的轻量元数据。
/// 不是 `PersistedTask` 的镜像 DTO:`PersistedTask` 文件私有、@MainActor 构造、且驮着
/// 哈希 / diff / 报告等重负载,不适合做跨上下文查询面;本快照只暴露查询所需字段。
/// `.running` 在落盘时已被 `PersistedStatus(status:)` 归并为 `.cancelled`,故 outcome 只有 4 态。
nonisolated struct ArchiveTaskSnapshot: Identifiable, Sendable {
    enum Outcome: String, Sendable { case succeeded, skipped, failed, cancelled }
    let id: UUID
    let kind: OperationTask.Kind
    let source: OperationTask.Source
    let title: String
    let detail: String?
    let startedAt: Date
    let finishedAt: Date?
    let outcome: Outcome
    let failureMessage: String?

    nonisolated init(
        id: UUID, kind: OperationTask.Kind, source: OperationTask.Source,
        title: String, detail: String?, startedAt: Date, finishedAt: Date?,
        outcome: Outcome, failureMessage: String?
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failureMessage = failureMessage
    }

    /// 从一条**已收尾**的 `OperationTask` 直建快照(完成时增量索引 Spotlight 用)。
    /// 仍在运行(`.running`)→ 返回 nil(只索引终态)。读 @MainActor 的 OperationTask,故标 @MainActor。
    @MainActor
    init?(task: OperationTask) {
        let outcome: Outcome
        var failure: String?
        switch task.status {
        case .succeeded: outcome = .succeeded
        case .skipped: outcome = .skipped
        case .failed(let message): outcome = .failed; failure = message
        case .cancelled: outcome = .cancelled
        case .running: return nil
        }
        self.init(
            id: task.id, kind: task.kind, source: task.source,
            title: task.title, detail: task.detail, startedAt: task.startedAt,
            finishedAt: task.finishedAt, outcome: outcome, failureMessage: failure
        )
    }
}

/// 活动历史的 **nonisolated 只读查询入口** —— 直接读 `activityHistory` 的 UserDefaults JSON,
/// 不触碰 @MainActor 的 `TaskCenter` 运行态。App Intents 的 `ArchiveTaskEntity` 据此查询。
nonisolated enum ActivityHistoryStore {
    /// 逐条 lossy 解码(与 `TaskCenter.loadPersistedHistory` 同口径:坏的丢、好的留)。
    private struct LossyTask: Decodable {
        let value: PersistedTask?
        init(from decoder: Decoder) throws { value = try? PersistedTask(from: decoder) }
    }

    static func snapshot() -> [ArchiveTaskSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.Key.activityHistory),
              let lossy = try? JSONDecoder().decode([LossyTask].self, from: data) else { return [] }
        return lossy.compactMap(\.value).map(makeSnapshot(_:))
    }

    static func lookup(id: UUID) -> ArchiveTaskSnapshot? {
        snapshot().first { $0.id == id }
    }

    /// 入参用了文件私有的 `PersistedTask`,映射只在本文件内发生。
    private static func makeSnapshot(_ task: PersistedTask) -> ArchiveTaskSnapshot {
        let outcome: ArchiveTaskSnapshot.Outcome
        var failure: String?
        switch task.status {
        case .succeeded: outcome = .succeeded
        case .skipped: outcome = .skipped
        case .failed(let message): outcome = .failed; failure = message
        case .cancelled: outcome = .cancelled
        }
        return ArchiveTaskSnapshot(
            id: task.id,
            kind: task.kind,
            source: task.source ?? .app,
            title: task.title,
            detail: task.detail,
            startedAt: task.startedAt,
            finishedAt: task.finishedAt,
            outcome: outcome,
            failureMessage: failure
        )
    }
}
