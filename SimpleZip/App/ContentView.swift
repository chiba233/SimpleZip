//
//  ContentView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口视图：只负责把侧边栏、工具栏、列表和状态栏组合在一起。
struct ContentView: View {
    @StateObject private var model = ArchiveBrowserModel()
    @State private var isDropTargeted = false

    /// 启动期校验「保存的 startupLocation 当前是否指向不存在的目录」用的弹窗 flag。
    /// 只在 app 第一次 onAppear 时计算一次，避免后续重新 layout 反复弹。
    @State private var showsStartupMissingAlert = false
    @State private var didCheckStartupLocation = false

    /// 欢迎助手 sheet。首次启动 `onAppear` 自动置 true；走完最后一步 / 关 sheet 都会清回 false。
    /// 用户从 SimpleZip → 重新运行欢迎助手 入口也走同一通道（通过 `.openWelcomeAssistant` 通知）。
    @State private var showsWelcomeAssistant = false
    @State private var didCheckWelcomeAssistant = false

    /// `.siz` 签名验证状态：unwrap 完成 + 验签结果就绪后赋值，触发 SwiftUI sheet 显示签名信息对话框。
    /// 用 sheet 替代 NSAlert 是因为后者在 SwiftUI 视图 context（没 key window 锚定）下渲染成无 chrome
    /// 浮动框，关闭行为也不可控。sheet 行为可控、跟 app 其它对话框（创建 / 解压选项）一致。
    @State private var pendingSIZVerification: SIZPendingVerification?

    /// `.szs` 签名清单验证状态。peek 完 → 弹 sheet 展示 manifest + 签名状态 + per-file 校验。
    @State private var pendingSZSVerification: SZSPendingVerification?
    /// 「创建签名清单」sheet flag。File 菜单 / 右键 / 通知触发 → 弹 CreateSZSSheet。
    @State private var showsCreateSZSSheet = false
    /// 右键入口预填值（payload root + 已选文件）。空白菜单触发时为 nil。
    @State private var createSZSPrefill: ArchiveBrowserModel.CreateSZSPrefill?
    /// 右键「解压」.szs 触发的提示 alert 状态。非 nil = alert 显示中；button 点了就清。
    @State private var szsExtractHintURL: URL?
    /// 右键「以虚拟目录浏览」静默校验失败时的警告 alert 状态。
    /// nil = 没问题（已直接进入虚拟模式）/ 还没触发；非 nil = 验证发现问题，用户需决定。
    @State private var szsSilentBrowseWarning: SZSSilentBrowseWarning?

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TopBar(model: model)

                Divider()

                if case .archive = model.mode {
                    ArchiveTable(model: model)
                } else {
                    FileTable(model: model)
                }

