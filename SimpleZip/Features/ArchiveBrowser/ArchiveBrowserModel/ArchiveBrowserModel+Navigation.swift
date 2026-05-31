//
//  ArchiveBrowserModel+Navigation.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  跳转 / 打开 / 后退前进 / 地址栏 / Finder 收藏刷新 / 当前位置入栈出栈。
//

import AppKit
import Foundation

extension ArchiveBrowserModel {
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
        // 切换到文件夹模式 → 一般情况清掉 `.siz` 残留的「显示路径覆盖」，避免老覆盖泄漏到下次 archive 打开。
        // **例外**：`.szs` 虚拟目录模式正在生效时（manifestVirtualMode != nil）保留 archiveDisplayOverride，
        // 让地址栏继续显示 `.szs` 路径。退出虚拟模式由 `exitManifestVirtualMode()` 显式清；这里不能误清。
        if manifestVirtualMode == nil {
            archiveDisplayOverride = nil
        }
        openFolder(url, recordsHistory: true)
    }

    func openFolder(_ url: URL, recordsHistory: Bool) {
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
        // `.szs` 不是压缩包 —— 强行喂给 7-Zip 会得到「Cannot open the file as archive」错误。
        // 它是 GPG clearsigned JSON 清单，正确入口是验证 sheet → 「以虚拟目录浏览」。
        if url.pathExtension.lowercased() == SZSArchive.extensionName {
            pendingSZSExtractHint = url
            return
        }
        forcedArchiveURLs.insert(url.standardizedFileURL)
        openArchive(url)
    }

    /// 当前 URL 是否已被标记为「强制以压缩包打开」。
    /// 用 standardizedFileURL 比较 —— 同一文件可能以不同形式（resolve / 非 resolve）传入。
    func isForced(_ url: URL) -> Bool {
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

    func openArchive(_ url: URL, recordsHistory: Bool) {
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

    func openArchiveDirectory(_ item: ArchiveItem) {
        let destinationPath = ArchiveSession.normalizedDirectoryPrefix(item.name)
        if currentNavigationLocation != .archive(currentArchiveURLForNavigation, destinationPath) {
            recordCurrentLocationForNavigation()
        }
        session.setArchivePath(destinationPath)
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
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
            // **`.szs` 虚拟根**：从虚拟根（payloadRoot）按「上一级」语义上要去虚拟父 = `.szs` 文件所在目录。
            // 但 .szs 文件所在目录 == payloadRoot 自身（虚拟模式下 .szs 跟 payload root 在同一物理目录里）—— 所以
            // Up 不改 URL，只是「**退出虚拟模式留在当前真实目录**」，相当于「从 .szs 里出来到它的容器目录」。
            if let virtual = manifestVirtualMode,
               url.standardizedFileURL.path == virtual.payloadRoot.path {
                exitManifestVirtualMode()
                reload() // 不带 filter 重 list，并刷新地址栏（不再用 manifest 路径）。
                return
            }
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
            // 进 / 切文件夹时（重）挂监视；同路径 watch 是 no-op，所以 watcher 自己触发的 reload 不会重建 stream。
            folderWatcher?.watch(url)
            loadTask = nil
            loadFolder(url)
        case .tag(let tag):
            folderWatcher?.stop()
            loadTask = Task { [weak self] in
                await self?.loadTaggedFiles(tag, generation: loadGeneration)
            }
        case .archive(let url):
            folderWatcher?.stop()
            loadTask = Task { [weak self] in
                await self?.loadArchive(url, generation: loadGeneration)
            }
        }
    }

    /// FolderWatcher 回调：当前文件夹内容变了 → 去抖后重新列出。
    /// 去抖（120ms）把一次批量操作产生的多次 FSEvents 合并成一次刷新。
    /// **绑定触发时的目录**：捕获事件发生时所在的文件夹，120ms 后若用户已经切到别的目录就不刷
    /// —— 否则「A 触发事件、用户立刻切到 B、120ms 后却刷了 B」会造成莫名其妙的多余刷新 + 清掉 B 刚点的选区。
    func handleFolderContentsChanged() {
        guard case .folder(let changedFolder) = mode else { return }
        let expected = changedFolder.standardizedFileURL
        pendingWatcherReload?.cancel()
        pendingWatcherReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  case .folder(let current) = self.mode,
                  current.standardizedFileURL == expected else { return }
            self.reloadFromFolderWatcher(expectedFolder: expected)
        }
    }

    /// watcher 触发的刷新：只刷「事件所属的那个目录」，且**保留选区**。
    /// 跟手动 `reload()` 不同 —— 手动刷新清选区是预期；自动刷新若清掉用户刚点的选区 / 准备拖动的多选就是「手欠」。
    /// 按 URL 重映射选区：`reload` 会重建 `FileItem`、`id` 每次都变，单纯不清 selection 会留下永不匹配的旧 UUID。
    func reloadFromFolderWatcher(expectedFolder: URL) {
        guard case .folder(let current) = mode,
              current.standardizedFileURL == expectedFolder.standardizedFileURL else { return }
        // 必须在 loadFolder（重建 fileItems）之前取旧选区的 URL。
        let previousSelectedURLs = Set(selectedFileItems.map { $0.url.standardizedFileURL })
        loadFolder(current)
        guard !previousSelectedURLs.isEmpty else {
            selection = []
            return
        }
        selection = Set(fileItems.filter { previousSelectedURLs.contains($0.url.standardizedFileURL) }.map(\.id))
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

    func recordCurrentLocationForNavigation() {
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

    func refreshVisibleFolder(_ folderURL: URL) {
        guard case .folder(let currentFolder) = mode else { return }
        if currentFolder.standardizedFileURL == folderURL.standardizedFileURL {
            reload()
        }
    }

    func refreshVisibleFolder(containing url: URL) {
        refreshVisibleFolder(url.deletingLastPathComponent())
    }
}
