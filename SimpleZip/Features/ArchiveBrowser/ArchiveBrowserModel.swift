//
//  ArchiveBrowserModel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 主界面的状态模型：负责文件浏览、压缩/解压动作和状态提示。
@MainActor
final class ArchiveBrowserModel: ObservableObject {
    @Published var mode: BrowserMode
    @Published var fileItems: [FileItem] = []
    @Published var archiveItems: [ArchiveItem] = []
    @Published var selection = Set<UUID>()
    @Published var selectedArchiveRows = Set<UUID>()
    @Published var status = L10n.text("status.ready")
    @Published var isWorking = false
    /// 失败 alert 的完整文案；setter 在 `errorMessage` 上 trim 一次。`nil` = 不展示 alert。
    /// 之前用 `ArchiveOperationFailureAlert` wrapper 包了一层「fullMessage + previewLimit + previewMessage」，
    /// 但 previewLimit 从未被设过其它值，wrapper 跟 `errorMessage` getter/setter 互相把对方藏起来，是过度抽象。
    @Published private var operationFailureFullMessage: String?
    @Published var hashReport: HashReport?
    @Published var benchmarkRequest: SevenZipBenchmarkRequest?
    @Published var benchmarkSession: SevenZipBenchmarkSession?
    @Published var operationDetailsSession: ArchiveOperationDetailsSession?
    @Published var isShowingOperationDetails = false
    @Published var archiveCreationRequest: ArchiveCreationRequest?
    @Published var extractArchiveRequest: ExtractArchiveRequest?
    @Published var extractSelectionRequest: ExtractSelectionRequest?
    @Published var operationProgress = ArchiveProgressState()
    @Published private(set) var canCancelCurrentOperation = false
    @Published private var navigationBackStack: [NavigationLocation] = []
    @Published private var navigationForwardStack: [NavigationLocation] = []
    /// 镜像自 macOS Finder「个人收藏」侧栏。
    ///
    /// 放在 model 而不是 Sidebar 的 `@State` —— 之前用 `@State` 时主线程赋值后 NSLog 能确认值已到 9，
    /// `favoriteRows` getter 也能读到 9，但屏幕仍然显示初始的 0（fallback 分支）。
    /// 推测是 SwiftUI 在 NavigationSplitView 里对 Sidebar 的 @State 在某条路径上失了 view 身份，
    /// 改用 ObservableObject 的 @Published 后这条路径被绕开。
    @Published var finderFavorites: [FinderFavoritesReader.Item] = []

    /// 「显示路径」覆盖 —— 用于 `.siz` 这种「内层 archive 实际在 /tmp、用户心智里是原文件」的场景。
    /// 设了之后，`title` / `locationText` / `editableLocationText` 都用这个 URL 代替真实的 inner URL，
    /// 用户看到的路径就是 `~/Desktop/xxx.siz` 而不是 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-UUID/archive.zip`。
    /// 切换到其它 mode（folder / tag）或非 SIZ archive 时由 `openArchive` 自动清空。
    @Published var archiveDisplayOverride: URL?

    /// `.siz` 容器在 SimpleZip 内被点开时的待处理 URL —— ContentView 用 `.onChange` 接住跑 unwrap + 验签 sheet。
    /// 不能走 `NSWorkspace.shared.open`：`.siz` UTI 注册到自己会循环创建新主窗口。
    /// 用 @Published 而不是 Notification.Name —— 单发单收的「函数调用穿了通知马甲」（AGENTS A3）。
    @Published var pendingSIZOpen: URL?

    /// 文件浏览模式选中 `.siz` 点 Extract 时的待处理 URL —— ContentView 用 `.onChange` 接住跑 unwrap + 验签 +
    /// 标准解压对话框。同 `pendingSIZOpen` 的解耦原则。
    @Published var pendingSIZExtract: URL?

    private let fileManager = FileManager.default
    private let extractionCoordinator = ArchiveExtractionCoordinator(fileManager: .default)
    /// 打开的压缩包内容 + 当前路径 + 合成目录派生。生命周期等同于 model。
    private let session = ArchiveSession()
    /// 用户主动用「以压缩包打开」打开过的文件 URL 集合（已 standardize）。
    /// 当前导航位置的 archive URL 出现在这里 → 后端调用统一加 `force: true`，
    /// 让 ArchiveService 跳过扩展名校验直接走 7-Zip。`.exe` `.apk` `.ipa` 等本质是 ZIP/NSIS
    /// 的非典型压缩包就是这类用户场景。
    private var forcedArchiveURLs: Set<URL> = []
    /// 本地文件浏览相关的纯逻辑（列目录 / 标签搜索 / FileItem 构造 / 路径补全）。
    private let fileBrowser = FileBrowserService()
    /// 「一次一个」长任务的生命周期管理（取消、ID 跟踪、跟 ArchiveService 的子进程联动）。
    private let operationRunner = ArchiveOperationRunner()
    private var fileClipboard: (urls: [URL], shouldMove: Bool)?
    private var loadTask: Task<Void, Never>?
    private var activeLoadGeneration = 0
    private var mountedDiskImage: MountedDiskImageSession?
    private var openedArchiveItemDirectories: [URL] = []

    init() {
        TemporaryResourceManager.cleanStaleOpenedArchiveItems(fileManager: fileManager)
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        finderFavorites = FinderFavoritesReader.readWithCache()
        reload()
    }

