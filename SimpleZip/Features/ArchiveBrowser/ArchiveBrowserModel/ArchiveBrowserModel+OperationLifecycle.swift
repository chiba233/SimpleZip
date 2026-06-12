//
//  ArchiveBrowserModel+OperationLifecycle.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  长任务的统一外壳：startOperationTask / runArchiveTask / 失败 alert / Details 抽屉 / 取消。
//

import AppKit
import Foundation

/// 后端命令输出节流转发器（前后端分离的关键）。
///
/// 后端在后台线程逐块吐输出（大归档每文件一行，几万行）。如果每块都 `Task { @MainActor }` 去改
/// @Published 字符串，会几万次刷主 actor + 触发 SwiftUI 重渲染 → 解压时 GUI 卡死。
/// 这里：后端线程只往 lock 缓冲塞（摊还 O(1)，并自截断到尾部），主 actor 最多每 ~500ms 拉一次刷给 session
/// —— 详情面板是给人看的日志，不需要高频刷新；500ms 已经够实时，还能让渲染几十万字符的 Text 不那么吃力。
// nonisolated：app target 默认 MainActor，不标的话整类会被推成 MainActor，
// 后端线程的 append/submit 就没法调了（同 FolderWatcher 的处理）。flush 单独标 @MainActor 改 @Published。
// 设为 internal 供 Finder 自动解压浮窗（ExternalExtract）复用 —— 让它的任务在活动中心也能看「命令输出」。
nonisolated final class ThrottledDetailsOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var flushScheduled = false
    private let session: ArchiveOperationDetailsSession
    private let maxCharacters = 200_000 // pending 缓冲的内存护栏（按字符，便宜）
    private let maxLines = 500           // 详情面板最终只留最近 500 行

    init(session: ArchiveOperationDetailsSession) {
        self.session = session
    }

    /// 后端线程调用：只塞缓冲 + 必要时排一次节流 flush。
    func append(_ chunk: String) {
        lock.lock()
        pending += chunk
        if pending.count > maxCharacters {
            pending = String(pending.suffix(maxCharacters))
        }
        let shouldSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 详情日志 500ms 刷一次足够
            self.flush()
        }
    }

    @MainActor func flushNow() {
        flush()
    }

    @MainActor private func flush() {
        lock.lock()
        let chunk = pending
        pending = ""
        flushScheduled = false
        lock.unlock()
        guard !chunk.isEmpty else { return }
        session.appendCapped(chunk, maxLines: maxLines)
    }
}

/// 进度节流：后端逐文件回调进度（几万次），只保留最新值，主 actor 最多每 ~80ms 应用一次，避免状态栏被刷爆。
/// 0.3.0：从 `private` 放宽到模块内可见——拖出解压（+CreateExtract 的 `exportArchiveItem`）也复用它做进度节流。
nonisolated final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ArchiveProgressState?
    private var scheduled = false
    private let apply: @MainActor (ArchiveProgressState) -> Void

    init(apply: @escaping @MainActor (ArchiveProgressState) -> Void) {
        self.apply = apply
    }

    func submit(_ state: ArchiveProgressState) {
        lock.lock()
        latest = state
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.flush()
        }
    }

    @MainActor private func flush() {
        lock.lock()
        let state = latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let state { apply(state) }
    }
}

