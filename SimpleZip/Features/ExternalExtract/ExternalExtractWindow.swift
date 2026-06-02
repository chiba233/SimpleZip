//
//  ExternalExtractWindow.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import AppKit
import Combine
import SwiftUI

/// 「Finder 双击 → 自动解压」/「右键 用 SimpleZip 解压」走的独立小浮窗。
///
/// 设计动机：用户开了「Finder 自动解压」开关后，原实现把任务交给主窗口的 `ArchiveBrowserModel`，
/// 主窗口会被一并拉起，违反了「双击 = 后台静默解压」的预期。这个 controller 完全独立于主窗口的 model。
///
/// **同一时间只允许一个浮窗 + 一个解压任务**。`start` / `startBatch` 在替换窗口前会 **cancel 上一个任务**——
/// 否则旧任务的 `Task` 强捕获了旧 session 仍会在后台不可见地继续写磁盘（用户报告的多选解压隐身任务问题）。
@MainActor
final class ExternalExtractWindowController {
    static let shared = ExternalExtractWindowController()

    private var window: NSWindow?
    /// 当前活动任务的取消句柄。替换 / 关闭浮窗前调用，确保旧任务真的停掉而不是隐身续跑。
    private var cancelActive: (() -> Void)?

    /// 统一入口：按扩展名分派 `.siz → startSIZ` / `.szs → startSZS` / 其它 → 普通解压。
    /// Finder 自动解压（冷启动 / 热运行 / 右键单个）都经这里，**全程不碰主窗口**。
    func open(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case SIZArchive.extensionName: startSIZ(sourceURL: url)
        case SZSArchive.extensionName: startSZS(sourceURL: url)
        default: start(archiveURL: url, mainWindowURL: url)
        }
    }

    /// 单个压缩包解压（含 `.siz` 自动解压：带目标目录 / 输出名 / 显示名 / 清理目录 override）。
    /// - mainWindowURL：浮窗「在主窗口打开」点击时交给主窗口浏览的 URL（默认即 archiveURL；
    ///   `.siz` 自动解压时传**原始 .siz**，让用户在主窗口看到的是容器而非临时内层 archive）。
    func start(
        archiveURL: URL,
        destinationDirectoryOverride: URL? = nil,
        outputBaseNameOverride: String? = nil,
        displayName: String? = nil,
        cleanupDirectory: URL? = nil,
        mainWindowURL: URL? = nil
    ) {
        let session = ExternalExtractSession(
            archiveURL: archiveURL,
            destinationDirectoryOverride: destinationDirectoryOverride,
            outputBaseNameOverride: outputBaseNameOverride,
            displayName: displayName,
            cleanupDirectory: cleanupDirectory
        )
        let openURL = mainWindowURL ?? archiveURL
        session.onOpenInMainWindow = { [weak self] in self?.openInMainWindow(browseURL: openURL, cleanup: nil) }
        present(content: ExternalExtractView(session: session), cancel: { session.cancel() })
        session.start(
            onClose: { [weak self] in self?.close() },
            onAttention: { [weak self] in self?.bringToFront() }
        )
    }

    /// 多个压缩包批量解压（Finder 多选 → 用 SimpleZip 解压）：**一个浮窗、串行解压、一个取消、一个失败汇总**。
    /// 单个时退回 `start`（复用单任务 UI）。
    func startBatch(archiveURLs: [URL]) {
        guard !archiveURLs.isEmpty else { return }
        guard archiveURLs.count > 1 else {
            start(archiveURL: archiveURLs[0])
            return
        }
        let session = ExternalExtractBatchSession(archiveURLs: archiveURLs)
        present(content: ExternalExtractBatchView(session: session), cancel: { session.cancel() })
        Task { [weak self] in
            await session.run(
                onClose: { [weak self] in self?.close() },
                onAttention: { [weak self] in self?.bringToFront() }
            )
        }
    }

    /// `.siz` 自动解压（独立浮窗，全程脱钩主窗口）：先在浮窗显「正在校验签名…」，后台 unwrap + 验签：
    /// - 签名干净（或 gpgEnabled 关 = 无可验签名）→ 解密(若需) + 直接解压到 .siz 所在目录。
    /// - 有 concerns → 浮窗内呈现 `SIZSignatureSheet`，用户选「解压 / 在主窗口打开 / 取消」。
    /// - unwrap / 验签出错 → 浮窗显错误 + 「在主窗口打开」逃生入口。
    func startSIZ(sourceURL: URL) {
        let prepare = ExternalPrepareSession(displayName: sourceURL.lastPathComponent)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let (innerArchiveURL, tempRoot, summary) = try await SignedContainerService.unwrapAndVerifySIZ(at: sourceURL)
                try Task.checkCancellation()
                if SignedContainerService.sizSignatureIsClean(summary) {
                    // 干净（含 GPG 关闭的刚需例外）→ 解密(若需) 后直接解压。
                    let decrypted = try await SignedContainerService.decryptInnerArchiveIfNeeded(innerArchiveURL)
                    try Task.checkCancellation()
                    self.cancelActive = nil   // 交棒给解压 session：别让下面 start() 的 present 误清 tempRoot
                    self.start(
                        archiveURL: decrypted,
                        destinationDirectoryOverride: sourceURL.deletingLastPathComponent(),
                        outputBaseNameOverride: sourceURL.deletingPathExtension().lastPathComponent,
                        displayName: sourceURL.lastPathComponent,
                        cleanupDirectory: tempRoot,
                        mainWindowURL: sourceURL
                    )
                } else if let summary {
                    self.presentSIZSignatureSheet(
                        sourceURL: sourceURL,
                        innerArchiveURL: innerArchiveURL,
                        tempRoot: tempRoot,
                        summary: summary
                    )
                }
            } catch is CancellationError {
                self.close()
            } catch {
                prepare.fail(error.localizedDescription)
                self.bringToFront()
            }
        }
        prepare.onOpenInMainWindow = { [weak self] in self?.openInMainWindow(browseURL: sourceURL, cleanup: nil) }
        present(content: ExternalPrepareView(session: prepare), cancel: { task.cancel() })
    }

    /// `.siz` 验签有 concerns 时浮窗内呈现签名 sheet。三动作：解压 / 在主窗口打开 / 取消，均自管 tempRoot 清理。
    private func presentSIZSignatureSheet(
        sourceURL: URL,
        innerArchiveURL: URL,
        tempRoot: URL,
        summary: SIZSignatureSummary
    ) {
        let sheet = SIZSignatureSheet(
            signature: summary,
            onOpen: { [weak self] key, passphrase in
                self?.proceedSIZExtract(
                    sourceURL: sourceURL,
                    innerArchiveURL: innerArchiveURL,
                    tempRoot: tempRoot,
                    decryptionKey: key,
                    passphrase: passphrase
                )
            },
            onCancel: { [weak self] in
                try? FileManager.default.removeItem(at: tempRoot)
                self?.close()
            },
            primaryActionTitle: L10n.text("externalExtract.siz.extractButton"),
            onOpenInMainWindow: { [weak self] in
                self?.openInMainWindow(browseURL: sourceURL, cleanup: tempRoot)
            }
        )
        present(content: sheet, cancel: { [weak self] in
            try? FileManager.default.removeItem(at: tempRoot)
            self?.close()
        })
    }

    /// 用户在签名 sheet 点「解压」：解密(若需) 后解压。解密失败 → 浮窗显错误 + 逃生入口（可去主窗口换密钥重试）。
    private func proceedSIZExtract(
        sourceURL: URL,
        innerArchiveURL: URL,
        tempRoot: URL,
        decryptionKey: String?,
        passphrase: String?
    ) {
        // 关键：先解除签名 sheet 留下的 cancelActive（= 删 tempRoot）。否则下面 present 占位视图时会触发它，
        // 把还要用来解密的 tempRoot 删掉。tempRoot 之后交给解压 session（cleanupDirectory）或本函数的错误/取消分支清理。
        cancelActive = nil
        let prepare = ExternalPrepareSession(displayName: sourceURL.lastPathComponent)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let decrypted = try await SignedContainerService.decryptInnerArchiveIfNeeded(
                    innerArchiveURL, decryptionKey: decryptionKey, passphrase: passphrase
                )
                try Task.checkCancellation()
                self.cancelActive = nil   // 交棒给解压 session 清 tempRoot
                self.start(
                    archiveURL: decrypted,
                    destinationDirectoryOverride: sourceURL.deletingLastPathComponent(),
                    outputBaseNameOverride: sourceURL.deletingPathExtension().lastPathComponent,
                    displayName: sourceURL.lastPathComponent,
                    cleanupDirectory: tempRoot,
                    mainWindowURL: sourceURL
                )
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: tempRoot)
                self.close()
            } catch {
                prepare.fail(error.localizedDescription)
                self.bringToFront()
            }
        }
        prepare.onOpenInMainWindow = { [weak self] in self?.openInMainWindow(browseURL: sourceURL, cleanup: tempRoot) }
        present(content: ExternalPrepareView(session: prepare), cancel: { task.cancel() })
    }

    /// `.szs` 自动解压（独立浮窗，全程脱钩主窗口）：peek 签名清单后浮窗内呈现 `SZSVerificationSheet`。
    /// `.szs` 无「解压」语义，主操作即「以虚拟目录浏览」—— 该操作需要主窗口 model，走「在主窗口打开」直达入口（免重验）。
    func startSZS(sourceURL: URL) {
        let prepare = ExternalPrepareSession(displayName: sourceURL.lastPathComponent)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let (signature, manifest) = try await SZSArchive.peek(manifestURL: sourceURL)
                try Task.checkCancellation()
                self.presentSZSVerificationSheet(sourceURL: sourceURL, signature: signature, manifest: manifest)
            } catch is CancellationError {
                self.close()
            } catch {
                prepare.fail(error.localizedDescription)
                self.bringToFront()
            }
        }
        prepare.onOpenInMainWindow = { [weak self] in self?.openInMainWindow(browseURL: sourceURL, cleanup: nil) }
        present(content: ExternalPrepareView(session: prepare), cancel: { task.cancel() })
    }

    private func presentSZSVerificationSheet(
        sourceURL: URL,
        signature: GPGBackend.GPGVerifyResult,
        manifest: SZSArchive.Manifest
    ) {
        let sheet = SZSVerificationSheet(
            sourceURL: sourceURL,
            signature: signature,
            manifest: manifest,
            initialPayloadRoot: sourceURL.deletingLastPathComponent(),
            onClose: { [weak self] in self?.close() },
            onOpenAsVirtualFolder: { [weak self] payloadRoot, report in
                self?.openInMainWindow(
                    szsRequest: SZSVirtualFolderRequest(manifestURL: sourceURL, report: report, payloadRoot: payloadRoot)
                )
            }
        )
        present(content: sheet, cancel: { [weak self] in self?.close() })
    }

    /// 浮窗「在主窗口打开」：把请求交给标准主窗口流程（按偏好新标签 / 新窗口），关浮窗。
    /// 这是「彻底脱钩」下用户**主动**拉起主窗口的唯一入口。
    private func openInMainWindow(browseURL: URL, cleanup: URL?) {
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
        cancelActive = nil   // 已交给主窗口；别在 close 链路误触发 sheet 的 tempRoot 清理（已清）
        MainWindowFactory.open(asTab: AppPreferences.openExternalInNewTab, openURL: browseURL)
        close()
    }

    /// `.szs`「以虚拟目录浏览」：已验签报告直达新主窗口，免重验。
    private func openInMainWindow(szsRequest: SZSVirtualFolderRequest) {
        cancelActive = nil
        MainWindowFactory.open(asTab: AppPreferences.openExternalInNewTab, openSZSVirtualFolder: szsRequest)
        close()
    }

    /// Finder 右键「用 SimpleZip 创建 ▸ ZIP/7z/TAR.GZ」—— 和解压完全同构的独立浮窗：
    /// 进度条 + 「活动中心」按钮 + 取消；压完 1.2s 自动关窗、Finder 高亮产物；失败保留窗口显错误。
    /// 全程不碰主窗口。命名仿 Finder：单个 = `名字.ext`，多个 = `Archive.ext`，重名加序号绝不覆盖。
    func startQuickCreate(format: ArchiveCreateFormat, sourceURLs: [URL]) {
        let files = sourceURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = files.first else { return }
        let dir = first.deletingLastPathComponent()
        let ext = format.pathExtension
        let baseName = files.count == 1 ? first.lastPathComponent : "Archive"
        let fm = FileManager.default
        func candidate(_ tail: String) -> URL { dir.appendingPathComponent("\(baseName)\(tail).\(ext)") }
        var destination = candidate("")
        var n = 2
        while fm.fileExists(atPath: destination.path) { destination = candidate(" \(n)"); n += 1 }

        let session = ExternalCreateSession(format: format, files: files, destination: destination)
        present(
            content: ExternalCreateView(session: session),
            windowTitle: L10n.text("externalCreate.window.title"),
            cancel: { session.cancel() }
        )
        session.start(
            onClose: { [weak self] in self?.close() },
            onAttention: { [weak self] in self?.bringToFront() }
        )
    }

    /// 创建并展示浮窗，替换并 **取消** 上一个活动任务。
    private func present(content: some View, windowTitle: String = L10n.text("externalExtract.window.title"), cancel: @escaping () -> Void) {
        cancelActive?()            // 关键：先停掉旧任务，避免它在后台隐身续跑。
        window?.orderOut(nil)
        window = nil
        cancelActive = cancel

        // 用 NSWindow 而不是 NSPanel —— Panel 在 NSApp.activate 时夺焦后可能立刻 deactivate，行为不稳。
        let frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: content)
        window.title = windowTitle
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// 失败 / 需要用户注意时：激活 app + 把浮窗带到最前（后台运行时别被埋在 Finder 后面）。
    private func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        cancelActive = nil
    }
}