    deinit {
        let openedArchiveItemDirectories = openedArchiveItemDirectories
        Task.detached {
            for directory in openedArchiveItemDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        if let mountedDiskImage {
            Task.detached {
                try? await ArchiveService.detachDiskImage(at: mountedDiskImage.mountPoint)
            }
        }
    }

    var title: String {
        switch mode {
        case .folder(let url):
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .archive(let url):
            return (archiveDisplayOverride ?? url).lastPathComponent
        case .tag(let tag):
            return tag
        }
    }

    var locationText: String {
        switch mode {
        case .folder(let url):
            return url.path
        case .archive(let url):
            // `archiveDisplayOverride` 给 `.siz` 这种「内层 archive 实际在 /tmp，但用户心智里是
            // 桌面的 `xxx.siz`」的场景用 —— 显示原始 .siz 路径而不是丑陋的 `/var/folders/...`。
            let displayed = archiveDisplayOverride ?? url
            let baseLocation = L10n.format("location.archive", displayed.path)
            let path = session.archivePath
            return path.isEmpty ? baseLocation : "\(baseLocation) / \(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        }
    }

    var editableLocationText: String {
        switch mode {
        case .folder(let url):
            return url.path
        case .archive(let url):
            let displayed = archiveDisplayOverride ?? url
            let path = session.archivePath
            return path.isEmpty ? displayed.path : displayed.path + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        }
    }

    var selectedFileItems: [FileItem] {
        fileItems.filter { selection.contains($0.id) }
    }

    var selectedArchiveItems: [ArchiveItem] {
        archiveItems.filter { selectedArchiveRows.contains($0.id) }
    }

    var errorMessage: String? {
        get { operationFailureFullMessage }
        set { operationFailureFullMessage = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 截断到 600 字符给 alert 顶部预览（避免上百行 stderr 撑爆弹窗）。完整文案仍存 `errorMessage`，
    /// 用户点「打开详情」走 operationDetailsSession 看完整内容。截断逻辑在 Core 里有专属单测。
    var operationFailurePreviewMessage: String {
        guard let message = operationFailureFullMessage else { return "" }
        return ArchiveOperationFailurePreview.truncate(message)
    }

    var isShowingOperationFailureAlert: Bool {
        operationFailureFullMessage != nil
    }

    var canGoUp: Bool {
        if case .tag = mode {
            return false
        }
        if case .folder(let url) = mode {
            return url.path != "/"
        }
        return true
    }

    var canGoBack: Bool {
        !navigationBackStack.isEmpty
    }

    var canGoForward: Bool {
        !navigationForwardStack.isEmpty
    }

    func openHome() {
        openFolder(fileManager.homeDirectoryForCurrentUser)
    }

    func openDownloads() {
        openFolder(fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openDesktop() {
        openFolder(fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openDocuments() {
        openFolder(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openApplications() {
        openFolder(URL(fileURLWithPath: "/Applications"))
    }

    func openTag(_ tag: String) {
        archiveDisplayOverride = nil
        recordCurrentLocationForNavigation()
        cleanupMountedDiskImageIfNeeded(for: nil)
        session.clearArchive()
        mode = .tag(tag)
        reload()
    }

    func pinCurrentFolderToSidebar() {
        guard case .folder(let url) = mode else { return }
        AppPreferences.pinSidebarURL(url)
        status = L10n.format("status.pinnedLocation", url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    }

    func openLocationText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .archive(let archiveURL):
            openArchiveLocationText(trimmed, archiveURL: archiveURL)
        case .folder, .tag:
            openFolder(lastExistingFolder(for: URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)))
        }
    }

    func locationCompletions(for text: String) -> [LocationCompletion] {
        guard case .folder(let currentFolder) = mode else { return [] }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return fileBrowser.directoryCompletions(
                in: currentFolder, matching: "",
                showHiddenFiles: AppPreferences.showHiddenFiles,
                showSymbolicLinks: AppPreferences.showSymbolicLinks
            )
        }

        let expandedQuery = NSString(string: query).expandingTildeInPath
        let queryURL = URL(fileURLWithPath: expandedQuery)
        var isDirectory = ObjCBool(false)

        if query.hasSuffix("/") || fileManager.fileExists(atPath: queryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
            return fileBrowser.directoryCompletions(
                in: queryURL, matching: "",
                showHiddenFiles: AppPreferences.showHiddenFiles,
                showSymbolicLinks: AppPreferences.showSymbolicLinks
            )
        }

        let parentURL = queryURL.deletingLastPathComponent()
        let prefix = queryURL.lastPathComponent
        return fileBrowser.directoryCompletions(
            in: parentURL, matching: prefix,
            showHiddenFiles: AppPreferences.showHiddenFiles,
            showSymbolicLinks: AppPreferences.showSymbolicLinks
        )
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openFolder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openArchive")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveService.supportedArchiveTypes
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let url = panel.url {
            openArchive(url)
        }
    }

    func openFolder(_ url: URL) {
        // 切换到文件夹模式 → 清掉 .siz 残留的「显示路径覆盖」，避免老覆盖泄漏到下次 archive 打开。
        archiveDisplayOverride = nil
        openFolder(url, recordsHistory: true)
    }

    private func openFolder(_ url: URL, recordsHistory: Bool) {
        let destination = NavigationLocation.folder(url.standardizedFileURL)
        if recordsHistory, currentNavigationLocation != destination {
            recordCurrentLocationForNavigation()
        }
        cleanupMountedDiskImageIfNeeded(for: url)
        session.clearArchive()
        mode = .folder(url)
        if let mountedDiskImage {
            if !url.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
                AppPreferences.rememberLastFolder(url)
            }
        } else {
            AppPreferences.rememberLastFolder(url)
        }
        reload()
    }

    func openArchive(_ url: URL) {
        archiveDisplayOverride = nil
        openArchive(url, recordsHistory: true)
    }

    /// 打开「内层 archive」但对外用 `displayedAs` 的路径展示 —— 给 `.siz` 用。
    /// inner URL 真的在 /tmp，但用户看到的「源文件」是桌面 / 下载里的原始 `.siz`。
    func openArchive(_ url: URL, displayedAs displayURL: URL) {
        archiveDisplayOverride = displayURL
        openArchive(url, recordsHistory: true)
    }

    /// 把任意文件「以压缩包打开」—— 不走扩展名校验，强制按 7-Zip 后端处理。
    ///
    /// 用户场景：.exe / .apk / .ipa / .jar / 各种非典型 archive。
    /// 入口：FileTable 右键菜单 + File 主菜单 → 「以压缩包打开」。
    /// 实现：把 URL 记到 `forcedArchiveURLs`，随后用现有 openArchive 流程走，
    /// `loadArchive` / `performExtract*` / `testArchive` 等都靠 `isForced(_:)` 判断要不要传 force。
    /// 不是有效压缩包时 ArchiveService.list 会抛 ArchiveError，正常走「读取压缩包失败」错误展示。
    func openAsArchive(_ url: URL) {
        forcedArchiveURLs.insert(url.standardizedFileURL)
        openArchive(url)
    }

    /// 当前 URL 是否已被标记为「强制以压缩包打开」。
    /// 用 standardizedFileURL 比较 —— 同一文件可能以不同形式（resolve / 非 resolve）传入。
    private func isForced(_ url: URL) -> Bool {
        forcedArchiveURLs.contains(url.standardizedFileURL)
    }

    /// 外部入口（Finder 双击 / Open With / 服务调用）打开压缩包的路由。
    ///
    /// 按用户在「通用」设置里的偏好分两条路：
    /// - `finderOpenAutoExtract` 关：与之前完全一致，进 SimpleZip 浏览压缩包内容；
    /// - 开：直接解压到压缩包所在目录，不进浏览。同时若开启了「预设密码」，
    ///   request 的初始 password 就预填入预设值，免去用户再次手动确认。
    /// DMG 当作可挂载卷处理，不走「解压」路径 —— 没有解压语义，仍打开浏览。
    func openArchiveFromExternal(_ url: URL) {
        guard AppPreferences.finderOpenAutoExtract else {
            openArchive(url)
            return
        }
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        if supportedURL.pathExtension.lowercased() == "dmg" {
            openArchive(url)
            return
        }
        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        let request = ExtractArchiveRequest(
            archiveURL: supportedURL,
            destinationURL: supportedURL.deletingLastPathComponent(),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: supportedURL)
        )
        performExtractArchive(request)
    }

    private func openArchive(_ url: URL, recordsHistory: Bool) {
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        if supportedURL.pathExtension.lowercased() == "dmg" {
            if recordsHistory, currentNavigationLocation != .folder(supportedURL.standardizedFileURL) {
                recordCurrentLocationForNavigation()
            }
            openDiskImage(supportedURL)
            return
        }
        let destination = NavigationLocation.archive(supportedURL.standardizedFileURL, "")
        if recordsHistory, currentNavigationLocation != destination {
            recordCurrentLocationForNavigation()
        }
        cleanupMountedDiskImageIfNeeded(for: nil)
        session.clearArchive()
        mode = .archive(supportedURL)
        reload()
    }

    func open(_ item: FileItem) {
        if FileBrowserService.isNavigableDirectory(item) {
            openFolder(item.url)
        } else if item.url.pathExtension.lowercased() == "siz" {
            // `.siz` 走 ContentView 的专用 handle：unwrap → 签名验证对话框 → 解压到 /tmp → 浏览。
            // 不能走 `NSWorkspace.shared.open`，否则系统按 UTI 把文件转回 SimpleZip 又创建新窗口。
            pendingSIZOpen = item.url
        } else if ArchiveService.isSupportedArchive(item.url) {
            openArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func canShowPackageContents(_ item: FileItem) -> Bool {
        item.isDirectory && FileBrowserService.isLocalFilePackage(item.url)
    }

    func showPackageContents(_ item: FileItem) {
        guard canShowPackageContents(item) else { return }
        openFolder(item.url)
    }

    func open(_ item: ArchiveItem) {
        if item.isDirectory, !isOpenableArchiveDirectoryPackage(item) {
            openArchiveDirectory(item)
            return
        }
        openArchiveItemExternally(item)
    }

    private func openArchiveDirectory(_ item: ArchiveItem) {
        let destinationPath = ArchiveSession.normalizedDirectoryPrefix(item.name)
        if currentNavigationLocation != .archive(currentArchiveURLForNavigation, destinationPath) {
            recordCurrentLocationForNavigation()
        }
        session.setArchivePath(destinationPath)
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    private func openArchiveItemExternally(_ item: ArchiveItem) {
        guard case .archive(let archiveURL) = mode else { return }

        if ArchiveSafety.requiresExternalOpenConfirmation(item), !allowPotentiallyUnsafeArchiveItemOpen(item) {
            return
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else { return }
        let detectedZipEncryption = archiveURL.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: archiveURL)
            : .unknown
        let shouldPromptBeforeExtraction = ArchiveService.archiveItemsSuggestPasswordRequirement(entries, in: archiveURL)

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            var extractedDiskImageURL: URL?
            let didSucceed = await runArchiveTask(L10n.format("status.openingArchiveItem", item.displayName)) { progress in
                let destination = try self.makeArchiveItemOpenDirectory()
                self.openedArchiveItemDirectories.append(destination)
                try self.confirmArchiveExtractionSafety(entries: entries)
                // 预设密码可用时把它作为首选 —— 这样用户不必看到弹窗（除非预设是错的）。
                // 没有预设时 password 仍是空字符串，原本「先弹窗再尝试」的路径完整保留。
                let hasPreset = AppPreferences.hasUsablePresetPassword
                var password = hasPreset ? AppPreferences.presetPassword : ""
                var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
                var isRetry = false

                if shouldPromptBeforeExtraction && !hasPreset {
                    guard let authentication = self.promptForArchiveItemPassword(
                        item: item,
                        archiveURL: archiveURL,
                        detectedZipEncryption: detectedZipEncryption,
                        isRetry: false
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }

                let force = self.isForced(archiveURL)
                while true {
                    do {
                        try? self.fileManager.removeItem(at: destination)
                        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                        try await ArchiveService.extract(
                            archiveURL,
                            entries: entries,
                            to: destination,
                            overwriteBehavior: .overwrite,
                            pathMode: .preserve,
                            password: password,
                            zipDecryptionMethod: zipDecryptionMethod,
                            safetyPolicy: .skipValidation,
                            operationID: operationID,
                            progress: progress,
                            force: force
                        )
                        try self.confirmExtractedArchiveLinks(at: destination)

                        let extractedURL = try self.extractedURL(for: item, in: destination)
                        if extractedURL.pathExtension.lowercased() == "dmg" {
                            extractedDiskImageURL = extractedURL
                            return
                        }
                        guard NSWorkspace.shared.open(extractedURL) else {
                            throw ArchiveError.openExtractedItemFailed
                        }
                        return
                    } catch {
                        guard self.shouldPromptForArchivePassword(error) else {
                            throw error
                        }
                        guard let authentication = self.promptForArchiveItemPassword(
                            item: item,
                            archiveURL: archiveURL,
                            detectedZipEncryption: detectedZipEncryption,
                            isRetry: isRetry
                        ) else {
                            throw CancellationError()
                        }
                        password = authentication.password
                        zipDecryptionMethod = authentication.zipDecryptionMethod
                        isRetry = true
                    }
                }
            }
            if didSucceed {
                if let extractedDiskImageURL {
                    openDiskImage(extractedDiskImageURL)
                } else {
                    status = L10n.format("status.openedArchiveItem", item.displayName)
                }
            }
        }
    }

    func exportArchiveItem(_ item: ArchiveItem, to destinationFolder: URL) async throws {
        guard case .archive(let archiveURL) = mode else {
            throw ArchiveError.unsupportedFormat
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else {
            throw ArchiveError.extractedItemNotFound
        }

        status = L10n.format("status.exportingArchiveItem", item.displayName)
        let stagingURL = try extractionCoordinator.makeExtractionStagingDirectory()
        defer { try? fileManager.removeItem(at: stagingURL) }

        try confirmArchiveExtractionSafety(entries: entries)
        try await ArchiveService.extract(
            archiveURL,
            entries: entries,
            to: stagingURL,
            overwriteBehavior: .overwrite,
            pathMode: .preserve,
            safetyPolicy: .skipValidation,
            force: isForced(archiveURL)
        )
        try confirmExtractedArchiveLinks(at: stagingURL)

        let extractedURL = try extractedURL(for: item, in: stagingURL)
        let destinationURL = destinationFolder.appendingPathComponent(item.displayName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw ArchiveError.exportDestinationExists
        }
        try fileManager.moveItem(at: extractedURL, to: destinationURL)
        status = L10n.format("status.exportedArchiveItem", item.displayName)
    }

    private func confirmOpeningPotentiallyUnsafeArchiveItem(_ item: ArchiveItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.openUnsafeArchiveItem.title", item.displayName)
        alert.informativeText = L10n.text("confirm.openUnsafeArchiveItem.message")
        alert.addButton(withTitle: L10n.text("button.open"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func allowPotentiallyUnsafeArchiveItemOpen(_ item: ArchiveItem) -> Bool {
        switch AppPreferences.activeContentOpenPolicy {
        case .allow:
            return true
        case .deny:
            errorMessage = L10n.text("error.blockedBySecurityPolicy")
            status = L10n.text("status.failed")
            return false
        case .ask:
            return confirmOpeningPotentiallyUnsafeArchiveItem(item)
        }
    }

    /// 安全检查：列出条目（可能需要密码）+ 用 ArchiveSafety 判定。
    ///
    /// 接收 password 是为了让 header-encrypted 7z 这类「不给密码连 list 都失败」的档案
    /// 能用调用方手上已有的密码（用户输入 / 预设密码 / 上次成功的密码）跑 list。
    /// 调用方负责把这个函数放在密码 retry 循环内 —— 列表失败时会抛出可被
    /// `shouldPromptForArchivePassword` 识别的错误，由 retry 循环统一处理。
    private func confirmArchiveExtractionSafety(
        archiveURL: URL,
        password: String = "",
        force: Bool? = nil
    ) async throws {
        let force = force ?? isForced(archiveURL)
        let items = try await ArchiveService.list(archiveURL, password: password, force: force)
        try confirmArchiveExtractionSafety(entries: items)
    }

    private func confirmArchiveExtractionSafety(entries: [ArchiveItem]) throws {
        let unsafeNames = ArchiveSafety.unsafeEntryNames(in: entries)
        guard !unsafeNames.isEmpty else { return }

        switch AppPreferences.suspiciousPathPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveEntries.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveEntries.message", Array(unsafeNames.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
    }

    private func confirmExtractedArchiveLinks(at directory: URL) throws {
        let unsafeLinks = try ArchiveSafety.unsafeLinks(in: directory, fileManager: fileManager)
        guard !unsafeLinks.isEmpty else { return }

        switch AppPreferences.symbolicLinkPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveLinks.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveLinks.message", Array(unsafeLinks.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
    }

    func openSelectedItem() {
        switch mode {
        case .folder:
            if let item = selectedFileItems.first {
                open(item)
            }
        case .tag:
            if let item = selectedFileItems.first {
                open(item)
            }
        case .archive:
            if let item = selectedArchiveItems.first {
                open(item)
            }
        }
    }

    func openDroppedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }

        if urls.count == 1 {
            openDroppedURL(first)
            return
        }

        let archiveURL = urls.first(where: { ArchiveService.isSupportedArchive($0) })
        if let archiveURL {
            openArchive(archiveURL)
        } else {
            openFolder(first.deletingLastPathComponent())
        }
    }

    private func openDroppedURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            openFolder(url)
        } else if ArchiveService.isSupportedArchive(url) {
            openArchive(url)
        } else {
            openFolder(url.deletingLastPathComponent())
        }
    }

    func goUp() {
        switch mode {
        case .folder(let url):
            openFolder(url.deletingLastPathComponent())
        case .tag:
            openHome()
        case .archive(let url):
            if session.archivePath.isEmpty {
                // `.siz` 容器打开时 url 是 /tmp 路径，上一级要回到原始 `.siz` 所在目录（archiveDisplayOverride 的父）。
                let parentURL = (archiveDisplayOverride ?? url).deletingLastPathComponent()
                openFolder(parentURL)
            } else {
                recordCurrentLocationForNavigation()
                session.setArchivePath(session.parentPath(of: session.archivePath))
                selectedArchiveRows.removeAll()
                refreshArchiveItems()
            }
        }
    }

    func goBack() {
        guard let destination = navigationBackStack.popLast() else { return }
        if let current = currentNavigationLocation {
            navigationForwardStack.append(current)
        }
        restoreNavigationLocation(destination)
    }

    func goForward() {
        guard let destination = navigationForwardStack.popLast() else { return }
        if let current = currentNavigationLocation {
            navigationBackStack.append(current)
        }
        restoreNavigationLocation(destination)
    }

    /// 重读 macOS Finder 的「个人收藏」侧栏，同步到 `finderFavorites`。
    /// 调用方：Sidebar 在 `onAppear` + `NSApplication.didBecomeActiveNotification` 时触发。
    /// 走带缓存版本 —— sfl4 因为 TCC / 文件被锁 / 临时 I/O 失败返回空时，
    /// 仍然显示最近一次成功读到的列表，避免 UI 在 Finder 收藏和硬编码 5 项之间反复横跳。
    func refreshFinderFavorites() {
        finderFavorites = FinderFavoritesReader.readWithCache()
    }

    func reload() {
        loadTask?.cancel()
        selection.removeAll()
        selectedArchiveRows.removeAll()
        errorMessage = nil
        let loadGeneration = nextLoadGeneration()

        switch mode {
        case .folder(let url):
            loadTask = nil
            loadFolder(url)
        case .tag(let tag):
            loadTask = Task { [weak self] in
                await self?.loadTaggedFiles(tag, generation: loadGeneration)
            }
        case .archive(let url):
            loadTask = Task { [weak self] in
                await self?.loadArchive(url, generation: loadGeneration)
            }
        }
    }

    func createArchive() {
        guard case .folder(let currentFolder) = mode else {
            errorMessage = L10n.text("error.openFolderFirst")
            return
        }

        let items = selectedFileItems
        guard !items.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let destination = currentFolder.appendingPathComponent(defaultArchiveName(for: items.map(\.url)))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: items.map(\.url), directoryURL: currentFolder, destinationURL: destination)
    }

    func createArchive(fromFinderURLs urls: [URL]) {
        let fileURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !fileURLs.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let parentDirectory = fileURLs[0].deletingLastPathComponent()
        let destination = parentDirectory.appendingPathComponent(defaultArchiveName(for: fileURLs))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: fileURLs, directoryURL: parentDirectory, destinationURL: destination)
    }

    func performCreateArchive(_ request: ArchiveCreationRequest) {
        // 勾选 GPG 签名 → 实际输出会被改名成 `<name>.siz` —— title 也跟着用最终文件名，
        // 避免长任务面板显示「正在创建 1.zip」但实际产物是 1.siz 的违和。
        let finalDestination = request.options.gpgSign
            ? request.destinationURL.deletingPathExtension().appendingPathExtension(SIZArchive.extensionName)
            : request.destinationURL
        let title = L10n.format("status.creating", finalDestination.lastPathComponent)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.options.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(containing: finalDestination)
            }
        ) { operationID, progress, outputObserver in
            // 不带 GPG 签名 → 跟原来一样直接 createArchive 写到用户指定的 destinationURL。
            guard request.options.gpgSign else {
                try await ArchiveService.createArchive(
                    from: request.sourceURLs,
                    destination: request.destinationURL,
                    options: request.options,
                    operationID: operationID,
                    progress: progress,
                    outputObserver: outputObserver
                )
                return
            }

            // 带签名 → 三步走：
            // 1. 把内层压缩包做到临时 staging（用 inner format 的扩展名，比如 archive.zip）；
            // 2. 用 GPG 跑 detached signature；
            // 3. tar 打成 .siz 容器写到自动改名后的 destinationURL（强制 `.siz` 后缀）。
            //
            // 自动改后缀：用户在创建对话框里选的 destinationURL 可能是 `xxx.zip`；勾选「GPG 签名」
            // 后实际输出是 .siz 容器，所以这里把扩展名重写成 `siz`。
            try SIZArchive.validateCreationOptionsForSignedContainer(request.options)
            let sizDestination = request.destinationURL
                .deletingPathExtension()
                .appendingPathExtension(SIZArchive.extensionName)

            let fileManager = FileManager.default
            let staging = fileManager.temporaryDirectory
                .appendingPathComponent("SimpleZip-Sign-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            let innerExtension = request.options.format.pathExtension
            let plaintextInnerName = "archive.\(innerExtension)"
            let plaintextInnerURL = staging.appendingPathComponent(plaintextInnerName)

            // Step 1：跑原本的 createArchive，目标改成 staging 里的 inner archive。
            var innerOptions = request.options
            innerOptions.gpgSign = false
            innerOptions.gpgSigningKeyFingerprint = ""
            innerOptions.gpgRecipientFingerprints = []
            try await ArchiveService.createArchive(
                from: request.sourceURLs,
                destination: plaintextInnerURL,
                options: innerOptions,
                operationID: operationID,
                progress: progress,
                outputObserver: outputObserver
            )

            // Step 2：（可选）多收件人加密 + / 或对称密码。SimpleZip v3 行为：
            // - 收件人 + 密码都空 → innerURL 仍是明文 archive，innerName 是 archive.<ext>（v2 兼容）；
            // - 任一非空 → 跑 gpg --[encrypt -r ...] [--symmetric --passphrase-fd 0] → archive.<ext>.gpg；innerName 跟着改。
            // 加密产物覆盖到 staging 后，明文 archive 立即删除（不留在临时目录里给攻击者捡）。
            let recipients = Array(Set(request.options.gpgRecipientFingerprints)).filter { !$0.isEmpty }
            let symmetricPassphrase = request.options.gpgSymmetricPassphrase.isEmpty
                ? nil
                : request.options.gpgSymmetricPassphrase
            let willEncrypt = !recipients.isEmpty || symmetricPassphrase != nil
            let innerURL: URL
            let innerName: String
            let encryptionInfo: SIZArchive.EncryptionInfo?
            if !willEncrypt {
                innerURL = plaintextInnerURL
                innerName = plaintextInnerName
                encryptionInfo = nil
            } else {
                let encryptedName = plaintextInnerName + ".gpg"
                let encryptedURL = staging.appendingPathComponent(encryptedName)
                try await GPGBackend.encrypt(
                    fileURL: plaintextInnerURL,
                    recipients: recipients,
                    symmetricPassphrase: symmetricPassphrase,
                    outputURL: encryptedURL,
                    operationID: operationID
                )
                // 把明文从临时目录抹掉，最小化在磁盘上停留时间。
                try? FileManager.default.removeItem(at: plaintextInnerURL)
                // 把每个 recipient fingerprint 反查 keyring 拿 UID，metadata 里同时记 fp + UID 给 UI 显示。
                // listKeys 失败时 fall back 到「只有 fingerprint，没有 UID」的占位 RecipientInfo —— metadata 仍合法。
                let allKeys = recipients.isEmpty ? [] : ((try? await GPGBackend.listKeys()) ?? [])
                let recipientInfos: [SIZArchive.RecipientInfo] = recipients.map { fp in
                    let uid = allKeys.first(where: { $0.fingerprint == fp })?.userID ?? ""
                    return SIZArchive.RecipientInfo(fingerprint: fp, userID: uid)
                }
                innerURL = encryptedURL
                innerName = encryptedName
                encryptionInfo = SIZArchive.EncryptionInfo(
                    recipients: recipientInfos,
                    algorithm: "gpg",
                    hasSymmetricPassphrase: symmetricPassphrase != nil ? true : nil
                )
            }

            // Step 3：组装 metadata（含 inner SHA256；加密时 SHA 是**密文** SHA），签的是 metadata.json。
            // 选签名密钥的优先级：
            // 1) 用户在创建对话框 ask 模式里挑的密钥（options.gpgSigningKeyFingerprint，create sheet 默认 seed 到 prefs 默认值）
            // 2) AppPreferences.gpgDefaultSigningKeyFingerprint —— 给非对话框入口（Finder Sync 等）走默认
            // 3) nil → 让 backend listKeys 兜底挑 first hasSecretKey
            let keyFingerprint: String? = {
                if !request.options.gpgSigningKeyFingerprint.isEmpty {
                    return request.options.gpgSigningKeyFingerprint
                }
                let prefsDefault = AppPreferences.gpgDefaultSigningKeyFingerprint
                return prefsDefault.isEmpty ? nil : prefsDefault
            }()
            let signerKey: GPGBackend.GPGKey? = (try? await GPGBackend.listKeys())?.first(where: { key in
                if let keyFingerprint { return key.fingerprint == keyFingerprint }
                return key.hasSecretKey
            })
            let innerSHA256 = try SIZArchive.computeInnerArchiveSHA256(of: innerURL)
            let metadata = SIZArchive.Metadata(
                schema: SIZArchive.schemaIdentifier,
                version: SIZArchive.schemaVersion,
                innerArchiveName: innerName,
                innerFormat: innerExtension,
                originalArchiveName: request.destinationURL.deletingPathExtension().lastPathComponent + ".\(innerExtension)",
                innerArchiveSHA256: innerSHA256,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                createdBy: "SimpleZip \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
                signature: SIZArchive.SignatureInfo(
                    signerFingerprint: signerKey?.fingerprint ?? "",
                    signerUserID: signerKey?.userID ?? "",
                    armorFormat: true
                ),
                encryption: encryptionInfo
            )

            // Step 4：把 metadata 落到 staging（用同一个确定性 encoder 让 wrap 和签名字节一致），
            // 然后 gpg detached sign。gpg-agent + pinentry-mac 弹密码框，我们不碰 passphrase。
            let metadataForSigning = staging.appendingPathComponent(SIZArchive.metadataFileName)
            try SIZArchive.encodeMetadata(metadata).write(to: metadataForSigning, options: .atomic)
            let signatureURL = try await GPGBackend.sign(
                archiveURL: metadataForSigning,
                signingKeyFingerprint: keyFingerprint,
                operationID: operationID
            )

            // Step 5：tar wrap 成 .siz。wrap 内部会再次 encode 同一个 metadata，字节跟我们刚签的一致。
            try await SIZArchive.wrap(
                innerArchive: innerURL,
                signatureFile: signatureURL,
                metadata: metadata,
                outputURL: sizDestination
            )
        }
    }

    func extractFromCurrentContext() {
        if case .archive = mode, !selectedArchiveItems.isEmpty {
            extractSelectedArchiveItems()
        } else {
            extractArchive()
        }
    }

    func extractArchive() {
        // 文件浏览器里选中 `.siz` + 点 Extract —— `.siz` 不在 `supportedExtensions` 里（ArchiveService
        // 不直接处理 tar 壳），所以特判走 @Published 状态给 ContentView 跑「unwrap + 验签 + 标准解压对话框」。
        if case .folder = mode,
           let sizURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SIZArchive.extensionName })?.url {
            pendingSIZExtract = sizURL
            return
        }

        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        // 预设密码开启时 request 的初始密码就填好；ExtractOptionsForm 那一头会同时把
        // 「使用预设密码」复选框默认勾上 —— 用户不需要在偏好和对话框两处再点一遍。
        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractArchiveRequest = ExtractArchiveRequest(
            archiveURL: archiveURL,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    /// 解压默认目标路径 —— 普通 archive 用自身父目录；`.siz` 打开内层时 archiveURL 是 /tmp 路径，
    /// 这时回退到 `archiveDisplayOverride`（=原始 .siz 文件路径）的父目录，
    /// 用户期望的「桌面 / 下载」目录，而不是 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-xxx/`。
    private func defaultExtractDestination(for archiveURL: URL) -> URL {
        if let displayed = archiveDisplayOverride {
            return displayed.deletingLastPathComponent()
        }
        return archiveURL.deletingLastPathComponent()
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        let title = L10n.format("status.extracting", request.archiveURL.lastPathComponent)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            // `.siz` v3 加密前置：如果是加密的内层 archive（`.gpg` 后缀 + sizSignature 带 encryption），
            // 先用 gpg --decrypt 出明文 sibling 文件，再走原本的 ArchiveService.extract 路径。
            // 用 defer 把解密产物在任务结束时抹掉，避免明文长期留在 /tmp。
            let archiveURLForExtract: URL
            let decryptedSiblingToCleanup: URL?
            if request.sizSignature?.encryption != nil,
               request.archiveURL.lastPathComponent.hasSuffix(".gpg") {
                do {
                    archiveURLForExtract = try await SIZArchive.decryptInnerArchive(
                        encryptedURL: request.archiveURL,
                        decryptionKeyFingerprint: request.gpgDecryptionKeyFingerprint.isEmpty ? nil : request.gpgDecryptionKeyFingerprint,
                        passphrase: request.gpgDecryptionPassphrase.isEmpty ? nil : request.gpgDecryptionPassphrase,
                        operationID: operationID
                    )
                    decryptedSiblingToCleanup = archiveURLForExtract
                } catch {
                    throw ArchiveError.commandFailed(L10n.format("error.siz.decryptionFailed", error.localizedDescription))
                }
            } else {
                archiveURLForExtract = request.archiveURL
                decryptedSiblingToCleanup = nil
            }
            defer {
                if let toCleanup = decryptedSiblingToCleanup {
                    try? self.fileManager.removeItem(at: toCleanup)
                }
            }

            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            // 安全检查只跑一次 —— 第一次 list 成功后置 true，后续 retry 不重复跑 NSAlert。
            // 旧版本把这步放在循环外，对 header-encrypted 7z 用空密码 list 直接失败，
            // 用户根本进不到下面的密码 prompt。
            var didCheckSafety = false
            while true {
                do {
                    if !didCheckSafety {
                        try await self.confirmArchiveExtractionSafety(
                            archiveURL: archiveURLForExtract,
                            password: password,
                            force: force
                        )
                        didCheckSafety = true
                    }
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        archiveURLForExtract,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: archiveURLForExtract,
                        displayName: request.archiveURL.lastPathComponent,
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { [weak self] status in
                self?.status = status
            } updateProgress: { [weak self] progress in
                self?.operationProgress = progress
            }
        }
    }

    func extractSelectedArchiveItems() {
        guard case .archive(let archiveURL) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let entries = expandedSelectedArchiveItems()
        guard !entries.isEmpty else {
            errorMessage = L10n.text("error.selectArchiveItemsToExtract")
            return
        }

        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractSelectionRequest = ExtractSelectionRequest(
            archiveURL: archiveURL,
            entries: entries,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        let title = L10n.format("status.extractingSelected", request.entries.count)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            try self.confirmArchiveExtractionSafety(entries: request.entries)
            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            while true {
                do {
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        request.archiveURL,
                        entries: request.entries,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        pathMode: request.pathMode,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: request.archiveURL,
                        displayName: L10n.format("status.extractingSelected", request.entries.count),
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { [weak self] status in
                self?.status = status
            } updateProgress: { [weak self] progress in
                self?.operationProgress = progress
            }
        }
    }

    func testArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let force = isForced(archiveURL)
        startManagedArchiveTask(
            title: L10n.format("status.testing", archiveURL.lastPathComponent),
            showsDetails: false,
            successStatus: L10n.text("status.archiveTested")
        ) { operationID, _, _ in
            try await ArchiveService.test(archiveURL, operationID: operationID, force: force)
        }
    }

    func showSevenZipBenchmarkOptions() {
        benchmarkRequest = SevenZipBenchmarkRequest()
    }

    func runSevenZipBenchmark(_ request: SevenZipBenchmarkRequest) {
        let session = SevenZipBenchmarkSession(options: request.options)
        benchmarkSession = session
        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(
                L10n.text("status.benchmarking"),
                initialProgress: ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.benchmarking"))
            ) { _ in
                let report = try await ArchiveService.benchmark(options: request.options, operationID: operationID) { report, output in
                    Task { @MainActor [weak session] in
                        session?.report = report
                        session?.rawOutput = output
                    }
                }
                await MainActor.run {
                    session.report = report
                    session.rawOutput = report.output
                }
            }
            session.finishedAt = Date()
            if didSucceed, session.report != nil {
                status = L10n.text("status.benchmarkReady")
            }
        }
    }

    func calculateHash() {
        calculateHash(algorithms: HashAlgorithm.allCases)
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

    func calculateHash(algorithms: [HashAlgorithm]) {
        let urls: [URL]
        switch mode {
        case .folder, .tag:
            urls = selectedFileItems.map(\.url)
        case .archive(let url):
            urls = [url]
        }

        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.selectFilesForHash")
            return
        }

        calculateHash(for: urls, algorithms: algorithms)
    }

    func calculateHash(forFinderURLs urls: [URL]) {
        calculateHash(for: urls, algorithms: HashAlgorithm.allCases)
    }

    private func calculateHash(for urls: [URL], algorithms: [HashAlgorithm]) {
        let fileURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !fileURLs.isEmpty else {
            errorMessage = L10n.text("error.selectFilesForHash")
            return
        }

        startOperationTask { [weak self] in
            guard let self else { return }
            isWorking = true
            errorMessage = nil
            status = L10n.text("status.hashing")
            defer { isWorking = false }

            do {
                hashReport = try await HashService.calculate(for: fileURLs, includeHiddenFiles: AppPreferences.showHiddenFiles, algorithms: algorithms)
                status = L10n.text("status.hashReady")
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
        }
    }

    func revealInFinder() {
        switch mode {
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting(selectedFileItems.map(\.url).isEmpty ? [url] : selectedFileItems.map(\.url))
        case .tag:
            NSWorkspace.shared.activateFileViewerSelecting(selectedFileItems.map(\.url))
        case .archive(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 不论当前 selection 是什么，都把「当前所在文件夹 / 标签 / 压缩包文件」自身在 Finder 里露出来。
    /// 给空白处右键菜单用 —— 那里点 `revealInFinder()` 会优先 reveal 残留的旧 selection，
    /// 跟用户的意图（"打开我现在看的这个文件夹"）对不上。
    func revealCurrentLocationInFinder() {
        switch mode {
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .tag:
            // tag 没有实体路径可定位，回落到 home 目录。
            NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser])
        case .archive(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copySelectedFiles() {
        guard case .folder = mode else { return }
        fileClipboard = (selectedFileItems.map(\.url), false)
    }

    func cutSelectedFiles() {
        guard case .folder = mode else { return }
        fileClipboard = (selectedFileItems.map(\.url), true)
    }

    func pasteFiles() {
        guard case .folder(let folderURL) = mode, let fileClipboard, !fileClipboard.urls.isEmpty else { return }

        startOperationTask { [weak self] in
            guard let self else { return }
            isWorking = true
            status = L10n.text("status.pasting")
            operationProgress = ArchiveProgressState(fraction: 0, currentFile: nil, completedUnitCount: 0, totalUnitCount: fileClipboard.urls.count)
            defer {
                isWorking = false
                operationProgress = ArchiveProgressState()
            }

            do {
                let total = max(1, fileClipboard.urls.count)
                let conflictSession = extractionCoordinator.makeConflictResolutionSession()
                for (index, url) in fileClipboard.urls.enumerated() {
                    operationProgress = ArchiveProgressState(
                        fraction: Double(index) / Double(total),
                        currentFile: url.lastPathComponent,
                        completedUnitCount: index + 1,
                        totalUnitCount: total
                    )
                    let requestedTargetURL = folderURL.appendingPathComponent(url.lastPathComponent)
                    let targetURL = try await extractionCoordinator.resolveDestination(
                        for: url,
                        requestedTargetURL: requestedTargetURL,
                        defaultOverwriteBehavior: AppPreferences.overwriteBehavior,
                        updateStatus: { [weak self] status in self?.status = status },
                        updateProgress: { [weak self] progress in self?.operationProgress = progress },
                        conflictSession: conflictSession
                    )
                    guard let targetURL else { continue }

                    if fileClipboard.shouldMove {
                        try fileManager.moveItem(at: url, to: targetURL)
                    } else {
                        try fileManager.copyItem(at: url, to: targetURL)
                    }
                    extractionCoordinator.showPendingHashOverwriteResult(for: targetURL)
                }
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                if fileClipboard.shouldMove {
                    self.fileClipboard = nil
                }
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: total, totalUnitCount: total)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
        }
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        operationRunner.cancel()
    }

    func deleteSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        if AppPreferences.confirmBeforeDeletingFiles {
            guard confirmDelete(items: selectedFileItems) else { return }
        }

        do {
            for item in selectedFileItems {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    func sortFileItems(by key: String, ascending: Bool) {
        fileItems.sort { lhs, rhs in
            compareFileItem(lhs, rhs, by: key, ascending: ascending)
        }
    }

    func sortArchiveItems(by key: String, ascending: Bool) {
        archiveItems.sort { lhs, rhs in
            compareArchiveItem(lhs, rhs, by: key, ascending: ascending)
        }
    }

    func moveSelectedFilesToFolder() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.text("file.moveTo")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        dropFileURLs(selectedFileItems.map(\.url), to: destinationFolder, shouldMove: true)
    }

    func dropFileURLs(_ urls: [URL], to destinationFolder: URL, shouldMove: Bool) {
        guard !urls.isEmpty else { return }
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            isWorking = true
            errorMessage = nil
            status = shouldMove ? L10n.text("status.movingFiles") : L10n.text("status.copyingFiles")
            operationProgress = ArchiveProgressState(fraction: 0, currentFile: nil, completedUnitCount: 0, totalUnitCount: urls.count)
            defer {
                isWorking = false
                operationProgress = ArchiveProgressState()
            }

            do {
                let total = max(1, urls.count)
                let conflictSession = extractionCoordinator.makeConflictResolutionSession()
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    operationProgress = ArchiveProgressState(
                        fraction: Double(index) / Double(total),
                        currentFile: url.lastPathComponent,
                        completedUnitCount: index + 1,
                        totalUnitCount: total
                    )
                    if shouldMove && url.deletingLastPathComponent().standardizedFileURL == destinationFolder.standardizedFileURL {
                        continue
                    }
                    let requestedTargetURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
                    let targetURL = try await extractionCoordinator.resolveDestination(
                        for: url,
                        requestedTargetURL: requestedTargetURL,
                        defaultOverwriteBehavior: AppPreferences.overwriteBehavior,
                        updateStatus: { [weak self] status in self?.status = status },
                        updateProgress: { [weak self] progress in self?.operationProgress = progress },
                        conflictSession: conflictSession
                    )
                    guard let targetURL else { continue }
                    if shouldMove {
                        try fileManager.moveItem(at: url, to: targetURL)
                    } else {
                        try fileManager.copyItem(at: url, to: targetURL)
                    }
                    extractionCoordinator.showPendingHashOverwriteResult(for: targetURL)
                }
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: total, totalUnitCount: total)
                status = L10n.text("status.done")
                if case .folder(let currentFolder) = mode {
                    let standardizedCurrentFolder = currentFolder.standardizedFileURL
                    let shouldRefreshCurrentFolder = standardizedCurrentFolder == destinationFolder.standardizedFileURL
                        || urls.contains { $0.deletingLastPathComponent().standardizedFileURL == standardizedCurrentFolder }
                    if shouldRefreshCurrentFolder {
                        reload()
                    }
                }
            } catch is CancellationError {
                errorMessage = nil
                status = L10n.text("status.cancelled")
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
        }
    }

    /// 加载本地文件夹内容，并按“文件夹优先、名称自然排序”展示。
    private func loadFolder(_ url: URL) {
        do {
            let urls = try fileBrowser.contents(
                of: url,
                showHiddenFiles: AppPreferences.showHiddenFiles,
                followFinderStructure: AppPreferences.followFinderStructure,
                resourceKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .contentAccessDateKey,
                    .addedToDirectoryDateKey,
                    .localizedTypeDescriptionKey,
                    .isHiddenKey
                ]
            )

            fileItems = fileBrowser.makeFileItems(
                from: urls,
                showSymbolicLinks: AppPreferences.showSymbolicLinks,
                hiddenSuffixes: AppPreferences.hiddenDisplaySuffixes,
                folderFirst: true
            )

            archiveItems = []
            session.clearArchive()
            status = L10n.format("status.itemCount", fileItems.count)
        } catch {
            fileItems = []
            archiveItems = []
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotOpenFolder")
        }
    }

    /// 使用 Spotlight 查询 Finder tag。结果仍显示成普通文件行，方便继续打开、哈希或创建压缩包。
    private func loadTaggedFiles(_ tag: String, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.format("status.searchingTag", tag))
        defer { endAsyncLoad(generation: generation) }

        do {
            let urls = try await fileBrowser.taggedFileURLs(named: tag)
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = fileBrowser.makeFileItems(
                from: urls,
                showSymbolicLinks: AppPreferences.showSymbolicLinks,
                hiddenSuffixes: AppPreferences.hiddenDisplaySuffixes,
                folderFirst: false
            )
            archiveItems = []
            session.clearArchive()
            status = L10n.format("status.tagItemCount", fileItems.count)
        } catch {
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = []
            archiveItems = []
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    /// 加载压缩包内项目。具体解析交给 ArchiveService，这里只更新 UI 状态。
    ///
    /// header-encrypted 7z 不给密码连列表都拿不到 —— 这种情况下如果用户配了预设密码，
    /// 优先用预设静默重试一次（不弹密码框）；预设也失败再走原本的错误提示。
    /// 非加密 / ZIP 的常规情况第一次 list 就成功，下面的 catch 分支根本不会进。
    private func loadArchive(_ url: URL, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.text("status.readingArchive"))
        defer { endAsyncLoad(generation: generation) }

        let force = isForced(url)
        do {
            let items: [ArchiveItem]
            do {
                items = try await ArchiveService.list(url, force: force)
            } catch {
                guard
                    AppPreferences.hasUsablePresetPassword,
                    shouldPromptForArchivePassword(error)
                else {
                    throw error
                }
                items = try await ArchiveService.list(url, password: AppPreferences.presetPassword, force: force)
            }
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            session.setItems(items)
            fileItems = []
            refreshArchiveItems()
        } catch {
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotReadArchive")
        }
    }

    private func defaultArchiveName(for urls: [URL]) -> String {
        if urls.count == 1 {
            return urls[0].deletingPathExtension().lastPathComponent + ".zip"
        }
        return "Archive.zip"
    }

    /// 选中压缩包内目录时，展开成目录下所有项目，避免后端只收到目录占位项。
    private func expandedSelectedArchiveItems() -> [ArchiveItem] {
        session.expand(selectedArchiveItems)
    }

    private func expandedArchiveItems(for item: ArchiveItem) -> [ArchiveItem] {
        session.expand(item)
    }

    /// 根据压缩包内当前路径生成“这一层”的列表，并自动补齐缺失的目录节点。
    private func refreshArchiveItems() {
        let currentItems = session.currentChildren()
        archiveItems = currentItems
        status = L10n.format("status.archivedItemCount", currentItems.count)
    }

    private func isOpenableArchiveDirectoryPackage(_ item: ArchiveItem) -> Bool {
        guard item.isDirectory else { return false }
        let ext = URL(fileURLWithPath: item.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .applicationBundle)
    }

    private func makeArchiveItemOpenDirectory() throws -> URL {
        try TemporaryResourceManager.makeOpenedArchiveItemDirectory(fileManager: fileManager)
    }

    private func extractedURL(for item: ArchiveItem, in destination: URL) throws -> URL {
        let relativePath = item.isDirectory
            ? ArchiveSession.normalizedDirectoryPrefix(item.name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : ArchiveSession.normalizedEntryName(item.name, isDirectory: false)
        let expectedURL = destination.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }

        if let fallbackURL = firstExtractedURL(named: item.displayName, in: destination) {
            return fallbackURL
        }
        throw ArchiveError.extractedItemNotFound
    }

    private func firstExtractedURL(named fileName: String, in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }

    private func nextLoadGeneration() -> Int {
        activeLoadGeneration += 1
        return activeLoadGeneration
    }

    private func beginAsyncLoad(generation: Int, statusText: String) {
        guard generation == activeLoadGeneration else { return }
        isWorking = true
        status = statusText
    }

    private func endAsyncLoad(generation: Int) {
        guard generation == activeLoadGeneration else { return }
        isWorking = false
        loadTask = nil
    }

    private func isCurrentLoad(_ generation: Int, mode expectedMode: BrowserMode) -> Bool {
        guard generation == activeLoadGeneration, !Task.isCancelled else { return false }
        return mode == expectedMode
    }

    private func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        startOperationTask(cancellable: cancellable) { _ in
            await operation()
        }
    }

    private func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor (UUID) async -> Void) {
        operationRunner.start(
            cancellable: cancellable,
            onCancellableChange: { [weak self] value in self?.canCancelCurrentOperation = value },
            operation: operation
        )
    }

    private func confirmDelete(items: [FileItem]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.delete.title", items.count)
        alert.informativeText = L10n.text("confirm.delete.message")
        alert.addButton(withTitle: L10n.text("file.moveToTrash"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func shouldPromptForArchivePassword(_ error: Error) -> Bool {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .passwordPromptExhausted:
                return true
            case .commandFailed(let output):
                return archiveCommandSuggestsPasswordRequirement(output)
            default:
                return false
            }
        }
        return archiveCommandSuggestsPasswordRequirement(error.localizedDescription)
    }

    private func archiveCommandSuggestsPasswordRequirement(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("enter password")
            || normalized.contains("wrong password")
            || normalized.contains("can not open encrypted archive")
            || normalized.contains("cannot open encrypted archive")
    }

    private func promptForArchiveItemPassword(
        item: ArchiveItem,
        archiveURL: URL,
        detectedZipEncryption: ZipEncryptionDetection,
        isRetry: Bool
    ) -> (password: String, zipDecryptionMethod: ArchiveDecryptionMethod)? {
        promptForArchivePassword(
            archiveURL: archiveURL,
            displayName: item.displayName,
            detectedZipEncryption: detectedZipEncryption,
            isRetry: isRetry,
            actionTitle: L10n.text("button.open")
        )
    }

    private func promptForArchivePassword(
        archiveURL: URL,
        displayName: String,
        detectedZipEncryption: ZipEncryptionDetection,
        isRetry: Bool,
        actionTitle: String
    ) -> (password: String, zipDecryptionMethod: ArchiveDecryptionMethod)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = archiveURL.lastPathComponent
        alert.informativeText = isRetry ? L10n.text("error.passwordPromptExhausted") : displayName
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: L10n.text("button.cancel"))

        let accessoryWidth: CGFloat = 320
        let accessoryHeight: CGFloat = archiveURL.pathExtension.lowercased() == "zip" ? 112 : 24
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))

        let passwordFieldY: CGFloat = archiveURL.pathExtension.lowercased() == "zip" ? 88 : 0
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: passwordFieldY, width: accessoryWidth, height: 24))
        passwordField.placeholderString = L10n.text("extract.password.placeholder")
        accessoryView.addSubview(passwordField)

        let decryptionMethods = Array(ArchiveDecryptionMethod.allCases)
        var methodPicker: NSPopUpButton?
        if archiveURL.pathExtension.lowercased() == "zip" {
            if detectedZipEncryption != .unknown {
                let detectionLabel = NSTextField(labelWithString: detectedZipEncryption.autoDetectionText)
                detectionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                detectionLabel.textColor = .secondaryLabelColor
                detectionLabel.frame = NSRect(x: 0, y: 56, width: accessoryWidth, height: 16)
                accessoryView.addSubview(detectionLabel)
            }

            let methodLabel = NSTextField(labelWithString: L10n.text("extract.decryptionMethod"))
            methodLabel.frame = NSRect(x: 0, y: 32, width: accessoryWidth, height: 16)
            accessoryView.addSubview(methodLabel)

            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 26), pullsDown: false)
            decryptionMethods.forEach { picker.addItem(withTitle: $0.title) }
            picker.selectItem(at: 0)
            accessoryView.addSubview(picker)
            methodPicker = picker
        }

        alert.accessoryView = accessoryView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 注意：点了 Extract 但密码框留空 ≠ 取消。
        // 比如用户给一个其实没加密的档案先填了密码 → 后续重试弹框 → 用户清掉再点 Extract，
        // 这是「我想不带密码再试一次」的明确表态，把空字符串照原样返回让外层 retry 一次。
        // 旧代码这里 guard !password.isEmpty else { return nil }，会被外层当 CancellationError 抛出 ——
        // 没加密的档案就被"静默"标成取消，文件根本没解出来。
        let selectedMethod: ArchiveDecryptionMethod
        if let methodPicker {
            let index = methodPicker.indexOfSelectedItem
            selectedMethod = decryptionMethods.indices.contains(index) ? decryptionMethods[index] : .automatic
        } else {
            selectedMethod = .automatic
        }
        return (password, selectedMethod)
    }

