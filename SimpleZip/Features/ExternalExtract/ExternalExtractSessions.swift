//
//  ExternalExtractSessions.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ExternalExtractWindow.swift 切出的浮窗会话（单任务 / 批量 / 准备 / 创建），纯移动、零行为变更。
//

import AppKit
import Combine
import SwiftUI

/// 单次解压会话 —— 关掉 controller 即销毁。
@MainActor
final class ExternalExtractSession: ObservableObject {
    enum Status: Equatable {
        case running
        case succeeded(URL)
        case failed(String)
    }

    let archiveURL: URL
    /// 浮窗标题显示名（`.siz` 自动解压时显示原 `.siz` 名而非内层 archive 名）。
    let displayName: String
    private let destinationDirectoryOverride: URL?
    private let outputBaseNameOverride: String?
    private let cleanupDirectory: URL?
    @Published var status: Status = .running
    @Published var fraction: Double? = nil
    @Published var currentFileName: String? = nil
    @Published var statusText: String

    /// 浮窗「在主窗口打开」回调（controller 注入）—— 满足「在独立窗口内可以选择拉起主窗口」。
    var onOpenInMainWindow: (() -> Void)?

    private let operationID = UUID()
    private let coordinator = ArchiveExtractionCoordinator(fileManager: .default)
    /// 外层运行任务句柄 —— 取消时连它一起 cancel（与批量会话的 isCancelled 对齐）：
    /// 7zz 已结束、正在 staging merge / 移动阶段时已无活跃 backend 进程，光取消子进程停不下来，
    /// 取消 Task 才能在协作点中止后续阶段。
    private var runTask: Task<Void, Never>?

    init(
        archiveURL: URL,
        destinationDirectoryOverride: URL? = nil,
        outputBaseNameOverride: String? = nil,
        displayName: String? = nil,
        cleanupDirectory: URL? = nil
    ) {
        self.archiveURL = archiveURL
        self.destinationDirectoryOverride = destinationDirectoryOverride
        self.outputBaseNameOverride = outputBaseNameOverride
        let name = displayName ?? archiveURL.lastPathComponent
        self.displayName = name
        self.cleanupDirectory = cleanupDirectory
        // `status.extracting` 是带 %@ 的格式串，必须 format 填名字 —— 之前用 L10n.text 直出导致 UI 显示「正在解压 %@」。
        self.statusText = L10n.format("status.extracting", name)
    }

    /// 启动并持有运行任务（让 cancel 能连外层 Task 一起取消）。
    func start(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void = {}) {
        runTask = Task { [weak self] in
            await self?.run(onClose: onClose, onAttention: onAttention)
        }
    }

    func cancel() {
        runTask?.cancel()
        ArchiveService.cancelRunningCommand(operationID: operationID)
    }

    private func run(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void = {}) async {
        // `.siz` unwrap 暂存根：无论成功失败都清掉（含可能的解密产物）。
        defer { if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) } }
        // 接入活动中心：Finder 自动解压也建一个归档任务，进度同步喂进去，可在活动中心查看 / 取消 / 看命令输出。
        let details = ArchiveOperationDetailsSession(title: displayName)
        let detailsOutput = ThrottledDetailsOutput(session: details)
        let task = TaskCenter.shared.begin(
            category: .archive, kind: .extract, source: .finder, title: displayName, cancellable: true,
            detailsSession: details, operationID: operationID
        )
        task.cancel = { [weak self] in self?.cancel() }
        do {
            let target = try await ExternalExtractRunner.extract(
                archiveURL: archiveURL,
                destinationDirectoryOverride: destinationDirectoryOverride,
                outputBaseNameOverride: outputBaseNameOverride,
                operationID: operationID,
                coordinator: coordinator,
                onStatus: { [weak self] text in self?.statusText = text; task.progress.statusText = text },
                onProgress: { [weak self] fraction, file in
                    self?.fraction = fraction
                    self?.currentFileName = file
                    task.progress.fraction = fraction
                    task.progress.currentFile = file
                },
                outputObserver: { detailsOutput.append($0) }
            )
            status = .succeeded(target)
            detailsOutput.flushNow()   // 先把节流缓冲刷进 session，finish() 会立刻持久化历史，否则末尾输出丢失
            TaskCenter.shared.finish(task, outcome: .succeeded(target))
            SystemSound.operationComplete?.play()
            NSWorkspace.shared.activateFileViewerSelecting([target])
            // 1.2s 后自动关 —— 让用户看到「完成」反馈但不挡屏幕太久。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } catch is CancellationError {
            // 用户主动取消 ≠ 失败。直接关掉浮窗，不弹「解压失败 CancellationError」。
            detailsOutput.flushNow()
            TaskCenter.shared.finish(task, outcome: .cancelled)
            onClose()
        } catch {
            // 真失败不自动关；用户可能想看错误 + 复制路径。把浮窗带到最前，确保后台时错误不被埋。
            status = .failed(error.localizedDescription)
            detailsOutput.flushNow()
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            onAttention()
        }
    }
}

