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

    /// 单个压缩包解压（含 `.siz` 自动解压：带目标目录 / 输出名 / 显示名 / 清理目录 override）。
    func start(
        archiveURL: URL,
        destinationDirectoryOverride: URL? = nil,
        outputBaseNameOverride: String? = nil,
        displayName: String? = nil,
        cleanupDirectory: URL? = nil
    ) {
        let session = ExternalExtractSession(
            archiveURL: archiveURL,
            destinationDirectoryOverride: destinationDirectoryOverride,
            outputBaseNameOverride: outputBaseNameOverride,
            displayName: displayName,
            cleanupDirectory: cleanupDirectory
        )
        present(content: ExternalExtractView(session: session), cancel: { session.cancel() })
        Task { [weak self] in
            await session.run(
                onClose: { [weak self] in self?.close() },
                onAttention: { [weak self] in self?.bringToFront() }
            )
        }
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

    /// 创建并展示浮窗，替换并 **取消** 上一个活动任务。
    private func present(content: some View, cancel: @escaping () -> Void) {
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
        window.title = L10n.text("externalExtract.window.title")
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
        onProgress: @escaping @MainActor (Double?, String?) -> Void
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
            }
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

    private let operationID = UUID()
    private let coordinator = ArchiveExtractionCoordinator(fileManager: .default)

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

    func cancel() {
        ArchiveService.cancelRunningCommand(operationID: operationID)
    }

    func run(onClose: @escaping @MainActor () -> Void, onAttention: @escaping @MainActor () -> Void = {}) async {
        // `.siz` unwrap 暂存根：无论成功失败都清掉（含可能的解密产物）。
        defer { if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) } }
        // 接入活动中心：Finder 自动解压也建一个归档任务，进度同步喂进去，可在活动中心查看 / 取消。
        let task = TaskCenter.shared.begin(
            category: .archive, kind: .extract, title: displayName, cancellable: true, operationID: operationID
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
                }
            )
            status = .succeeded(target)
            TaskCenter.shared.finish(task, outcome: .succeeded(target))
            SystemSound.operationComplete?.play()
            NSWorkspace.shared.activateFileViewerSelecting([target])
            // 1.2s 后自动关 —— 让用户看到「完成」反馈但不挡屏幕太久。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } catch is CancellationError {
            // 用户主动取消 ≠ 失败。直接关掉浮窗，不弹「解压失败 CancellationError」。
            TaskCenter.shared.finish(task, outcome: .cancelled)
            onClose()
        } catch {
            // 真失败不自动关；用户可能想看错误 + 复制路径。把浮窗带到最前，确保后台时错误不被埋。
            status = .failed(error.localizedDescription)
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
            // 每个压缩包在活动中心建独立任务，可逐个查看 / 取消。
            let task = TaskCenter.shared.begin(
                category: .archive, kind: .extract, title: url.lastPathComponent, cancellable: true, operationID: opID
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
                    }
                )
                succeeded.append(target)
                TaskCenter.shared.finish(task, outcome: .succeeded(target))
            } catch is CancellationError {
                // 取消当前项 → 整批停止，不记为失败。
                TaskCenter.shared.finish(task, outcome: .cancelled)
                break
            } catch {
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