    private func lastExistingFolder(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return fileManager.homeDirectoryForCurrentUser
            }
            candidate = parent
        }
        return candidate
    }

    private func openArchiveLocationText(_ text: String, archiveURL: URL) {
        let archivePathPrefix = archiveURL.path + "/"
        let requestedArchivePath: String
        if text == archiveURL.path {
            requestedArchivePath = ""
        } else if text.hasPrefix(archivePathPrefix) {
            requestedArchivePath = String(text.dropFirst(archivePathPrefix.count))
        } else if FileManager.default.fileExists(atPath: text) {
            openFolder(lastExistingFolder(for: URL(fileURLWithPath: text)))
            return
        } else {
            requestedArchivePath = text
        }

        let destinationPath = session.lastExistingPath(for: requestedArchivePath)
        if currentNavigationLocation != .archive(archiveURL.standardizedFileURL, destinationPath) {
            recordCurrentLocationForNavigation()
        }
        session.setArchivePath(destinationPath)
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    private var currentArchiveURLForNavigation: URL {
        if case .archive(let url) = mode {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: "/")
    }

    private var currentNavigationLocation: NavigationLocation? {
        switch mode {
        case .folder(let url):
            return .folder(url.standardizedFileURL)
        case .archive(let url):
            return .archive(url.standardizedFileURL, session.archivePath)
        case .tag(let tag):
            return .tag(tag)
        }
    }

    private func recordCurrentLocationForNavigation() {
        guard let current = currentNavigationLocation else { return }
        if navigationBackStack.last != current {
            navigationBackStack.append(current)
            if navigationBackStack.count > 100 {
                navigationBackStack.removeFirst(navigationBackStack.count - 100)
            }
        }
        navigationForwardStack.removeAll()
    }

    private func restoreNavigationLocation(_ location: NavigationLocation) {
        switch location {
        case .folder(let url):
            openFolder(url, recordsHistory: false)
        case .archive(let url, let path):
            openArchive(url, recordsHistory: false)
            session.setArchivePath(path)
        case .tag(let tag):
            cleanupMountedDiskImageIfNeeded(for: nil)
            session.clearArchive()
            mode = .tag(tag)
            reload()
        }
    }

    private func refreshVisibleFolder(_ folderURL: URL) {
        guard case .folder(let currentFolder) = mode else { return }
        if currentFolder.standardizedFileURL == folderURL.standardizedFileURL {
            reload()
        }
    }

    private func refreshVisibleFolder(containing url: URL) {
        refreshVisibleFolder(url.deletingLastPathComponent())
    }

    private func compareFileItem(_ lhs: FileItem, _ rhs: FileItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "type":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "application":
            result = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        case "lastOpened":
            result = (lhs.lastOpened ?? .distantPast).compare(rhs.lastOpened ?? .distantPast)
        case "dateAdded":
            result = (lhs.dateAdded ?? .distantPast).compare(rhs.dateAdded ?? .distantPast)
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "created":
            result = (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func compareArchiveItem(_ lhs: ArchiveItem, _ rhs: ArchiveItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "kind":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "method":
            result = lhs.method.localizedStandardCompare(rhs.method)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func openDiskImage(_ url: URL) {
        cleanupMountedDiskImageIfNeeded(for: nil)
        status = L10n.text("status.readingArchive")
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let mountPoint = try await ArchiveService.mountDiskImage(url)
                mountedDiskImage = MountedDiskImageSession(sourceURL: url, mountPoint: mountPoint)
                session.clearArchive()
                mode = .folder(mountPoint)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
            isWorking = false
        }
    }

    private func cleanupMountedDiskImageIfNeeded(for targetURL: URL?) {
        guard let mountedDiskImage else { return }
        if let targetURL, targetURL.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
            return
        }
        let mountPoint = mountedDiskImage.mountPoint
        self.mountedDiskImage = nil
        Task.detached {
            try? await ArchiveService.detachDiskImage(at: mountPoint)
        }
    }

    private func prepareOperationDetailsSession(title: String, showsDetails: Bool) -> ArchiveOperationDetailsSession? {
        guard showsDetails else {
            operationDetailsSession = nil
            isShowingOperationDetails = false
            return nil
        }
        let session = ArchiveOperationDetailsSession(title: title)
        operationDetailsSession = session
        isShowingOperationDetails = true
        return session
    }

    private func makeOperationOutputObserver(for session: ArchiveOperationDetailsSession?) -> (@Sendable (String) -> Void)? {
        guard let session else { return nil }
        return { chunk in
            Task { @MainActor [weak session] in
                session?.append(chunk)
            }
        }
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

    private func startManagedArchiveTask(
        title: String,
        showsDetails: Bool,
        cancellable: Bool = true,
        successStatus: String? = nil,
        refreshOnSuccess: (() -> Void)? = nil,
        operation: @escaping (UUID?, @escaping @Sendable (ArchiveProgressState) -> Void, (@Sendable (String) -> Void)?) async throws -> Void
    ) {
        let detailsSession = prepareOperationDetailsSession(title: title, showsDetails: showsDetails)
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: cancellable) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(title) { progress in
                try await operation(operationID, progress, outputObserver)
            }
            finishOperationDetailsSession(detailsSession)
            guard didSucceed else { return }
            if let successStatus {
                status = successStatus
            }
            refreshOnSuccess?()
        }
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    private func runArchiveTask(
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
            try await operation { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.operationProgress = progress
                    if let statusText = progress.statusText, !statusText.isEmpty {
                        self?.status = statusText
                    } else if let currentFile = progress.currentFile, !currentFile.isEmpty {
                        self?.status = currentFile
                    }
                }
            }
            status = L10n.text("status.done")
            return true
        } catch is CancellationError {
            errorMessage = nil
            status = L10n.text("status.cancelled")
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