/// 解压单个压缩包到其所在目录的同名文件夹，返回产物目录。**纯流程，无 reveal / 关窗 / 声音副作用**——
/// 单任务和批量任务共用，避免重复 staging → extract → merge 这段逻辑。
enum ExternalExtractRunner {
    @MainActor
    static func extract(
        archiveURL: URL,
        destinationDirectoryOverride: URL?,
        outputBaseNameOverride: String?,
        operationID: UUID,
        coordinator: ArchiveExtractionCoordinator,
        onStatus: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (Double?, String?) -> Void,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let supportedURL = ArchiveService.supportedArchiveURL(archiveURL) ?? archiveURL
        // 目标父目录：默认 archive 所在目录；`.siz` 自动解压时内层 archive 在 /tmp，用 override 落到原 .siz 文件夹。
        let destinationDir = destinationDirectoryOverride ?? supportedURL.deletingLastPathComponent()
        let stagingURL = try coordinator.makeExtractionStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        let overwriteBehavior: OverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting
            ? .skipExisting
            : .overwrite

        try await ArchiveService.extract(
            supportedURL,
            to: stagingURL,
            overwriteBehavior: overwriteBehavior,
            password: preset,
            operationID: operationID,
            progress: { state in
                Task { @MainActor in
                    onProgress(state.fraction, state.currentFile)
                    if let text = state.statusText { onStatus(text) }
                }
            },
            outputObserver: outputObserver
        )

        let baseName = outputBaseNameOverride ?? supportedURL.deletingPathExtension().lastPathComponent
        let target = coordinator.uniqueDestinationURL(for: baseName, in: destinationDir)
        try await coordinator.mergeExtractedItems(
            from: stagingURL,
            to: target,
            defaultOverwriteBehavior: overwriteBehavior,
            updateStatus: { text in Task { @MainActor in onStatus(text) } },
            updateProgress: { state in Task { @MainActor in onProgress(state.fraction, state.currentFile) } }
        )
        return target
    }
}

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
            category: .archive, kind: .extract, title: displayName, cancellable: true,
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
    private let coordinator = ArchiveExtractionCoordinator(fileManager: .default)

    var total: Int { archiveURLs.count }

    init(archiveURLs: [URL]) {
        self.archiveURLs = archiveURLs
        self.statusText = L10n.format("externalExtract.batch.progress", 1, archiveURLs.count, archiveURLs.first?.lastPathComponent ?? "")
    }

    func cancel() {
        isCancelled = true
        if let id = currentOperationID { ArchiveService.cancelRunningCommand(operationID: id) }
    }

    func run(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void) async {
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
                category: .archive, kind: .extract, title: url.lastPathComponent, cancellable: true,
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

/// 单任务浮窗内容：固定 360 宽，VStack 包标题 / 进度条 / 当前文件 / 状态行。
struct ExternalExtractView: View {
    @ObservedObject var session: ExternalExtractSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let fraction = session.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if session.status == .running {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let currentFile = session.currentFileName, session.status == .running {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                switch session.status {
                case .running:
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) {
                        session.cancel()
                    }
                case .succeeded:
                    Label(L10n.text("externalExtract.done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.text("externalExtract.failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}

/// 批量浮窗内容：标题显示「解压 N 个压缩包」，进行中显示「N / M：名字」+ 进度；结束显示成功 / 失败汇总。
struct ExternalExtractBatchView: View {
    @ObservedObject var session: ExternalExtractBatchSession

    /// 失败列表最多展示几条，超出折叠成「+N」，避免浮窗被撑爆。
    private let maxFailureLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("externalExtract.batch.title", session.total))
                        .font(.headline)
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if !session.isFinished {
                if let fraction = session.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let currentFile = session.currentFileName {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) { session.cancel() }
                }
            } else if session.failures.isEmpty {
                Label(L10n.format("externalExtract.batch.allDone", session.succeeded.count), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        L10n.format("externalExtract.batch.summary", session.succeeded.count, session.failures.count),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    ForEach(session.failures.prefix(maxFailureLines)) { failure in
                        Text("\(failure.name): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.failures.count > maxFailureLines {
                        Text(L10n.format("externalExtract.batch.moreFailures", session.failures.count - maxFailureLines))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}

/// `.siz`/`.szs` 在浮窗里「准备阶段」（unwrap + 验签 / peek）的占位会话 —— 校验中显进度条，
/// 出错显错误 + 「在主窗口打开」逃生入口。准备完成后 controller 会把浮窗内容替换成解压进度 / 签名 sheet。
@MainActor
final class ExternalPrepareSession: ObservableObject {
    enum Phase: Equatable {
        case verifying
        case failed(String)
    }

    let displayName: String
    @Published var phase: Phase = .verifying
    /// controller 注入：浮窗「在主窗口打开」（准备失败时的逃生入口）。
    var onOpenInMainWindow: (() -> Void)?

    init(displayName: String) {
        self.displayName = displayName
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }
}

/// `.siz`/`.szs` 准备阶段浮窗内容。
struct ExternalPrepareView: View {
    @ObservedObject var session: ExternalPrepareSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch session.phase {
            case .verifying:
                ProgressView().progressViewStyle(.linear)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if let onOpenInMainWindow = session.onOpenInMainWindow {
                        Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }

    private var statusText: String {
        switch session.phase {
        case .verifying: return L10n.text("externalExtract.verifying")
        case .failed: return L10n.text("externalExtract.failed")
        }
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
        var options = ArchiveCreationOptions()
        options.format = format
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
            category: .archive, kind: .compress, title: displayName, cancellable: true,
            detailsSession: details, operationID: operationID
        )
        task.cancel = { [weak self] in self?.cancel() }
        do {
            try await ArchiveService.createArchive(
                from: files,
                destination: destination,
                options: options,
                operationID: operationID,
                progress: { state in
                    // 外层是 @Sendable 闭包，弱捕获放到内层 Task（并发上下文）里，
                    // 避免「在并发代码里引用捕获的 self」错误。state 是 Sendable 值，外层捕获它无碍。
                    Task { @MainActor [weak self, weak task] in
                        guard let self else { return }
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

/// Finder 一键创建浮窗内容 —— 和 `ExternalExtractView` 同构（创建文案 + 无「在主窗口打开」）。
struct ExternalCreateView: View {
    @ObservedObject var session: ExternalCreateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let fraction = session.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if session.status == .running {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let currentFile = session.currentFileName, session.status == .running {
                Text(currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                switch session.status {
                case .running:
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                    Spacer()
                    Button(L10n.text("button.cancel")) {
                        session.cancel()
                    }
                case .succeeded:
                    Label(L10n.text("externalCreate.done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.text("externalCreate.failed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L10n.text("tasks.window.title")) {
                        ActivityWindowController.shared.show(category: .archive)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}
