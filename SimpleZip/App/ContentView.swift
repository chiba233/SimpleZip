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

    /// 工厂建窗时传入：窗口/标签出现后在本浏览器里浏览这个 URL（右键「在新标签 / 新窗口打开」用）。
    private let openURLOnAppear: URL?
    /// 工厂建窗时传入：窗口出现后直接以虚拟目录浏览这个已验签的 .szs（独立浮窗「在主窗口打开」用，免重验）。
    private let openSZSVirtualFolderOnAppear: SZSVirtualFolderRequest?
    init(openURLOnAppear: URL? = nil, openSZSVirtualFolderOnAppear: SZSVirtualFolderRequest? = nil) {
        self.openURLOnAppear = openURLOnAppear
        self.openSZSVirtualFolderOnAppear = openSZSVirtualFolderOnAppear
    }

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
        // focusedSceneObject 服务 WindowGroup 自动建的首窗；focusedObject 让工厂手建的窗口/标签
        // 在成为 key 且有焦点时也能被菜单命令（@FocusedObject）定位到。
        .focusedSceneObject(model)
        .focusedObject(model)
        // 给宿主 NSWindow 设原生标签属性（tabbingIdentifier + identifier）。
        .background(WindowAccessor())
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
        .sheet(item: $model.pendingGPGKeyImport) { request in
            GPGKeyImportSheet(request: request) { model.pendingGPGKeyImport = nil }
        }
        .onAppear {
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
            // 独立浮窗「在主窗口打开」.szs：已验签报告直达，直接进虚拟目录浏览，不再重弹验签 sheet。
            if let request = openSZSVirtualFolderOnAppear {
                model.openSZSAsVirtualFolder(
                    manifestURL: request.manifestURL,
                    verifyReport: request.report,
                    payloadRoot: request.payloadRoot
                )
            }
            // 右键「在新标签 / 新窗口打开」：工厂把目标 URL 传进来，本浏览器在出现后浏览它（强制浏览，不走自动解压）。
            if let url = openURLOnAppear { openURLInThisBrowser(url) }
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
            handleRunningExternalOpen()
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
        case .extract(let urls):
            // 「用 SimpleZip 解压」—— 受支持的压缩包走自动解压浮窗解到其所在文件夹。
            // DMG 是挂载不是解压，跳过；.siz/.szs 有各自打开流程，这里只处理普通压缩包。
            // 多选走**批量队列**（一个浮窗、串行、一个取消、一个失败汇总）——
            // 旧实现循环调 start 会替换浮窗但让旧任务在后台隐身续跑。
            let extractable = urls.filter { url in
                guard ArchiveService.isSupportedArchive(url) else { return false }
                let supported = ArchiveService.supportedArchiveURL(url) ?? url
                return supported.pathExtension.lowercased() != "dmg"
            }
            if !extractable.isEmpty {
                ExternalExtractWindowController.shared.startBatch(archiveURLs: extractable)
            }
        case .quickCreate(let format, let urls):
            // 和解压一样走独立浮窗（进度 + 活动中心 + 自动关窗），全程不碰主窗口。
            ExternalExtractWindowController.shared.startQuickCreate(format: format, sourceURLs: urls)
        }
    }

    /// 运行中收到外部打开通知（`.openExternalFile`）的总入口 —— 多标签下所有 ContentView 都会收到，
    /// 靠 `claimRouting()` 选出唯一认领者，避免每个标签各开一个新标签。
    ///
    /// - 纯「浮窗类」（Finder 自动解压普通压缩包）：原地 drain 处理，**不**开浏览标签（浮窗 + 隐藏主窗，与旧行为一致）。
    /// - 浏览类（文件夹 / `.siz` / `.szs` / 自动解压关的压缩包）：开**新标签**，把 URL 留在队列里让新标签的 `onAppear` 去 drain。
    private func handleRunningExternalOpen() {
        guard ExternalFileOpenQueue.shared.claimRouting() else { return }
        let pending = ExternalFileOpenQueue.shared.peek()
        guard !pending.isEmpty else { return }

        // 「就地处理、不开新标签」的两类：① 自动解压浮窗类（脱钩主窗口）；② `.gpg` 加密文件
        //（解密在当前窗口完成 + 进度反馈；密钥文件只弹导入 sheet —— 为它单开一个空标签很怪，用户已反馈）。
        let handledInCurrentWindow = pending.allSatisfy {
            opensInFloatWindowOnly($0) || GPGFileService.isRecognizedGPGFile($0)
        }
        if handledInCurrentWindow {
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        } else if AppPreferences.openExternalInNewTab {
            // 浏览类 + 设置为新标签 → 开新标签；不在这里 drain，URL 留给新标签 onAppear 的 drain（原子，落到新标签的 model）。
            MainWindowFactory.open(asTab: true)
        } else {
            // 设置为在当前标签打开 → 复用本窗口，直接 drain 处理。
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
    }

    /// 在「本浏览器」里浏览一个 URL（右键「在新标签 / 新窗口打开」用）——强制浏览语义，**不**走 Finder 自动解压。
    /// 文件夹 → 进入；`.siz`/`.szs` → 走各自验签流程；受支持压缩包 → 浏览。
    private func openURLInThisBrowser(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        let ext = url.pathExtension.lowercased()
        if isDirectory.boolValue && !FileBrowserService.isLocalFilePackage(url) {
            model.openFolder(url)
        } else if ext == SIZArchive.extensionName {
            handleSIZOpen(url)
        } else if ext == SZSArchive.extensionName {
            handleSZSOpen(url)
        } else if ArchiveService.isSupportedArchive(url) {
            // 强制浏览：直接进浏览，绝不走 openArchiveFromExternal —— 后者会遵循「Finder 自动解压」偏好，
            // 开了自动解压时它会把压缩包再解压一遍而非浏览，导致浮窗「在主窗口打开」打不开压缩包。
            model.openArchive(url)
        } else if GPGFileService.isRecognizedGPGFile(url) {
            handleGPGFileOpen(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 判定这个外部 URL「只会进自动解压浮窗、不需要浏览标签」。
    /// 镜像 `openExternalURL` 的分支：开了 Finder 自动解压时，受支持压缩包（非 dmg）+ `.siz` + `.szs` 全部走独立浮窗
    /// （彻底脱钩主窗口），不开浏览标签。关了自动解压才回到主窗口浏览。
    private func opensInFloatWindowOnly(_ url: URL) -> Bool {
        guard AppPreferences.finderOpenAutoExtract else { return false }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }
        let ext = url.pathExtension.lowercased()
        // `.siz`/`.szs` 开了自动解压一律浮窗（unwrap/验签/校验都在浮窗内完成，需要主窗口时浮窗里有「在主窗口打开」）。
        if ext == SIZArchive.extensionName || ext == SZSArchive.extensionName { return true }
        guard ArchiveService.isSupportedArchive(url) else { return false }
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        return supportedURL.pathExtension.lowercased() != "dmg"
    }

    /// 处理 Finder / Open With / 拖到 Dock 图标等外部打开事件。
    private func openExternalURL(_ url: URL) {
        if FinderServiceActionQueue.shared.enqueue(fromCallbackURL: url) {
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
            return
        }

        var isDirectory: ObjCBool = false
        let ext = url.pathExtension.lowercased()
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            activateForMainWindowOpen()
            model.openFolder(url)
        } else if ext == SIZArchive.extensionName {
            // `.siz` 容器：开了自动解压 → 独立浮窗内 unwrap+验签+解压，**彻底脱钩主窗口**（return，主窗口不动）。
            // 关了自动解压 → 主窗口浏览（unwrap → 验签 sheet → 开内层 archive）。
            if AppPreferences.finderOpenAutoExtract {
                ExternalExtractWindowController.shared.open(url)
                return
            }
            handleSIZOpen(url)
        } else if ext == SZSArchive.extensionName {
            // `.szs` 签名清单：开了自动解压 → 独立浮窗内 peek+校验，「以虚拟目录浏览」时才按需拉起主窗口。
            // 关了自动解压 → 主窗口弹 SZSVerificationSheet。
            if AppPreferences.finderOpenAutoExtract {
                ExternalExtractWindowController.shared.open(url)
                return
            }
            handleSZSOpen(url)
        } else if ArchiveService.isSupportedArchive(url) {
            // 用户开了「Finder 自动解压」+ 不是 DMG → 走独立浮窗 controller，主窗口完全不参与（不创建/不拉起/不隐藏）。
            // DMG 仍然走 model 挂载浏览（没有「解压」语义）。
            let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
            if AppPreferences.finderOpenAutoExtract,
               supportedURL.pathExtension.lowercased() != "dmg" {
                ExternalExtractWindowController.shared.open(url)
                return
            }
            // 关闭自动解压时与之前完全一致：走 model 浏览压缩包。
            activateForMainWindowOpen()
            model.openArchiveFromExternal(url)
        } else if GPGFileService.isRecognizedGPGFile(url) {
            handleGPGFileOpen(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// `.siz` **主窗口浏览**入口 —— unwrap + 验签后弹签名 sheet；确认后开内层 archive 浏览。
    /// 关 `gpgEnabled` 时跳过验签 + 不弹 sheet，直接开内层 archive（用户规则：关了 GPG 集成主页面不再出现 GPG UI）。
    /// 不管哪条分支：如果内层 archive 是加密包（`.gpg` 后缀），先 `SIZArchive.decryptInnerArchive` 再 open。
    ///
    /// 注意：Finder 自动解压（脱钩主窗口）由 `openExternalURL` 直接路由到 `ExternalExtractWindowController.open`，
    /// **不**经过这里。本函数是「强制在主窗口浏览」语义（右键在新标签打开 / app 内点 / 浮窗「在主窗口打开」），
    /// 与自动解压开关无关。
    private func handleSIZOpen(_ url: URL) {
        Task {
            do {
                let (innerArchiveURL, tempRoot, summary) = try await unwrapAndVerifySIZ(at: url)
                if summary != nil {
                    await MainActor.run {
                        // 验签有问题（坏签 / 未知签名者 / 验签错误 / 不受信 / 有 concerns）→ 弹验签 sheet
                        // 让用户决定。即使开了「Finder 自动解压」也要把主窗口唤起来 —— 否则 sheet 挂在
                        // 没前置的窗口上，用户只看到 app 起来了却没弹任何东西（用户特别提醒的场景）。
                        activateForMainWindowOpen()
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
                // unwrap / 解密 / 验签过程报错也要把窗口唤起来，否则错误 alert 挂在没前置的主窗口上，
                // 从 Finder 双击 .siz 时用户只看到程序起来却没有任何提示。
                await MainActor.run {
                    activateForMainWindowOpen()
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 共用解密 helper —— 转调共享服务（SIZSignatureSheet 收完 UI 值后调；解压路径同样复用）。
    private func decryptInnerArchiveIfNeeded(
        _ innerArchiveURL: URL,
        decryptionKey: String? = nil,
        passphrase: String? = nil
    ) async throws -> URL {
        try await SignedContainerService.decryptInnerArchiveIfNeeded(
            innerArchiveURL,
            decryptionKey: decryptionKey,
            passphrase: passphrase
        )
    }

    /// 双击 / 右键打开一个 `.gpg`/`.pgp`/`.asc` 文件 —— 唤起主窗口后把整条编排交给 model
    /// （门控 / 嗅探 / 解密进度 / 取消静默 / app 内路由都在 `model.openGPGFile`，见 +GPG）。
    private func handleGPGFileOpen(_ url: URL) {
        activateForMainWindowOpen()
        model.openGPGFile(url)
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

    /// 共用 helper：unwrap `.siz` + 验签 —— 转调共享服务（主窗口与独立浮窗路径共用）。
    private func unwrapAndVerifySIZ(
        at sourceURL: URL
    ) async throws -> (innerArchiveURL: URL, tempRoot: URL, summary: SIZSignatureSummary?) {
        try await SignedContainerService.unwrapAndVerifySIZ(at: sourceURL)
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

    /// 把 SimpleZip 的主内容窗口（若被 orderOut / 隐藏）重新 orderFront ——
    /// 用于「关闭自动解压时从 Finder 打开 / .siz 用户确认要浏览内层」等「要让用户看到主窗口」的场景。
    ///
    /// **只**把 SimpleZip 的主内容窗口 orderFront，绝不碰其它任何 hidden 窗口。
    ///
    /// 用「白名单」（`MainWindow.isMainContentWindow`）而不是旧的「黑名单」（`!isAuxiliaryWindow`）——
    /// 黑名单只认得 Settings / Sparkle / About，认不出**已关闭的 QLPreviewPanel**（用户关快速查看 = orderOut →
    /// isVisible=false 的 hidden 窗口）。旧逻辑会把这种 hidden QL 面板一并 orderFront，于是打开 / 测试 `.siz`
    /// 就把用户早先关掉的快速查看面板神秘地顶回来。白名单只认我们自己的浏览窗口，
    /// QL 面板 / 哈希进度面板 / 解压浮窗 / Settings 等一律不动。
    private func ensureMainWindowVisible() {
        for window in NSApp.windows where !window.isVisible && MainWindow.isMainContentWindow(window) {
            // 不强制 makeKey —— 用户已经在跟签名对话框互动，让窗口出现但不抢焦点；NSWindow.orderFront 默认不夺焦。
            window.orderFront(nil)
        }
    }

    /// 外部打开（Finder 双击 / 打开方式 / 拖到 Dock）要用主窗口浏览时，把 app 激活并把主窗口前置。
    ///
    /// 修复用户反馈：app 已在后台运行时从 Finder 打开压缩包，只是「打开了程序」却没唤起窗口，
    /// 得再点一下 Dock 图标才进得去。根因是这条路径从不 `NSApp.activate` / 前置主窗口
    /// （只有 Finder 服务路径做了）。
    ///
    /// 放在 drain 时机（`openExternalURL`）而不是 `AppDelegate.application(_:openFile:)`：冷启动时
    /// openFile 早于 SwiftUI 主窗口建出来，那会儿 activate 会丢。这里 onAppear / 通知触发，窗口已存在。
    /// 仅在「确实要显示主窗口」的分支调用 —— Finder 自动解压走浮窗、主窗口被 orderOut，不能在那条路径前置。
    private func activateForMainWindowOpen() {
        NSApp.activate(ignoringOtherApps: true)
        ensureMainWindowVisible()
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
