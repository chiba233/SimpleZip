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
        .sheet(item: $pendingSIZVerification) { pending in
            SIZSignatureSheet(
                pending: pending,
                onOpen: {
                    pendingSIZVerification = nil
                    ensureMainWindowVisible()
                    // 用 archive 浏览模式 —— Extract / Hash / 打开单文件按钮都正常工作。
                    // 关键：`displayedAs: pending.sourceURL` 让 model 的 title / locationText 显示
                    // 原始 .siz 路径（如 `~/Desktop/1.siz`），而不是丑陋的 inner URL
                    // `/var/folders/.../T/SimpleZip-SIZ-Unwrap-xxx/archive.zip`。
                    model.openArchive(pending.unwrap.innerArchiveURL, displayedAs: pending.sourceURL)
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
            // 「打开设置…」走和 SettingsRequestBridge 同款的旧式 selector 路径，
            // 这样不依赖 macOS 14+ 的 @Environment(\.openSettings) —— 全版本都能开窗口。
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
        .onOpenURL { url in
            openExternalURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openExternalFile)) { _ in
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSIZContainer)) { notification in
            // model 在 SimpleZip 内点 .siz 时发的通知 —— 走 ContentView 的 handleSIZOpen 路径，
            // 跟 Finder 外部双击 .siz 同一处理流程，主窗口不会被复制创建新实例。
            if let url = notification.object as? URL {
                handleSIZOpen(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .finderServiceAction)) { _ in
            FinderServiceActionQueue.shared.drain().forEach(handleFinderServiceAction)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserPreferencesChanged)) { _ in
            model.reload()
        }
        .background {
            if #available(macOS 14.0, *) {
                SettingsRequestBridge()
            }
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

    /// `.siz` 容器入口：unwrap → GPG 验签 → **设置 state** 让 SwiftUI sheet 显示签名信息对话框。
    /// sheet 的 Open / Cancel 按钮在 `SIZSignatureSheet` 里处理；之前用 NSAlert 在 SwiftUI 视图 context
    /// 里渲染会变成无 chrome 的浮动框 + 关闭不可控（截图里反复出现），改用 sheet 行为可控。
    private func handleSIZOpen(_ url: URL) {
        Task {
            do {
                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SimpleZip-SIZ-Unwrap-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                let unwrap = try await SIZArchive.unwrap(at: url, to: tempRoot)

                // GPG 没装 → 让用户看到原因，选择跳过验签还是取消。装了 → 跑 verify 拿四态结果。
                let verifyResult: SIZVerificationOutcome
                if GPGBackend.isAvailable() {
                    do {
                        let gpgResult = try await GPGBackend.verify(
                            archiveURL: unwrap.innerArchiveURL,
                            signatureURL: unwrap.signatureURL
                        )
                        verifyResult = .gpgResult(gpgResult)
                    } catch {
                        verifyResult = .verificationError(error.localizedDescription)
                    }
                } else {
                    verifyResult = .gpgMissing
                }

                await MainActor.run {
                    pendingSIZVerification = SIZPendingVerification(
                        sourceURL: url,
                        tempRoot: tempRoot,
                        unwrap: unwrap,
                        outcome: verifyResult
                    )
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 验签结果的「上一层」枚举 —— 因为 `GPGBackend.GPGVerifyResult` 不能表达「gpg 根本没装」这种情况，
    /// 我们在外面再套一层。
    enum SIZVerificationOutcome: Equatable {
        case gpgResult(GPGBackend.GPGVerifyResult)
        case verificationError(String)
        case gpgMissing
    }

    /// `.siz` 签名对话框 sheet 的承载状态。`id` 让 SwiftUI 把每次新打开当成新 sheet。
    struct SIZPendingVerification: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let tempRoot: URL
        let unwrap: SIZArchive.UnwrapResult
        let outcome: SIZVerificationOutcome

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// 主窗口被 `hideMainWindowIfPossible` orderOut 后，再次显示出来 ——
    /// 用于「.siz 用户确认要打开内层」之类「我们要让用户看到主窗口浏览」的场景。
    private func ensureMainWindowVisible() {
        for window in NSApp.windows where !window.isVisible {
            // 不强制 makeKey —— 用户已经在跟签名对话框互动，让窗口出现但不抢焦点；NSWindow.orderFront 默认不夺焦。
            window.orderFront(nil)
        }
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
        let fileURLProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileURLProviders.isEmpty else { return false }

        var urls = Array<URL?>(repeating: nil, count: fileURLProviders.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, provider) in fileURLProviders.enumerated() {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }

                if let data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls[index] = url
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            model.openDroppedURLs(urls.compactMap { $0 })
        }

        return true
    }
}

@available(macOS 14.0, *)
private struct SettingsRequestBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenSettingsColumns)) { _ in
                SettingsNavigation.prepareOpenColumns()
                openSettings()
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