                Divider()
                StatusBar(model: model)
            }
            .frame(minWidth: 620)
            .navigationTitle(model.title)
        }
        .frame(minWidth: 980, minHeight: 620)
        .focusedSceneObject(model)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            receiveDroppedFileURLs(from: providers)
        }
        .alert(L10n.text("alert.operationFailed"), isPresented: Binding(get: {
            model.isShowingOperationFailureAlert
        }, set: { newValue in
            if !newValue { model.dismissOperationFailureAlert() }
        })) {
            if let session = model.operationDetailsSession {
                // 点了「复制诊断」alert 会被自动关掉（SwiftUI 默认行为），
                // 但 NSPasteboard.setString 是同步的，await ArchiveService.*Version 的取版本
                // 由 DiagnosticsCopier 内部异步等待，最坏情况就是用户多等一两秒看到 ✓ 反馈。
                Button(L10n.text("button.copyDiagnostics")) {
                    let errorMessage = model.errorMessage
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: errorMessage)
                    }
                }
                Button(L10n.text("button.details")) {
                    model.openOperationDetailsFromFailureAlert()
                }
            }
            Button(L10n.text("button.ok"), role: .cancel) { model.dismissOperationFailureAlert() }
        } message: {
            Text(model.operationFailurePreviewMessage)
        }
        .sheet(isPresented: Binding(get: {
            model.isShowingOperationDetails && model.operationDetailsSession != nil
        }, set: { newValue in
            model.handleOperationDetailsPresentationChange(newValue)
        })) {
            if let session = model.operationDetailsSession {
                ArchiveOperationDetailsView(session: session) {
                    model.closeOperationDetails()
                }
            }
        }
        .sheet(item: $model.hashReport) { report in
            HashResultsView(report: report) {
                model.hashReport = nil
            }
        }
        .sheet(item: $model.benchmarkRequest) { request in
            BenchmarkOptionsView(request: request) { confirmedRequest in
                model.benchmarkRequest = nil
                model.runSevenZipBenchmark(confirmedRequest)
            } cancel: {
                model.benchmarkRequest = nil
            }
        }
        .sheet(item: $model.benchmarkSession) { session in
            BenchmarkRunView(session: session) {
                if session.isRunning {
                    model.cancelCurrentOperation()
                }
                model.benchmarkSession = nil
            }
        }
        .sheet(item: $model.archiveCreationRequest) { request in
            ArchiveCreationOptionsView(request: request) { confirmedRequest in
                model.archiveCreationRequest = nil
                model.performCreateArchive(confirmedRequest)
            } cancel: {
                model.archiveCreationRequest = nil
            }
        }
        .sheet(item: $model.extractSelectionRequest) { request in
            ExtractSelectionOptionsView(request: request) { confirmedRequest in
                model.extractSelectionRequest = nil
                model.performExtractSelection(confirmedRequest)
            } cancel: {
                model.extractSelectionRequest = nil
            }
        }
        .sheet(item: $model.extractArchiveRequest) { request in
            ExtractArchiveOptionsView(request: request) { confirmedRequest in
                model.extractArchiveRequest = nil
                model.performExtractArchive(confirmedRequest)
            } cancel: {
                model.extractArchiveRequest = nil
            }
        }
        .sheet(item: $pendingSZSVerification) { pending in
            SZSVerificationSheet(
                sourceURL: pending.sourceURL,
                signature: pending.signature,
                manifest: pending.manifest,
                initialPayloadRoot: pending.sourceURL.deletingLastPathComponent(),
                onClose: {
                    pendingSZSVerification = nil
                },
                onOpenAsVirtualFolder: { payloadRoot, report in
                    pendingSZSVerification = nil
                    // 同 `.siz` 的逻辑：sheet 附属主窗口，主窗口本来就 visible —— 别 ensureMainWindowVisible
                    // 把正在 dismissing 的 sheet 又拉回来。
                    // 传 verifyReport 而不是 peek 的 manifest —— model 内部按 `.match` 条目过滤 allowedFiles。
                    model.openSZSAsVirtualFolder(
                        manifestURL: pending.sourceURL,
                        verifyReport: report,
                        payloadRoot: payloadRoot
                    )
                }
            )
        }
        .sheet(isPresented: $showsCreateSZSSheet) {
            CreateSZSSheet(
                initialPrefill: createSZSPrefill,
                onClose: {
                    showsCreateSZSSheet = false
                    createSZSPrefill = nil
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCreateSZSSheet)) { _ in
            createSZSPrefill = nil
            showsCreateSZSSheet = true
        }
        .onChange(of: model.pendingCreateSZS) { prefill in
            // 右键 → 「创建签名清单」入口：model 把当前选中 + payload root 推断好后 set 到 pendingCreateSZS；
            // 立即清空避免下次同样的 prefill 被吞掉 onChange。
            guard let prefill else { return }
            model.pendingCreateSZS = nil
            createSZSPrefill = prefill
            showsCreateSZSSheet = true
        }
        .sheet(item: $pendingSIZVerification) { pending in
            SIZSignatureSheet(
                signature: pending.signature,
                onOpen: { decryptionKey, decryptionPassphrase in
                    // **关键顺序**：不要在 Task 外清 pendingSIZVerification —— 否则 sheet 立刻 dismiss，解密失败时
                    // 用户没法在 sheet 里改 picker / 重输 passphrase 重试，必须重 Finder 打开。
                    // 正确：成功 branch 才 dismiss + openArchive；失败 branch 保留 sheet 让用户重试。
                    Task {
                        do {
                            let urlToOpen = try await decryptInnerArchiveIfNeeded(
                                pending.innerArchiveURL,
                                decryptionKey: decryptionKey,
                                passphrase: decryptionPassphrase
                            )
                            await MainActor.run {
                                pendingSIZVerification = nil
                                model.openArchive(urlToOpen, displayedAs: pending.signature.sourceURL)
                            }
                        } catch {
                            await MainActor.run {
                                // sheet 保留；只设 errorMessage 让 model alert 弹出来。
                                model.errorMessage = L10n.format("error.siz.decryptionFailed", error.localizedDescription)
                            }
                        }
                    }
                },
                onCancel: {
                    pendingSIZVerification = nil
                    try? FileManager.default.removeItem(at: pending.tempRoot)
                }
            )
        }
        .onAppear {
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
            // 校验保存的 startupLocation 是不是指向一个还活着的目录；
            // 只校验一次 —— 后续窗口大小变化重渲染时不会反复弹。
            if !didCheckStartupLocation {
                didCheckStartupLocation = true
                if AppPreferences.startupLocationIsMissing {
                    showsStartupMissingAlert = true
                }
            }
            // 首次启动自动弹欢迎助手 —— 只跑一次，后续 layout 重渲染不会反复触发。
            if !didCheckWelcomeAssistant {
                didCheckWelcomeAssistant = true
                if !AppPreferences.welcomeAssistantCompleted {
                    // 异步触发让 onAppear 的其它处理先跑完；避免一打开主窗口就立刻被 sheet 盖住。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showsWelcomeAssistant = true
                    }
                }
            }
        }
        .sheet(isPresented: $showsWelcomeAssistant) {
            WelcomeAssistantView {
                showsWelcomeAssistant = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWelcomeAssistant)) { _ in
            // 用户从 SimpleZip 菜单触发 —— 不重置 completed bool（重新看仍然算「已经走过一遍」）。
            showsWelcomeAssistant = true
        }
        .alert(
            L10n.text("startup.missing.title"),
            isPresented: $showsStartupMissingAlert
        ) {
            // 「打开设置…」走 AppKit 旧式 selector，不依赖 macOS 14+ 的 @Environment(\.openSettings) —— 全版本都能开窗口。
            Button(L10n.text("startup.missing.openSettings")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            // 「重置为个人文件夹」清掉 startupLocation 配置 + 切到 home。
            // role: .cancel 是为了让回车键默认走重置（更安全的行为，不会带用户离开主界面）。
            Button(L10n.text("startup.missing.reset"), role: .cancel) {
                AppPreferences.resetStartupLocationToDefault()
                model.openHome()
            }
        } message: {
            Text(L10n.text("startup.missing.message"))
        }
        // **不要**挂 `.onOpenURL { ... }` —— SwiftUI WindowGroup 一旦看到这个 handler，每次系统传入新 URL
        // 时 SwiftUI 都会为它建一个**新窗口**满足 handler 触发条件，结果 `.siz` / `.szs` 双击一次就开一个新主窗口。
        // 唯一路径：AppDelegate.application(_:open:) → ExternalFileOpenQueue.enqueue → 下面这条 notification
        // → 现有 ContentView 用 drain() 自处理 → 当前窗口里弹 sheet。冷启动场景由 onAppear 里另一处 drain 兜住。
        .onReceive(NotificationCenter.default.publisher(for: .openExternalFile)) { _ in
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
        .onChange(of: model.pendingSIZOpen) { url in
            // model 在 SimpleZip 内点 .siz 时设的待处理 URL —— 跟 Finder 外部双击 .siz 同一处理流程。
            // 立即清空避免下一次设同一 URL 时 onChange 不触发。
            guard let url else { return }
            model.pendingSIZOpen = nil
            handleSIZOpen(url)
        }
        .onChange(of: model.pendingSZSOpen) { url in
            // 右键「测试」.szs 或者「打开」.szs 都走这条 —— 验证 sheet 同时充当 Test 的结果展示。
            guard let url else { return }
            model.pendingSZSOpen = nil
            handleSZSOpen(url)
        }
        .onChange(of: model.pendingSZSExtractHint) { url in
            // 右键「解压」.szs —— 不是压缩包没法解压。弹 alert 解释 + 提供「以虚拟目录浏览」按钮。
            guard let url else { return }
            model.pendingSZSExtractHint = nil
            szsExtractHintURL = url
        }
        .onChange(of: model.pendingSZSSilentVirtualBrowse) { url in
            // 右键「以虚拟目录浏览」—— 静默校验。OK 就直接进虚拟模式，有问题才弹 alert。
            guard let url else { return }
            model.pendingSZSSilentVirtualBrowse = nil
            handleSZSSilentVirtualBrowse(url)
        }
        .alert(
            L10n.text("szs.silentBrowse.warning.title"),
            isPresented: Binding(
                get: { szsSilentBrowseWarning != nil },
                set: { if !$0 { szsSilentBrowseWarning = nil } }
            ),
            presenting: szsSilentBrowseWarning
        ) { warning in
            Button(L10n.text("szs.silentBrowse.warning.continueButton")) {
                szsSilentBrowseWarning = nil
                model.openSZSAsVirtualFolder(
                    manifestURL: warning.sourceURL,
                    verifyReport: warning.verifyReport,
                    payloadRoot: warning.payloadRoot
                )
            }
            Button(L10n.text("szs.silentBrowse.warning.detailsButton")) {
                let pending = SZSPendingVerification(
                    sourceURL: warning.sourceURL,
                    signature: warning.signature,
                    manifest: warning.manifest
                )
                szsSilentBrowseWarning = nil
                pendingSZSVerification = pending
            }
            Button(L10n.text("button.cancel"), role: .cancel) {
                szsSilentBrowseWarning = nil
            }
        } message: { warning in
            Text(L10n.format("szs.silentBrowse.warning.message", warning.summary))
        }
        .alert(
            L10n.text("szs.extractHint.title"),
            isPresented: Binding(
                get: { szsExtractHintURL != nil },
                set: { if !$0 { szsExtractHintURL = nil } }
            )
        ) {
            Button(L10n.text("szs.extractHint.browseButton")) {
                if let url = szsExtractHintURL {
                    szsExtractHintURL = nil
                    handleSZSOpen(url)
                }
            }
            Button(L10n.text("button.cancel"), role: .cancel) {
                szsExtractHintURL = nil
            }
        } message: {
            Text(L10n.text("szs.extractHint.message"))
        }
        .onChange(of: model.pendingSIZExtract) { url in
            // 浏览器选 .siz 点 Extract → unwrap + 验签 + 标准解压对话框。同上清空策略。
            guard let url else { return }
            model.pendingSIZExtract = nil
            handleSIZExtract(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .finderServiceAction)) { _ in
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPreferencesChanged)) { _ in
            model.reload()
        }
    }

    private func handleFinderServiceAction(_ action: FinderServiceAction) {
        switch action {
        case .addToArchive(let urls):
            model.createArchive(fromFinderURLs: urls)
        case .calculateHash(let urls):
            model.calculateHash(forFinderURLs: urls)
        }
    }

    /// 处理 Finder / Open With / 拖到 Dock 图标等外部打开事件。
    private func openExternalURL(_ url: URL) {
        if FinderServiceActionQueue.shared.enqueue(fromCallbackURL: url) {
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            model.openFolder(url)
        } else if url.pathExtension.lowercased() == SIZArchive.extensionName {
            // `.siz` 容器：unwrap 到临时目录后把内层 archive 喂给原本的 external-archive 路径。
            // 必须在 `ArchiveService.isSupportedArchive` 之前判 —— 否则会落到 `NSWorkspace.shared.open(url)`
            // 兜底分支，又把 .siz 路由回 SimpleZip（UTI 已注册），导致无限重开主窗口。
            handleSIZOpen(url)
        } else if url.pathExtension.lowercased() == SZSArchive.extensionName {
            // `.szs` 签名清单：peek manifest → 弹 SZSVerificationSheet 跑校验。
            handleSZSOpen(url)
        } else if ArchiveService.isSupportedArchive(url) {
            // 用户开了「Finder 自动解压」+ 不是 DMG → 走独立浮窗 controller，主窗口不参与。
            // DMG 仍然走 model 走挂载浏览（没有「解压」语义）。
            let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
            if AppPreferences.finderOpenAutoExtract,
               supportedURL.pathExtension.lowercased() != "dmg" {
                ExternalExtractWindowController.shared.start(archiveURL: url)
                hideMainWindowIfPossible()
                return
            }
            // 关闭自动解压时与之前完全一致：走 model 浏览压缩包。
            model.openArchiveFromExternal(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// `.siz` 打开入口 —— unwrap + 验签后弹签名 sheet；确认后开内层 archive 浏览。
    /// 关 `gpgEnabled` 时跳过验签 + 不弹 sheet，直接开内层 archive（用户规则：关了 GPG 集成主页面不再出现 GPG UI）。
    /// 不管哪条分支：如果内层 archive 是加密包（`.gpg` 后缀），先 `SIZArchive.decryptInnerArchive` 再 open。
    private func handleSIZOpen(_ url: URL) {
        Task {
            do {
                let (innerArchiveURL, tempRoot, summary) = try await unwrapAndVerifySIZ(at: url)
                // 「Finder 自动解压」开 + 签名无问题（或 GPG 关闭 = 无可验签名）→ 静默解压到 .siz 所在文件夹，不弹 sheet。
                // 签名有问题（坏签 / 未知签名者 / 验签错误 / 不受信 / 有 concerns）→ 落到下面正常弹验签 sheet 让用户决定。
                if AppPreferences.finderOpenAutoExtract, sizSignatureIsClean(summary) {
                    let decrypted = try await decryptInnerArchiveIfNeeded(innerArchiveURL)
                    await MainActor.run {
                        ExternalExtractWindowController.shared.start(
                            archiveURL: decrypted,
                            destinationDirectoryOverride: url.deletingLastPathComponent(),
                            outputBaseNameOverride: url.deletingPathExtension().lastPathComponent,
                            displayName: url.lastPathComponent,
                            cleanupDirectory: tempRoot
                        )
                        hideMainWindowIfPossible()
                    }
                    return
                }
                if summary != nil {
                    await MainActor.run {
                        pendingSIZVerification = SIZPendingVerification(
                            innerArchiveURL: innerArchiveURL,
                            tempRoot: tempRoot,
                            signature: summary!
                        )
                    }
                } else {
                    // gpgEnabled = false：用户关了 GPG 集成；按规则不显示签名 sheet，但加密 .siz 仍要能解密打开
                    // （否则用户「关了集成」= 「打不开文件」就成 DOS）。这里 pinentry-mac 弹密码（如果加密的话）。
                    let urlToOpen = try await decryptInnerArchiveIfNeeded(innerArchiveURL)
                    await MainActor.run {
                        ensureMainWindowVisible()
                        model.openArchive(urlToOpen, displayedAs: url)
                    }
                }
            } catch {
                await MainActor.run { model.errorMessage = error.localizedDescription }
            }
        }
    }

    /// `.siz` 签名是否「没问题」—— 用于 Finder 自动解压决定是否静默直解。
    /// - summary == nil：用户关了 GPG 集成，没有可校验的签名 → 视为「无问题」（按规则不弹 GPG UI，直接解压，刚需例外）。
    /// - 仅 `.validSignature` 且**受信任、无 concerns** 才算干净；坏签 / 未知签名者 / 验签错误 / 不受信 / 有 concerns
    ///   都算「有问题」→ 调用方落回正常验签 sheet 让用户决定。
    private func sizSignatureIsClean(_ summary: SIZSignatureSummary?) -> Bool {
        guard let summary else { return true }
        if case .validSignature(_, _, let trusted, let concerns) = summary.verify {
            return trusted && concerns.isEmpty
        }
        return false
    }

    /// 共用解密 helper：检查内层 archive 是不是加密包（`.gpg` 后缀）—— 是 → 走 `SIZArchive.decryptInnerArchive`；
    /// 否 → 原样返回。
    /// - `decryptionKey` / `passphrase` 为 nil 时让 gpg-agent + pinentry-mac 兜底，二者非 nil 时优先用（loopback 模式）。
    /// - 跟解压路径共用 `SIZArchive.decryptInnerArchive`；这里专门服务 open 流程（SIZSignatureSheet 收完 UI 值再传过来）。
    /// - 后缀检查 `.lowercased()` 容错：自家 wrap 总小写但跨平台 / 手工拼包的 `.siz` 内层可能写 `archive.zip.GPG` 大写。
    private func decryptInnerArchiveIfNeeded(
        _ innerArchiveURL: URL,
        decryptionKey: String? = nil,
        passphrase: String? = nil
    ) async throws -> URL {
        guard innerArchiveURL.lastPathComponent.lowercased().hasSuffix(".gpg") else { return innerArchiveURL }
        return try await SIZArchive.decryptInnerArchive(
            encryptedURL: innerArchiveURL,
            decryptionKeyFingerprint: decryptionKey,
            passphrase: passphrase
        )
    }

    /// `.szs` 打开入口 —— peek manifest + 签名状态 → 弹 SZSVerificationSheet 跑文件级校验。
    /// 关 `gpgEnabled` 时**仍然弹 sheet**：签名块会显示「GPG 未启用」/「签名无法校验」状态，文件校验仍能跑（SHA256 不依赖 GPG）。
    private func handleSZSOpen(_ url: URL) {
        Task {
            do {
                let (signature, manifest) = try await SZSArchive.peek(manifestURL: url)
                await MainActor.run {
                    pendingSZSVerification = SZSPendingVerification(
                        sourceURL: url,
                        signature: signature,
                        manifest: manifest
                    )
                }
            } catch {
                await MainActor.run { model.errorMessage = error.localizedDescription }
            }
        }
    }

    /// 「以虚拟目录浏览」静默入口 —— 后台 verify，没问题就直接进虚拟模式不打扰用户；
    /// 发现签名问题 / 文件 SHA 不一致 / 文件缺失才弹 alert 让用户做决定。
    ///
    /// payloadRoot 推断：跟 SZSVerificationSheet 的默认逻辑一致 —— `.szs` 文件所在目录。
    /// 如果用户的 manifest 实际指向别处，他们用普通「打开」流程在 sheet 里手动选 root 才能继续。
    private func handleSZSSilentVirtualBrowse(_ url: URL) {
        let payloadRoot = url.deletingLastPathComponent()
        Task {
            do {
                let signature: GPGBackend.GPGVerifyResult
                let manifest: SZSArchive.Manifest
                let report: SZSArchive.VerifyReport
                if AppPreferences.gpgEnabled {
                    (signature, manifest) = try await SZSArchive.peek(manifestURL: url)
                    report = try await SZSArchive.verify(manifestURL: url, payloadRoot: payloadRoot)
                } else {
                    // GPG 未启用（常见原因是 gpg 没装）：走不依赖 GPG 的明文路径 —— 抽明文 manifest + 只跑文件 SHA256。
                    // `.szs` 是注册文件类型，「以虚拟目录浏览」不该因为缺 GPG 而失败；签名状态在 gpgEnabled 关时本就被忽略。
                    report = try SZSArchive.verifyWithoutSignature(manifestURL: url, payloadRoot: payloadRoot)
                    manifest = report.manifest
                    signature = report.signature
                }

                let issueSummary = silentBrowseIssueSummary(signature: signature, report: report)
                await MainActor.run {
                    if let summary = issueSummary {
                        szsSilentBrowseWarning = SZSSilentBrowseWarning(
                            sourceURL: url,
                            payloadRoot: payloadRoot,
                            signature: signature,
                            manifest: manifest,
                            verifyReport: report,
                            summary: summary
                        )
                    } else {
                        // 全部通过 —— 真的静默进虚拟模式，零打扰。
                        model.openSZSAsVirtualFolder(
                            manifestURL: url,
                            verifyReport: report,
                            payloadRoot: payloadRoot
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = L10n.format("szs.silentBrowse.peekFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 静默校验完看是否有「值得打扰用户」的问题。返回 nil = 完全 OK 静默进虚拟模式；返回非 nil 字符串 = alert 文案。
    /// - `gpgEnabled` 关时：忽略签名状态（用户本来就主动放弃 GPG UI），只看文件 SHA 问题；
    /// - 开时：要求签名 `.validSignature`（trust 等级不限，跟现有「绿色但 trusted=false 仍打开」一致）+ 全文件 `.match`。
    private func silentBrowseIssueSummary(
        signature: GPGBackend.GPGVerifyResult,
        report: SZSArchive.VerifyReport
    ) -> String? {
        var issues: [String] = []

        if AppPreferences.gpgEnabled {
            let signatureOK: Bool
            switch signature {
            case .validSignature: signatureOK = true
            default: signatureOK = false
            }
            if !signatureOK {
                issues.append(L10n.format("szs.silentBrowse.summary.signature", signatureStatusShortLabel(signature)))
            }
        }

        var mismatchCount = 0
        var missingCount = 0
        var unreadableCount = 0
        for entry in report.entries {
            switch entry {
            case .match: continue
            case .mismatch: mismatchCount += 1
            case .missing: missingCount += 1
            case .unreadable: unreadableCount += 1
            }
        }
        let badFiles = mismatchCount + missingCount + unreadableCount
        if badFiles > 0 {
            issues.append(L10n.format(
                "szs.silentBrowse.summary.files",
                badFiles,
                report.entries.count,
                mismatchCount,
                missingCount,
                unreadableCount
            ))
        }

        return issues.isEmpty ? nil : issues.joined(separator: " ")
    }

    /// 简短的签名状态文案，用于 silentBrowse summary。`.validSignature` 不调这里（OK 时不出 summary）。
    private func signatureStatusShortLabel(_ result: GPGBackend.GPGVerifyResult) -> String {
        switch result {
        case .validSignature: return L10n.text("szs.silentBrowse.signatureStatus.error")  // 兜底；正常不该走到
        case .badSignature: return L10n.text("szs.silentBrowse.signatureStatus.bad")
        case .unknownSigner: return L10n.text("szs.silentBrowse.signatureStatus.noPublicKey")
        case .verificationError: return L10n.text("szs.silentBrowse.signatureStatus.error")
        }
    }

    /// `.siz` 直接解压入口 —— unwrap + 验签 → 走标准解压对话框 `ExtractArchiveOptionsView`，
    /// 签名信息塞进 `request.sizSignature` 让对话框里多出几行签名状态展示。
    /// 关 `gpgEnabled` 时 sizSignature 为 nil，对话框完全跟普通 archive 一致。
    private func handleSIZExtract(_ url: URL) {
        Task {
            do {
                let (innerArchiveURL, _, summary) = try await unwrapAndVerifySIZ(at: url)
                await MainActor.run {
                    let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
                    model.extractArchiveRequest = ExtractArchiveRequest(
                        archiveURL: innerArchiveURL,
                        destinationURL: url.deletingLastPathComponent(),
                        password: preset,
                        detectedZipEncryption: ArchiveService.detectZipEncryption(in: innerArchiveURL),
                        sizSignature: summary
                    )
                }
            } catch {
                await MainActor.run { model.errorMessage = error.localizedDescription }
            }
        }
    }

    /// 共用 helper：unwrap `.siz` 到 /tmp 临时目录，若 `gpgEnabled` 开则跑 SIZArchive.verify（gpg 验签 + SHA 校验）。
    /// 返回值 summary：nil = 用户关了 GPG 集成（按规则隐藏所有 GPG UI）；非 nil = 给 sheet / 解压对话框展示用。
    private func unwrapAndVerifySIZ(
        at sourceURL: URL
    ) async throws -> (innerArchiveURL: URL, tempRoot: URL, summary: SIZSignatureSummary?) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-SIZ-Unwrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let unwrap = try await SIZArchive.unwrap(at: sourceURL, to: tempRoot)

        // 用户关 GPG 集成 = 主页面所有 GPG 相关入口隐藏（打开 .siz 是刚需例外，但不能露 GPG UI）。
        guard AppPreferences.gpgEnabled else {
            return (unwrap.innerArchiveURL, tempRoot, nil)
        }

        // gpg 后端不可用时，等同于「gpg 验签失败」走 verificationError 一支。文案让用户知道是后端缺失。
        let verify: GPGBackend.GPGVerifyResult
        if GPGBackend.isAvailable() {
            do {
                verify = try await SIZArchive.verify(unwrap: unwrap)
            } catch {
                verify = .verificationError(message: error.localizedDescription)
            }
        } else {
            verify = .verificationError(message: L10n.text("siz.verify.gpgMissing.title"))
        }

        let storedSigner = unwrap.metadata.signature.signerUserID
        let displaySigner: String = {
            // 优先 gpg 返回的 signer（最新版本可能比 metadata 记录的更准）；否则退回 metadata；都没有就「未知」。
            if case .validSignature(let signer, _, _, _) = verify, let signer { return signer }
            if case .badSignature(let signer, _) = verify, let signer { return signer }
            return storedSigner.isEmpty ? L10n.text("siz.signatureSheet.unknownSigner") : storedSigner
        }()

        return (
            unwrap.innerArchiveURL,
            tempRoot,
            SIZSignatureSummary(
                sourceURL: sourceURL,
                signerDisplay: displaySigner,
                signerFingerprint: unwrap.metadata.signature.signerFingerprint,
                signedAt: unwrap.metadata.createdAt,
                verify: verify,
                encryption: unwrap.metadata.encryption
            )
        )
    }

    /// `.siz` 签名对话框 sheet 的承载状态。`id` 让 SwiftUI 把每次新打开当成新 sheet。
    struct SIZPendingVerification: Identifiable, Equatable {
        let id = UUID()
        let innerArchiveURL: URL
        let tempRoot: URL
        let signature: SIZSignatureSummary

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// `.szs` 签名清单验证 sheet 的承载状态。peek 完后赋值，触发 SZSVerificationSheet。
    struct SZSPendingVerification: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let signature: GPGBackend.GPGVerifyResult
        let manifest: SZSArchive.Manifest

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// 静默「以虚拟目录浏览」遇到问题时承载的 alert 状态。
    /// `summary` 是已经 L10n 拼好的人类可读摘要（含签名 + 文件问题）；alert 直接展示。
    /// 「查看详情」按钮回退到正常 SZSVerificationSheet 流程，复用 `peekSignature` + `manifest` 不再重 peek。
    struct SZSSilentBrowseWarning: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let payloadRoot: URL
        let signature: GPGBackend.GPGVerifyResult
        let manifest: SZSArchive.Manifest
        let verifyReport: SZSArchive.VerifyReport
        let summary: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// 主窗口被 `hideMainWindowIfPossible` orderOut 后，再次显示出来 ——
    /// 用于「.siz 用户确认要打开内层」之类「我们要让用户看到主窗口浏览」的场景。
    ///
    /// **不要**简单地 orderFront 所有 hidden 窗口 —— SwiftUI 的 Settings scene / Sparkle 更新窗口 / 关于面板
    /// 在第一次被打开后会作为 hidden NSWindow 留在 `NSApp.windows` 列表里。一并 orderFront 会在用户打开 `.siz`
    /// 时把 Settings 神秘弹出来，是真实用户反馈过的 bug（v0.1.8）。靠 identifier 子串识别辅助窗口排除。
    private func ensureMainWindowVisible() {
        for window in NSApp.windows where !window.isVisible && !Self.isAuxiliaryWindow(window) {
            // 不强制 makeKey —— 用户已经在跟签名对话框互动，让窗口出现但不抢焦点；NSWindow.orderFront 默认不夺焦。
            window.orderFront(nil)
        }
    }

    /// 识别 SwiftUI 的辅助窗口（Settings / Sparkle 更新 / About / **正在 dismissing 的 sheet 等**）。
    /// 靠 identifier 子串识别 —— locale-independent，也不依赖 SwiftUI / Sparkle 内部 NSWindow 子类。
    /// 任一关键词命中即视为辅助窗口，`ensureMainWindowVisible` 跳过。
    private static func isAuxiliaryWindow(_ window: NSWindow) -> Bool {
        // **sheet 窗口**：parent 指向附属的主窗口。SIZSignatureSheet 等正在 dismissing 时 isVisible 短暂为 false，
        // 旧版 ensureMainWindowVisible 把它 orderFront 又把刚要关掉的 sheet 拉回来 → 点了「打开」sheet 不消失的 bug。
        if window.parent != nil { return true }
        let id = (window.identifier?.rawValue ?? "").lowercased()
        if id.contains("settings") || id.contains("preferences") { return true }
        if id.contains("sparkle") || id.contains("update") { return true }
        if id.contains("about") { return true }
        // 兜底 title：SwiftUI Settings scene 标题是 OS 本地化的「Settings」/「设置」/「Preferences」/「设定」/「設定」等。
        let titleLower = window.title.lowercased()
        let knownAuxTitles: Set<String> = [
            "settings", "preferences", "设置", "偏好设置", "設定", "設置",
            "환경설정", "preferencias", "préférences", "einstellungen", "preferenze",
            "настройки", "การตั้งค่า"
        ]
        return knownAuxTitles.contains(window.title) || knownAuxTitles.contains(titleLower)
    }


    /// 把主窗口隐藏掉 —— Finder 自动解压时只显示浮窗，主窗口不该弹出。
    /// 冷启动场景：SwiftUI WindowGroup 已经构造了 ContentView，主窗口本能在 onAppear 之后短暂可见；
    /// 这里立即 orderOut 让它消失（用户感受不到「闪过」）。
    /// 已经热运行场景：主窗口在哪 / 是否可见，保持原样不动；如果主窗口已是 front，仍然降到后面。
    private func hideMainWindowIfPossible() {
        // ContentView 所在的 NSWindow 在 keyWindow / 第一个 windowGroup 里 —— 找出来 orderOut。
        // 通过 contentView 类型识别（NSHostingView 装的就是 SwiftUI 主窗口）。
        for window in NSApp.windows {
            if window.contentView is NSHostingView<AnyView> || window.identifier?.rawValue.hasPrefix("SimpleZip") == true || (window.title.contains("SimpleZip") && window.isVisible) {
                window.orderOut(nil)
            }
        }
        // 兜底：直接把 keyWindow 推走。external extract 浮窗的 makeKeyAndOrderFront 在调本函数之后才执行，
        // 所以当前 keyWindow 还是主窗口。
        NSApp.keyWindow?.orderOut(nil)
    }

    private func receiveDroppedFileURLs(from providers: [NSItemProvider]) -> Bool {
        extractDroppedFileURLs(from: providers) { urls in
            model.openDroppedURLs(urls)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