/// 批量解压会话：串行处理多个压缩包，一个取消、一个失败汇总。
@MainActor
final class ExternalExtractBatchSession: ObservableObject {
    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    let archiveURLs: [URL]
    @Published var fraction: Double? = nil
    @Published var currentFileName: String? = nil
    @Published var statusText: String
    @Published var isFinished = false
    @Published var succeeded: [URL] = []
    @Published var failures: [Failure] = []

    /// 用户主动取消 —— 停止推进剩余项，并 cancel 当前正在跑的命令。
    private var isCancelled = false
    private var currentOperationID: UUID?
    /// 外层运行任务句柄 —— 取消时连它一起 cancel（与单任务会话 `ExternalExtractSession.runTask` 对齐）：
    /// 当前项的 7z 已结束、正处于 staging merge / 移动阶段时已无活跃 backend 进程，光 cancelRunningCommand 停不下来，
    /// 必须 cancel 这个 Task 才能让 merge 的协作取消点（Task.isCancelled）中止后续阶段。
    private var runTask: Task<Void, Never>?
    private let coordinator = ArchiveExtractionCoordinator(fileManager: .default)

    var total: Int { archiveURLs.count }

    init(archiveURLs: [URL]) {
        self.archiveURLs = archiveURLs
        self.statusText = L10n.format("externalExtract.batch.progress", 1, archiveURLs.count, archiveURLs.first?.lastPathComponent ?? "")
    }

    /// 启动并持有运行任务（让 cancel 能连外层 Task 一起取消）。
    func start(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void) {
        runTask = Task { [weak self] in
            await self?.run(onClose: onClose, onAttention: onAttention)
        }
    }

    func cancel() {
        isCancelled = true
        runTask?.cancel()
        if let id = currentOperationID { ArchiveService.cancelRunningCommand(operationID: id) }
    }

    private func run(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void) async {
        for (index, url) in archiveURLs.enumerated() {
            if isCancelled { break }
            fraction = nil
            currentFileName = nil
            statusText = L10n.format("externalExtract.batch.progress", index + 1, total, url.lastPathComponent)
            let opID = UUID()
            currentOperationID = opID
            // 每个压缩包在活动中心建独立任务，可逐个查看 / 取消 / 看命令输出。
            let details = ArchiveOperationDetailsSession(title: url.lastPathComponent)
            let detailsOutput = ThrottledDetailsOutput(session: details)
            let task = TaskCenter.shared.begin(
                category: .archive, kind: .extract, source: .finder, title: url.lastPathComponent, cancellable: true,
                detailsSession: details, operationID: opID
            )
            task.cancel = { [weak self] in self?.cancel() }
            do {
                let target = try await ExternalExtractRunner.extract(
                    archiveURL: url,
                    destinationDirectoryOverride: nil,
                    outputBaseNameOverride: nil,
                    operationID: opID,
                    coordinator: coordinator,
                    onStatus: { _ in },   // 批量保留「N / M：名字」作标题，忽略 per-file 状态文案
                    onProgress: { [weak self] fraction, file in
                        self?.fraction = fraction
                        self?.currentFileName = file
                        task.progress.fraction = fraction
                        task.progress.currentFile = file
                    },
                    outputObserver: { detailsOutput.append($0) }
                )
                succeeded.append(target)
                detailsOutput.flushNow()   // 刷尽节流缓冲再 finish，避免历史快照丢末尾输出
                TaskCenter.shared.finish(task, outcome: .succeeded(target))
            } catch is CancellationError {
                // 取消当前项 → 整批停止，不记为失败。
                detailsOutput.flushNow()
                TaskCenter.shared.finish(task, outcome: .cancelled)
                break
            } catch {
                detailsOutput.flushNow()
                TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
                failures.append(Failure(name: url.lastPathComponent, message: error.localizedDescription))
            }
        }
        currentOperationID = nil
        isFinished = true

        // 成功的都 reveal 出来。
        if !succeeded.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(succeeded)
        }
        if !isCancelled && failures.isEmpty {
            SystemSound.operationComplete?.play()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } else {
            // 有失败 / 被取消：保留浮窗显示汇总，带到前台。
            onAttention()
        }
    }
}

/// `.siz`/`.szs` 在浮窗里「准备阶段」（unwrap + 验签 / peek）的占位会话 —— 校验中显进度条，
/// 出错显错误 + 「在主窗口打开」逃生入口。准备完成后 controller 会把浮窗内容替换成解压进度 / 签名 sheet。
@MainActor
final class ExternalPrepareSession: ObservableObject {
    enum Phase: Equatable {
        case verifying
        case succeeded(URL)
        case failed(String)
    }

