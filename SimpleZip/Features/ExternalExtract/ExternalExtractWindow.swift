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
        // `.gpg`/`.pgp`/`.asc`（加密数据）走解密浮窗。调用方（openExternalURL / 冷启动建窗判定）已用
        // `GPGFileService.shouldAutoDecryptOnExternalOpen` 过滤过，这里到的必是加密数据；startGPGDecrypt 再兜底校验一次。
        if GPGFileService.isRecognizedGPGFile(url) {
            startGPGDecrypt(sourceURL: url)
            return
        }
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
        // 持有运行任务（session.start 内部存 runTask），让取消能中止 staging merge 阶段，不只是杀 7z 进程。
        session.start(
            onClose: { [weak self] in self?.close() },
            onAttention: { [weak self] in self?.bringToFront() }
        )
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

    /// `.gpg`/`.pgp`/`.asc`（加密数据）的 Finder 自动解压（独立浮窗，全程脱钩主窗口），与 `startSIZ` 同构：
    /// 浮窗显「正在解密…」，后台解密到**加密临时卷**，然后把产物落到原文件所在目录：
    /// - 内层是受支持压缩包（如 `name.tar.gpg` 的 tar）→ 交给 `start()` 解压到该目录（复用整套解压 UI）。
    /// - 内层是普通文件（如 `report.pdf.gpg`）→ 移动到该目录（重名自动加 ` 2`），显示完成 + Finder 选中 + 自动关窗。
    /// 钥匙串材料 / 签名由主窗口路径处理（调用方已 classify 过滤），这里再兜底校验一次；用户取消密码 → 静默关窗。
    func startGPGDecrypt(sourceURL: URL) {
        let prepare = ExternalPrepareSession(displayName: sourceURL.lastPathComponent)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard GPGBackend.classifyFile(at: sourceURL) == .encryptedMessage else {
                    // 兜底：不是加密数据（钥匙串 / 签名）—— 浮窗里给「在主窗口打开」逃生入口，由主窗口走分类路由。
                    prepare.fail(L10n.text("gpgFile.notDecryptable.message"))
                    self.bringToFront()
                    return
                }
                let decrypted = try await GPGFileService.decryptToTemporary(sourceURL)
                try Task.checkCancellation()
                let tempRoot = decrypted.deletingLastPathComponent()
                let destinationDir = sourceURL.deletingLastPathComponent()
                if ArchiveService.isSupportedArchive(decrypted) {
                    // 内层压缩包 → 解压到原 .gpg 所在目录（与 .siz 自动解压完全同构）。
                    // 交棒给解压 session：清空 cancelActive，别让 start() 的 present 误清 tempRoot；
                    // tempRoot 交由 start 的 cleanupDirectory 在结束后清理。
                    self.cancelActive = nil
                    self.start(
                        archiveURL: decrypted,
                        destinationDirectoryOverride: destinationDir,
                        displayName: sourceURL.lastPathComponent,
                        cleanupDirectory: tempRoot,
                        mainWindowURL: sourceURL
                    )
                } else {
                    // 普通文件 → 落到原目录。明文中转在加密卷里，移动到用户目录是其「自动解压」的明确意图。
                    let target = Self.uniqueDestination(for: decrypted.lastPathComponent, in: destinationDir)
                    try FileManager.default.moveItem(at: decrypted, to: target)
                    try? FileManager.default.removeItem(at: tempRoot)
                    prepare.succeed(target)
                    SystemSound.operationComplete?.play()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.close()
                }
            } catch is CancellationError {
                self.close()
            } catch {
                // pinentry 取消（用户放弃输入密码）→ 静默关窗，不弹「失败」。其它失败留窗 + 带到最前 + 逃生入口。
                if Self.decryptErrorLooksLikeUserCancellation(error) {
                    self.close()
                    return
                }
                prepare.fail(error.localizedDescription)
                self.bringToFront()
            }
        }
        prepare.onOpenInMainWindow = { [weak self] in self?.openInMainWindow(browseURL: sourceURL, cleanup: nil) }
        present(content: ExternalPrepareView(session: prepare), cancel: { task.cancel() })
    }

    /// 原目录内不覆盖的落点：重名自动 ` 2`、` 3`…（与 GPGFileService.encryptedDestination 同口径）。
    private static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func candidate(_ tail: String) -> URL {
            let fileName = ext.isEmpty ? "\(base)\(tail)" : "\(base)\(tail).\(ext)"
            return directory.appendingPathComponent(fileName)
        }
        var destination = candidate("")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = candidate(" \(n)")
            n += 1
        }
        return destination
    }

    /// 粗判解密错误是否来自用户取消 pinentry —— 命中即静默关窗（与 ArchiveBrowserModel+GPG 同口径）。
    private static func decryptErrorLooksLikeUserCancellation(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("cancel") || text.contains("abort")
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
                // 浮窗宿主自己处理解密结果（替成进度/错误视图），sheet 无需内联错误 → 返回 nil。
                self?.proceedSIZExtract(
                    sourceURL: sourceURL,
                    innerArchiveURL: innerArchiveURL,
                    tempRoot: tempRoot,
                    decryptionKey: key,
                    passphrase: passphrase
                )
                return nil
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