extension ArchiveBrowserModel {
    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        operationRunner.cancel()
    }

    func showOperationDetails() {
        guard operationDetailsSession != nil else { return }
        isShowingOperationDetails = true
    }

    func dismissOperationFailureAlert() {
        operationFailureFullMessage = nil
    }

    func openOperationDetailsFromFailureAlert() {
        guard operationDetailsSession != nil else { return }
        isShowingOperationDetails = true
        dismissOperationFailureAlert()
    }

    func handleOperationDetailsPresentationChange(_ isPresented: Bool) {
        guard !isPresented else { return }
        if operationDetailsSession?.isRunning == false {
            operationDetailsSession = nil
        }
        isShowingOperationDetails = false
    }

    func closeOperationDetails() {
        if operationDetailsSession?.isRunning == false {
            operationDetailsSession = nil
        }
        isShowingOperationDetails = false
    }

    private func prepareOperationDetailsSession(title: String, showsDetails: Bool) -> ArchiveOperationDetailsSession? {
        // **始终**建好 session 并抓后端输出 —— 这样即使用户没在选项对话框里勾「显示详情」，
        // 操作进行中也能从底部状态栏的「详情」按钮按需打开（用户反馈：开始后反悔想看详情却没入口）。
        // 只有预先勾了 `showsDetails` 才自动弹出面板；没勾就只是默默抓着，等用户主动点。
        let session = ArchiveOperationDetailsSession(title: title)
        operationDetailsSession = session
        isShowingOperationDetails = showsDetails
        return session
    }

    private func makeOperationOutputObserver(for session: ArchiveOperationDetailsSession?) -> (@Sendable (String) -> Void)? {
        guard let session else { return nil }
        // 经节流转发器：后端线程零主-actor 跳转地塞缓冲，UI 最多每 ~150ms 刷一次（前后端分离）。
        let forwarder = ThrottledDetailsOutput(session: session)
        return { chunk in forwarder.append(chunk) }
    }

    private func finishOperationDetailsSession(_ session: ArchiveOperationDetailsSession?) {
        session?.finishedAt = Date()
    }

    private func preserveFailureDetailsIfNeeded(title: String, error: Error) {
        guard operationDetailsSession == nil else { return }
        let session = ArchiveOperationDetailsSession(title: title)
        session.append(error.localizedDescription)
        session.finishedAt = Date()
        operationDetailsSession = session
    }

    func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        startOperationTask(cancellable: cancellable) { _ in
            await operation()
        }
    }

    func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor (UUID) async -> Void) {
        operationRunner.start(
            cancellable: cancellable,
            onCancellableChange: { [weak self] value in self?.canCancelCurrentOperation = value },
            operation: operation
        )
    }

    /// 0.4.3 #2：写引擎排队等「同包写锁」时的统一上报 —— 任务详情日志打一行 + 状态栏显示
    /// 「等待归档释放」。写操作的 onWaitForLock 都用它,免得六个调用点各抄一遍。
    nonisolated func writeLockWaitReporter(_ observer: (@Sendable (String) -> Void)?) -> @Sendable () -> Void {
        { [weak self] in
            let message = L10n.text("status.waitingForArchiveLock")
            observer?(message + "\n")
            guard let self else { return }   // 先解成不可变强引用,Task 才能安全捕获(Swift 6 并发口径)
            Task { @MainActor in
                self.status = message
            }
        }
    }

    func startManagedArchiveTask(
        title: String,
        kind: OperationTask.Kind = .extract,
        showsDetails: Bool,
        cancellable: Bool = true,
        successStatus: String? = nil,
        refreshOnSuccess: (() -> Void)? = nil,
        // 成功后、归档进历史前的钩子 —— 给调用方往任务上挂「逐文件结果」(transferLog) / detail，
        // 让活动中心展开后有「新增 N 项」那样的密度（加密 / 创建签名清单用）。默认 nil = 老行为不变。
        onSucceeded: ((OperationTask) -> Void)? = nil,
        // 0.4.2 #21:「重新运行」动作 —— 用同样的输入把整个操作再跑一遍。nil = 该任务不可重跑。
        rerunAction: (() -> Void)? = nil,
        operation: @escaping (UUID?, @escaping @Sendable (ArchiveProgressState) -> Void, (@Sendable (String) -> Void)?) async throws -> Void
    ) {
        let detailsSession = ArchiveOperationDetailsSession(title: title)
        let detailsOutput = ThrottledDetailsOutput(session: detailsSession)
        let outputObserver: @Sendable (String) -> Void = { chunk in
            detailsOutput.append(chunk)
        }
        let operationID = UUID()
        let taskCenter = TaskCenter.shared
        let operationTask = taskCenter.begin(
            category: .archive,
            kind: kind,
            title: title,
            cancellable: cancellable,
            detailsSession: detailsSession,
            operationID: operationID
        )
        operationTask.progress = ArchiveProgressState(fraction: 0, currentFile: nil)
        operationTask.rerun = rerunAction
        if showsDetails {
            ActivityWindowController.shared.show(category: .archive)
        }

        let progressCoalescer = ProgressCoalescer { [weak operationTask] progress in
            guard let operationTask, operationTask.status.isRunning else { return }
            operationTask.progress = progress
            taskCenter.notifyTaskChanged()
        }

        var swiftTask: Task<Void, Never>?
        operationTask.cancel = cancellable ? {
            swiftTask?.cancel()
            ArchiveService.cancelRunningCommand(operationID: operationID)
        } : nil

        // 队列管理③:暂停 / 继续 —— 只挂给后端驱动的种类(SIGSTOP 冻结子进程;进程间的
        // Swift 阶段走完当前步骤后,下一个子进程启动即被补停)。暂停态只改任务自己的发布属性。
        if cancellable, OperationTask.pausableKinds.contains(kind) {
            operationTask.pause = { [weak operationTask] in
                guard let operationTask, operationTask.status.isRunning, !operationTask.isPaused else { return }
                ArchiveService.suspendRunningCommand(operationID: operationID)
                operationTask.isPaused = true
                operationTask.progress.statusText = L10n.text("tasks.paused")
                taskCenter.notifyTaskChanged()
            }
            operationTask.resume = { [weak operationTask] in
                guard let operationTask, operationTask.isPaused else { return }
                ArchiveService.resumeRunningCommand(operationID: operationID)
                operationTask.isPaused = false
                operationTask.progress.statusText = nil
                taskCenter.notifyTaskChanged()
            }
        }

        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            status = title
            do {
                // 队列管理②:重任务先取并发槽 —— 超过上限的排队等待(活动中心可见、状态行
                // 显示等待、可取消;与写锁/密码中心同一套 statusText 等待 idiom)。
                let usesSlot = HeavyTaskScheduler.heavyKinds.contains(kind)
                if usesSlot {
                    operationTask.isAwaitingSlot = true
                    operationTask.progress = ArchiveProgressState(
                        fraction: nil, currentFile: nil,
                        statusText: L10n.text("tasks.waitingForSlot")
                    )
                    taskCenter.notifyTaskChanged()
                    do {
                        try await HeavyTaskScheduler.shared.acquire(taskID: operationID)
                    } catch {
                        operationTask.isAwaitingSlot = false
                        throw error
                    }
                    operationTask.isAwaitingSlot = false
                    operationTask.progress = ArchiveProgressState(fraction: 0, currentFile: nil)
                    taskCenter.notifyTaskChanged()
                }
                defer {
                    if usesSlot { HeavyTaskScheduler.shared.release() }
                }
                try await operation(operationID, { progress in
                    progressCoalescer.submit(progress)
                }, outputObserver)
                progressCoalescer.submit(ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.done")))
                detailsOutput.flushNow()
                detailsSession.finishedAt = Date()
                onSucceeded?(operationTask)
                taskCenter.finish(operationTask, outcome: .succeeded(nil))
                if let successStatus {
                    status = successStatus
                } else {
                    status = L10n.text("status.done")
                }
                // 归档操作（创建 / 解压 / 测试 / 哈希）成功完成 → 提示音，与粘贴 / 移动一致。
                SystemSound.operationComplete?.play()
                refreshOnSuccess?()
            } catch is CancellationError {
                detailsOutput.flushNow()
                detailsSession.finishedAt = Date()
                taskCenter.finish(operationTask, outcome: .cancelled)
                status = L10n.text("status.cancelled")
            } catch {
                detailsOutput.flushNow()
                if detailsSession.rawOutput.isEmpty {
                    detailsSession.append(error.localizedDescription)
                }
                detailsSession.finishedAt = Date()
                taskCenter.finish(operationTask, outcome: .failed(error.localizedDescription))
                status = L10n.text("status.failed")
            }
        }
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    func runArchiveTask(
        _ workingStatus: String,
        initialProgress: ArchiveProgressState = ArchiveProgressState(fraction: 0, currentFile: nil),
        operation: @escaping (@escaping @Sendable (ArchiveProgressState) -> Void) async throws -> Void
    ) async -> Bool {
        isWorking = true
        errorMessage = nil
        operationProgress = initialProgress
        status = workingStatus
        defer {
            isWorking = false
            operationProgress = ArchiveProgressState()
        }

        do {
            // 进度经节流器：后端逐文件回调（大归档几万次）只更新最新值，UI 最多 ~80ms 应用一次，
            // 否则状态栏被刷爆 → 解压卡死。`guard isWorking` 让结束后的迟到 flush 不覆盖最终状态。
            let progressCoalescer = ProgressCoalescer { [weak self] progress in
                guard let self, self.isWorking else { return }
                self.operationProgress = progress
                if let statusText = progress.statusText, !statusText.isEmpty {
                    self.status = statusText
                } else if let currentFile = progress.currentFile, !currentFile.isEmpty {
                    self.status = currentFile
                }
            }
            try await operation { progress in
                progressCoalescer.submit(progress)
            }
            status = L10n.text("status.done")
            // 成功且用户全程没打开过详情面板 → 收掉 session，保持空闲状态栏干净
            // （运行中随时可点「详情」打开；失败的 session 在下面 catch 里保留，便于排查）。
            if !isShowingOperationDetails {
                operationDetailsSession = nil
            }
            return true
        } catch is CancellationError {
            errorMessage = nil
            status = L10n.text("status.cancelled")
            if !isShowingOperationDetails {
                operationDetailsSession = nil
            }
            return false
        } catch {
            preserveFailureDetailsIfNeeded(title: workingStatus, error: error)
            if isShowingOperationDetails && operationDetailsSession != nil {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
            status = L10n.text("status.failed")
            return false
        }
    }
}