    let displayName: String
    @Published var phase: Phase = .verifying
    /// controller 注入：浮窗「在主窗口打开」（准备失败时的逃生入口）。
    var onOpenInMainWindow: (() -> Void)?

    init(displayName: String) {
        self.displayName = displayName
    }

    func succeed(_ url: URL) {
        phase = .succeeded(url)
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }
}

/// Finder 一键创建会话 —— 和 `ExternalExtractSession` 同构：接活动中心、独立浮窗、压完自动关窗。
@MainActor
final class ExternalCreateSession: ObservableObject {
    enum Status: Equatable {
        case running
        case succeeded(URL)
        case failed(String)
    }

    let displayName: String
    private let files: [URL]
    private let destination: URL
    private let options: ArchiveCreationOptions
    @Published var status: Status = .running
    @Published var fraction: Double? = nil
    @Published var currentFileName: String? = nil
    @Published var statusText: String

    private let operationID = UUID()
    private var runTask: Task<Void, Never>?

    init(format: ArchiveCreateFormat, files: [URL], destination: URL) {
        self.files = files
        self.destination = destination
        // #115 按格式默认值：Finder / NSService 一键压缩按**目标格式**套用该格式在 设置→压缩→默认值 里**启用**的
        // 那些选项（没启用的字段保持内建默认；密码 / GPG 私钥不入库，见 sanitizedForStorage()）。
        var options = ArchiveCreationOptions()
        options.format = format
        if let preset = CompressionDefaultsStore().preset(for: format), preset.enabled {
            preset.apply(to: &options)
        }
        // GPG 签名是创建对话框里的交互项（要选签名 key）。预设可能带 gpgSign=true（sanitized 保留意图但抹掉 key），
        // 一键「简化压缩」是无对话框路径，不该用 default-key 静默签名 / 弹 passphrase —— 清掉，只走纯压缩。
        options.gpgSign = false
        options.gpgSigningKeyFingerprint = ""
        options.gpgRecipientFingerprints = []
        options.gpgSymmetricPassphrase = ""
        options.gpgDeliveryNote = ""
        // 预设密码：开了「使用预设密码」且该格式支持加密（ZIP / 7z；TAR.GZ 不支持）→ 自动建密码，
        // 与解压侧「优先用预设密码」对称。无对话框的 Finder 一键创建也照此自动加密。
        if AppPreferences.hasUsablePresetPassword, format.supportsPassword {
            options.password = AppPreferences.presetPassword
            options.passwordConfirmation = AppPreferences.presetPassword
        }
        self.options = options
        self.displayName = destination.lastPathComponent
        self.statusText = L10n.format("status.creating", destination.lastPathComponent)
    }

    func start(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void = {}) {
        runTask = Task { [weak self] in
            await self?.run(onClose: onClose, onAttention: onAttention)
        }
    }

    func cancel() {
        runTask?.cancel()
        ArchiveService.cancelRunningCommand(operationID: operationID)
    }

    private func run(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void) async {
        // 接活动中心：和解压一样建一个归档任务，进度 / 命令输出喂进去，可查看 / 取消 / 看日志。
        let details = ArchiveOperationDetailsSession(title: displayName)
        let detailsOutput = ThrottledDetailsOutput(session: details)
        let task = TaskCenter.shared.begin(
            category: .archive, kind: .compress, source: .finder, title: displayName, cancellable: true,
            detailsSession: details, operationID: operationID
        )
        task.cancel = { [weak self] in self?.cancel() }
        do {
            try await ArchiveService.createArchive(
                from: files,
                destination: destination,
                options: options,
                operationID: operationID,
                progress: { [weak self, weak task] state in
                    // @Sendable 进度闭包弱捕获 self / task（都是 MainActor 隔离=Sendable）。在跳进内层 Task 之前
                    // 先把弱引用解开 / 快照成局部 let —— 否则内层并发 Task 直接引用外层弱 var 在 Swift 6 是错误。
                    guard let self else { return }
                    let task = task
                    Task { @MainActor in
                        self.fraction = state.fraction
                        self.currentFileName = state.currentFile
                        if let text = state.statusText { self.statusText = text }
                        task?.progress = state
                    }
                },
                outputObserver: { detailsOutput.append($0) }
            )
            status = .succeeded(destination)
            detailsOutput.flushNow()
            TaskCenter.shared.finish(task, outcome: .succeeded(destination))
            SystemSound.operationComplete?.play()
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } catch is CancellationError {
            detailsOutput.flushNow()
            TaskCenter.shared.finish(task, outcome: .cancelled)
            onClose()
        } catch {
            status = .failed(error.localizedDescription)
            detailsOutput.flushNow()
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            onAttention()
        }
    }
}
