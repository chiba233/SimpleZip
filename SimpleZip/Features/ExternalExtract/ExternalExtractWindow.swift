//
//  ExternalExtractWindow.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import AppKit
import Combine
import SwiftUI

/// 「Finder 双击 → 自动解压」走的独立小浮窗。
///
/// 设计动机：用户开了「Finder 自动解压」开关后，原实现把任务交给主窗口的 `ArchiveBrowserModel`，
/// 主窗口会被一并拉起，违反了「双击 = 后台静默解压」的预期 —— 用户反馈「拉起主窗口毫无价值」。
/// 这个 controller 完全独立于主窗口的 model：
/// - 自己的 `ArchiveExtractionCoordinator` 持有 staging / 冲突解决；
/// - 自己的 `Session` 跑 `ArchiveService.extract`，progress 更新只刷新本浮窗 UI；
/// - 浮窗大小固定 ~360x180，`.utilityWindow` style + `.floating` level，不抢主窗口焦点；
/// - 解压成功后 1.2s 自动关掉 + reveal in Finder；失败时停留显示错误，让用户能复制详情。
@MainActor
final class ExternalExtractWindowController {
    static let shared = ExternalExtractWindowController()

    /// 同一时间只允许一个 external extract 浮窗 —— 用户连续从 Finder 双击多个压缩包时，
    /// 新一个用同一个窗口替换上一个（视觉上比堆 5 个浮窗清晰）。
    private var window: NSWindow?
    private var session: ExternalExtractSession?

    /// - Parameters:
    ///   - destinationDirectoryOverride: 解压目标父目录。默认 nil = 用 archive 所在目录；
    ///     `.siz` 自动解压时内层 archive 在 /tmp，但结果要落到原 `.siz` 所在文件夹，所以传 override。
    ///   - outputBaseNameOverride: 输出文件夹名（默认取 archive 去扩展名）。`.siz` 传原 `.siz` 名而不是内层 `archive`。
    ///   - displayName: 浮窗标题显示名（默认 archive 文件名）。`.siz` 传 `xxx.siz`。
    ///   - cleanupDirectory: 解压结束后删除的临时目录（`.siz` 的 unwrap 暂存根），nil = 不清理。
    func start(
        archiveURL: URL,
        destinationDirectoryOverride: URL? = nil,
        outputBaseNameOverride: String? = nil,
        displayName: String? = nil,
        cleanupDirectory: URL? = nil
    ) {
        // 已经有一个跑着 → 先关掉，避免视觉混乱。
        if let existing = window {
            existing.orderOut(nil)
            window = nil
            session = nil
        }

        let session = ExternalExtractSession(
            archiveURL: archiveURL,
            destinationDirectoryOverride: destinationDirectoryOverride,
            outputBaseNameOverride: outputBaseNameOverride,
            displayName: displayName,
            cleanupDirectory: cleanupDirectory
        )
        let view = ExternalExtractView(session: session)
        let hosting = NSHostingController(rootView: view)

        // 用 NSWindow 而不是 NSPanel —— Panel 在某些情况下会被 NSApp.activate 时夺焦后立刻 deactivate，
        // 反而导致行为不稳。普通带 .titled / .closable 的 NSWindow 配合 .floating level 行为更可预测。
        let frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = L10n.text("externalExtract.window.title")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.session = session

        // 用 weak self 让 closure 不阻止 controller 被释放（理论上 shared 永生，但留好）。
        Task { [weak self] in
            await session.run { [weak self] in
                self?.close()
            }
        }
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        session = nil
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
    @Published var statusText: String = L10n.text("status.extracting")

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
        self.displayName = displayName ?? archiveURL.lastPathComponent
        self.cleanupDirectory = cleanupDirectory
    }

    func cancel() {
        ArchiveService.cancelRunningCommand(operationID: operationID)
    }

    /// 整条流程：staging → ArchiveService.extract → mergeExtractedItems → reveal in Finder。
    /// 跟主 model 的 `performExtractArchive` 几乎一致，但不带密码 retry 循环 —— 助手 / 偏好里
    /// 把预设密码填好就够了；失败的密码不弹 prompt，让用户去主 App 走完整 flow。
    func run(onClose: @escaping @MainActor () -> Void) async {
        do {
            let supportedURL = ArchiveService.supportedArchiveURL(archiveURL) ?? archiveURL
            // 目标父目录：默认 archive 所在目录；`.siz` 自动解压时内层 archive 在 /tmp，用 override 落到原 .siz 文件夹。
            let destinationDir = destinationDirectoryOverride ?? supportedURL.deletingLastPathComponent()
            let stagingURL = try coordinator.makeExtractionStagingDirectory()
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            // `.siz` unwrap 暂存根：解压取完内层 archive 后清掉（含可能的解密产物）。
            defer { if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) } }

            let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
            let overwriteBehavior: OverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting
                ? .skipExisting
                : .overwrite

            // ArchiveService.extract 跑在自己的 Task；progress 回调在后台 queue 上被调，
            // 跨到 @MainActor 才能动 @Published —— Task { @MainActor in ... } 是标准写法。
            try await ArchiveService.extract(
                supportedURL,
                to: stagingURL,
                overwriteBehavior: overwriteBehavior,
                password: preset,
                operationID: operationID,
                progress: { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.fraction = state.fraction
                        self.currentFileName = state.currentFile
                        if let text = state.statusText {
                            self.statusText = text
                        }
                    }
                }
            )

            // 在压缩包所在目录建一个跟压缩包同名（去扩展名）的目录放结果；
            // 同名冲突走 coordinator 的 uniqueDestinationURL 加 " 1" / " 2" 后缀。
            let baseName = outputBaseNameOverride ?? supportedURL.deletingPathExtension().lastPathComponent
            let target = coordinator.uniqueDestinationURL(for: baseName, in: destinationDir)
            try await coordinator.mergeExtractedItems(
                from: stagingURL,
                to: target,
                defaultOverwriteBehavior: overwriteBehavior,
                updateStatus: { [weak self] text in
                    Task { @MainActor [weak self] in self?.statusText = text }
                },
                updateProgress: { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.fraction = state.fraction
                        self.currentFileName = state.currentFile
                    }
                }
            )

            status = .succeeded(target)
            NSWorkspace.shared.activateFileViewerSelecting([target])

            // 1.2s 后自动关 —— 让用户看到「完成」反馈但不挡屏幕太久。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onClose()
        } catch {
            // 失败不自动关；用户可能想看错误 + 复制路径。
            status = .failed(error.localizedDescription)
        }
    }
}

/// 浮窗内容：固定 360 宽，VStack 包标题 / 进度条 / 当前文件 / 状态行。
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
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .top)
    }
}
