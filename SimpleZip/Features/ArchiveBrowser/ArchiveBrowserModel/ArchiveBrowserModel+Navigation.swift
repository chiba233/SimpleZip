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

    /// 0.4.5 #80:进入 AI 建议虚拟工作区(白皮书工程补充一)。与 `openTag` 同款收尾:清归档 / 停镜像 / 记历史,
    /// 然后切 `mode`。**不加载文件列表、不监视文件夹**(reload 的 `.aiWorkspace` 分支只停 watcher);候选由
    /// `AISuggestionFolderView` 从现有索引确定性派生,只读。
    func openAIWorkspace(_ kind: AISystemWorkspaceKind) {
        archiveDisplayOverride = nil
        recordCurrentLocationForNavigation()
        cleanupMountedDiskImageIfNeeded(for: nil)
        session.clearArchive()
        mode = .aiWorkspace(kind)
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
        case .folder, .tag, .aiWorkspace:
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
        // 进文件夹一定离开了「档案嵌套」语境 —— 清空虚拟堆叠串。
        nestedDisplayPath = nil
        // 真实导航(recordsHistory:true)= 退出档案浏览:清「上一级」返回栈 + 即时清掉本会话临时产物。
        // 历史导航(back/forward/restore,recordsHistory:false)**不 purge** —— 临时可能还要被 ← / → 回到,删了再前进会扑空。
        // 进虚拟目录(卷内)由 purge 内部 isUnderDisposableTemp 再跳过一层。
        if recordsHistory {
            nestedArchiveReturnStack.removeAll()
            purgeOpenedArchiveTempsIfLeaving(to: url)
        }
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

    /// 登记一个「随当前档案浏览会话而生」的临时目录 —— 离开档案（进真实文件夹 / 开别的真实档案）时即时清掉。
    /// 覆盖：开档案内文件 / 嵌套档案解出的临时（openArchiveItemExternally 已登记）、`.gpg` 解密根、`.siz` unwrap 根。
    func registerOpenedArchiveItemTemp(_ url: URL) {
        let std = url.standardizedFileURL
        if !openedArchiveItemDirectories.contains(where: { $0.standardizedFileURL == std }) {
            openedArchiveItemDirectories.append(url)
        }
    }

    /// 目标 URL 是否落在「可丢弃临时区」（系统临时目录下，含加密卷挂载点）。
    /// 进入这种路径 = 进虚拟目录 / 嵌套档案，**不算离开档案**，不触发清理（否则会删掉正要进入的内容）。
    ///
    /// **必须用 `resolvingSymlinksInPath()`，不能用 `standardizedFileURL`**：macOS 的 `/var` 是 `/private/var`
    /// 的符号链接。`FileManager.temporaryDirectory` 给的是 `/var/folders/.../T` 形式，而 0.2.7 的加密临时卷由
    /// `hdiutil attach -mountpoint <temp 下目录>` 挂载后，**报告的挂载点是 `/private/var/...` 实路径**
    /// （已用 spike 证实）。`standardizedFileURL` 不解析符号链接 → `/private/var/...` 不以 `/var/...` 为前缀 →
    /// 加密卷里的临时被误判为「非临时」→ 打开嵌套档案 / `.gpg`·`.siz` 解密产物时（它们走 `openArchive`/`openFolder`
    /// 到加密卷里的临时路径）触发清理，**把正要打开的内容当场删掉** —— 这是「zip 套 zip / .gpg→archive 全炸」的根因。
    /// `resolvingSymlinksInPath()` 把两边都归一到 `/private/...`，前缀比对才成立。
    private func isUnderDisposableTemp(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = fileManager.temporaryDirectory.resolvingSymlinksInPath().path
        if path == temp || path.hasPrefix(temp + "/") { return true }
        // 兜底：加密临时卷理论上挂在 temp 下，但显式认它的挂载点更稳（未来若 macOS 把加密 APFS 挂到 /Volumes 仍正确）。
        if let mount = SecureScratchVolume.shared.currentMountPoint?.resolvingSymlinksInPath().path,
           path == mount || path.hasPrefix(mount + "/") {
            return true
        }
        return false
    }

    /// **离开档案即时清理**：删掉本会话登记的全部临时产物（后台执行，不阻塞主线程）。
    /// 档案一旦关闭 / 退出到真实目录，它的临时生命就结束了 —— 不等到退出 app（整卷销毁）才清。
    private func purgeOpenedArchiveTemps() {
        guard !openedArchiveItemDirectories.isEmpty else { return }
        let dirs = openedArchiveItemDirectories
        openedArchiveItemDirectories.removeAll()
        Task.detached {
            for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// 进入「真实目标」（非临时区）前清掉上一个档案会话的临时；进入虚拟目录 / 嵌套档案则跳过。
    private func purgeOpenedArchiveTempsIfLeaving(to destination: URL) {
        if !isUnderDisposableTemp(destination) {
            purgeOpenedArchiveTemps()
        }
    }

    func openArchive(_ url: URL) {
        archiveDisplayOverride = nil
        openArchive(url, recordsHistory: true)
    }

    /// #72:打开归档并在加载完成后跳到 `revealEntryPath` 所在目录、选中并滚动到它(Spotlight 单文件结果点击)。
    /// 走侧信道 `PendingArchiveReveal`:openArchive 异步加载,loadArchive 收尾时按 url 取出待定路径执行 reveal。
    func openArchive(_ url: URL, revealEntryPath: String) {
        archiveDisplayOverride = nil
        PendingArchiveReveal.set(entryPath: revealEntryPath, for: url)
        openArchive(url, recordsHistory: true)
    }

    /// #72:跳到 archive 内某条目所在目录、选中并请求滚动到它。仅在 archive 模式下有效。
    func revealArchiveEntry(_ entryPath: String) {
        guard case .archive = mode else { return }
        let normalizedTarget = ArchiveSession.normalizedEntryName(entryPath, isDirectory: false)
        guard !normalizedTarget.isEmpty else { return }
        let parent = session.parentPath(of: entryPath)
        session.setArchivePath(session.lastExistingPath(for: parent))
        refreshArchiveItems()
        guard let target = archiveItems.first(where: {
            ArchiveSession.normalizedEntryName($0.name, isDirectory: $0.isDirectory) == normalizedTarget
        }) else { return }
        selectedArchiveRows = [target.id]
        // 表格 coordinator 下一拍(refreshArchiveItems 已驱动)消费这个 id 滚动到行。
        pendingRevealArchiveItemID = target.id
    }

    /// 打开「内层 archive」但对外用 `displayedAs` 的路径展示 —— 给 `.siz` 用。
    /// inner URL 真的在 /tmp，但用户看到的「源文件」是桌面 / 下载里的原始 `.siz`。
    func openArchive(_ url: URL, displayedAs displayURL: URL) {
        archiveDisplayOverride = displayURL
        openArchive(url, recordsHistory: true)
    }

    /// 在 app 内打开**嵌套档案**（档案里套档案：zip 套 zip、tgz 里的 tar、7z 套 tar…）。
    ///
    /// 嵌套层级是纯**虚拟目录显示** —— 地址栏把整条链堆叠出来让用户看懂自己在第几层
    /// （`…/xx.zip/xa/a.zip/b.zip/c.zip`），中间段不要求真的可点进 / 可访问：
    /// - `tempURL`：被双击的档案 entry 解出来的临时路径（真实 list 跑在这里）。
    /// - `entryName`：该 entry 在**父档案**里的完整内部路径（如 `xa/a.zip`）。
    /// - `archiveDisplayOverride` 指向**最外层真实档案** → 「上一级」从嵌套根直接退出整条虚拟链、回到真实文件夹。
    /// - **不记导航历史**（recordsHistory: false）：嵌套临时档案永不进后退栈，所以「后退」也不会蹦出 `/var/folders`。
    func openNestedArchive(_ tempURL: URL, entryName: String, recordsReturnLocation: Bool = true) {
        guard case .archive(let currentURL) = mode else { return }
        // 进嵌套档案 = 一次导航:把「进来时的父档案位置」(父档案 + 当前子目录,**真实可导航**)既压进**后退栈**
        //（← 像 Finder 一样回到父档案那个子目录），也压进**嵌套返回栈**（^ 上一级回到同一处）。
        // 压的是父位置、不是临时档案本身;临时档案走下面 recordsHistory:false 不会被 recordCurrentLocation 压进栈。
        // `recordsReturnLocation: false` = 压缩 tar 壳的**自动下钻**(tar.gz/tar.zst 直开内层 tar):
        // 壳层对用户不可见,不进任何栈 —— 「上一级」走空栈分支直接回真实文件夹,← 回打开壳之前的位置。
        if recordsReturnLocation {
            recordCurrentLocationForNavigation()
            if let parentLocation = currentNavigationLocation {
                nestedArchiveReturnStack.append(parentLocation)
            }
        }
        let parentBase = nestedDisplayPath ?? (archiveDisplayOverride ?? currentURL).path
        let cleanedEntry = entryName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let newPrefix = parentBase + "/" + cleanedEntry
        // 最外层真实档案：第一次嵌套（nestedDisplayPath 还没设）= 当前真实档案；已嵌套则沿用既有 override。
        let outerReal = nestedDisplayPath == nil ? currentURL : (archiveDisplayOverride ?? currentURL)

        archiveDisplayOverride = outerReal      // 先设：核心 openArchive 不碰 override，不会被清掉。
        openArchive(tempURL, recordsHistory: false)  // 核心会把 nestedDisplayPath 清空…
        nestedDisplayPath = newPrefix           // …随后设回这一层的堆叠串（@Published → 地址栏刷新）。
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
        // 任何「真实」档案打开都清空嵌套虚拟堆叠串（嵌套打开走 openNestedArchive，会在调用本方法之后再设回）。
        nestedDisplayPath = nil
        // 真实导航(recordsHistory:true)= 离开嵌套链:清「上一级」返回栈 + 清掉上一个档案会话的临时。
        // 历史导航(back/forward/restore,recordsHistory:false)**不 purge** —— 临时档案可能还要被 ← / → 回到,
        // 删了再前进就扑空(unzip 找不到文件);嵌套打开也走 false,不会误删正要进入的内层档案。
        if recordsHistory {
            nestedArchiveReturnStack.removeAll()
            purgeOpenedArchiveTempsIfLeaving(to: url)
        }
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
            pendingSIZOpen = SIZOpenRequest(url: item.url)
        } else if item.url.pathExtension.lowercased() == "szs" {
            // `.szs` 同理走专用 handle（peek manifest → 验签 sheet），在**当前**浏览器里处理。
            // 之前这里没有 .szs 分支 → 掉进 NSWorkspace.open → 系统按 UTI 把它当外部打开转回来 →
            // 走 handleRunningExternalOpen 永远开新标签（用户反馈「.szs 固定在新标签打开」的根因）。
            pendingSZSOpen = item.url
        } else if AppPreferences.gpgEnabled, !item.isDirectory, GPGFileService.isRecognizedGPGFile(item.url) {
            // `.gpg`/`.pgp`/`.asc`/`.key`：当带密码压缩包/钥匙串材料处理 —— openGPGFile 内部嗅探包头再路由
            // （加密数据→解密浏览、公钥/私钥→导入 sheet）。**仅 gpgEnabled==true 时启用**（A4）；
            // 关了 GPG 主开关就落到 NSWorkspace.open 走系统默认 app，不暴露任何 GPG 行为。
            // `!item.isDirectory`：`.key` 也是 Keynote 文稿（目录包）的扩展名，排除目录包不误送进 GPG。
            openGPGFile(item.url)
        } else if ArchiveService.isSupportedArchive(item.url) {
            openArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func canShowPackageContents(_ item: FileItem) -> Bool {
        // 读列目录时存好的字段,零 IO —— 表格每行的可展开判定 / 拖拽 validateDrop 每次鼠标移动都会调,
        // 以前现场 resolvingSymlinksInPath + LaunchServices,大目录下把 UI 拖死。
        item.isDirectory && item.isPackage
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
        case .aiWorkspace:
            break // AI 工作区的节点动作由 AISuggestionFolderView 自己处理(只读打开 / 定位),不走这里。
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
            // **虚拟根（`.szs` / `.gpg` 解密产物）的「上一级」**：退出虚拟模式，回到**原始容器文件所在的真实目录**
            // ——`archiveDisplayOverride` 是原始容器 URL（`.szs` 文件 / 原 `.gpg` 文件），它的父目录就是用户心智里的
            // 「容器所在文件夹」。
            // - `.szs`：payloadRoot == `.szs` 所在目录，`override.parent` == payloadRoot → 等于「留在原地、退出虚拟」。
            // - `.gpg`：解密产物在 /tmp，但 override 是桌面上的原 `.gpg` → 回到桌面，**绝不暴露 `/var/folders/...`**。
            //   （早期版本拿 /tmp 当 payloadRoot 又直接 reload，上一级就漏了临时路径 —— 正是没吃透 `.siz` 地址栏为何那样写。）
            if let virtual = manifestVirtualMode,
               url.standardizedFileURL.path == virtual.payloadRoot.path {
                let upURL = (archiveDisplayOverride ?? url).deletingLastPathComponent()
                exitManifestVirtualMode()
                openFolder(upURL)
                return
            }
            openFolder(url.deletingLastPathComponent())
        case .tag, .aiWorkspace:
            openHome()
        case .archive(let url):
            if session.archivePath.isEmpty {
                if let parentLocation = nestedArchiveReturnStack.popLast() {
                    // 在嵌套档案(zip 里的 `.siz` / 内层档案)根目录 → 回到进来时的父档案位置(父档案 + 子目录),
                    // 而不是退出整条链蹦到物理文件夹。up 等价于「回到父档案」——若后退栈顶正是进嵌套时压的同一父位置,
                    // 一并弹掉,免得 up 之后再按 ← 停在原地。
                    if navigationBackStack.last?.location == parentLocation {
                        navigationBackStack.removeLast()
                    }
                    restoreNavigationLocation(parentLocation)
                } else {
                    // 顶层 `.siz` 容器:url 是 /tmp 路径,上一级回到原始 `.siz` 所在目录(archiveDisplayOverride 的父)。
                    let parentURL = (archiveDisplayOverride ?? url).deletingLastPathComponent()
                    openFolder(parentURL)
                }
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
        if let current = currentNavigationSnapshot {
            navigationForwardStack.append(current)
        }
        restoreNavigationSnapshot(destination)
    }

    func goForward() {
        guard let destination = navigationForwardStack.popLast() else { return }
        if let current = currentNavigationSnapshot {
            navigationBackStack.append(current)
        }
        restoreNavigationSnapshot(destination)
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
            clearExpandedFolderRegistry()
            loadTask = Task { [weak self] in
                await self?.loadTaggedFiles(tag, generation: loadGeneration)
            }
        case .archive(let url):
            folderWatcher?.stop()
            clearExpandedFolderRegistry()
            loadTask = Task { [weak self] in
                await self?.loadArchive(url, generation: loadGeneration)
            }
        case .aiWorkspace:
            // AI 工作区不监视文件夹、不加载文件列表;候选由 AISuggestionFolderView 自己从现有索引确定性派生。
            // 这里只停掉文件夹监视(避免残留 FSEvents),**绝不在此触发 @Published 风暴**(A17)。
            folderWatcher?.stop()
            clearExpandedFolderRegistry()
        }
    }

    /// 离开文件夹模式（tag / archive）时清掉文件夹原位展开注册表 —— 这两种模式不经 loadFolder,
    /// 不清的话陈旧子级会一直挂在注册表里（虽然 selection 已清、构不成实害,但没必要留）。
    private func clearExpandedFolderRegistry() {
        expandedFolderOwnerPath = nil
        expandedFolderChildrenByPath = [:]
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
        // 用户正按着鼠标（框选 / 拖动中）→ 推迟自动刷新：reloadData 会在 live 橡皮筋底下重载、打断框选。
        // 重新排一次去抖，松手后再刷（外部 .DS_Store 之类的变动晚 100ms 刷新无所谓）。
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            handleFolderContentsChanged()
            return
        }
        // 必须在 loadFolder（重建 fileItems）之前取旧选区的 URL + 选区在旧列表里的「锚点位置」。
        // 锚点 = 旧 fileItems 里第一个被选中项的下标 —— 用于「选中项被刷没了」时落到原位置的相邻项。
        let previousSelectedURLs = Set(selectedFileItems.map { $0.url.standardizedFileURL })
        let anchorIndex = fileItems.firstIndex { previousSelectedURLs.contains($0.url.standardizedFileURL) }
        loadFolder(current)
        // 按 URL 重映射选区（loadFolder 内容没变时会跳过赋值，fileItems / id 不变 → 重映射结果与现状一致）。
        // 只在结果真的不同才赋值，避免无谓的 @Published 抖动。
        // 0.4.1 文件夹原位展开：展开子级也参与重映射 —— 上一版漏了这层,自动刷新一来子行选区直接蒸发
        // （revert 信里的「闪一下就没了」）。loadFolder 刚 refresh 过注册表,这里读到的已是新实例。
        let listedEverything = fileItems + expandedFolderChildrenByPath.values.flatMap { $0 }
        let remapped = previousSelectedURLs.isEmpty
            ? Set<UUID>()
            : Set(listedEverything.filter { previousSelectedURLs.contains($0.url.standardizedFileURL) }.map(\.id))
        if selection != remapped {
            selection = remapped
        }
        // 通用兜底：之前有选区、刷新后却全没了（删除 / 改名 / 移走 / 外部删除…任何让选中项消失的刷新），
        // 就把光标落到原位置的相邻文件并恢复键盘焦点，而不是丢焦点、回到列表顶端。
        // 删除 / 改名等已显式设了更精确的 pendingSelectionURL（上一项 / 改名后的文件）→ 这里不覆盖。
        if pendingSelectionURL == nil, !previousSelectedURLs.isEmpty, remapped.isEmpty, !fileItems.isEmpty,
           let anchorIndex {
            let neighborIndex = min(anchorIndex, fileItems.count - 1)
            pendingSelectionURL = fileItems[neighborIndex].url.standardizedFileURL
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
        case .aiWorkspace:
            break // AI 工作区是虚拟视图,没有可在 Finder 中定位的真实位置。
        }
    }

    /// 「显示简介」——对选中的真实文件调起 Finder 原生 Get Info 窗口（AppleScript 控 Finder）。
    /// 只需选中 URL，不依赖 NSOutlineView，所以右键菜单（FileTable 协调器）和菜单栏 File 菜单共用这一份实现。
    /// 首次会弹「SimpleZip 想要控制 Finder」自动化授权，拒绝则走 errorMessage 提示。
    func showGetInfoForSelection() {
        let urls = selectedFileItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            try FinderInfoService.openInfoWindows(for: urls)
        } catch {
            errorMessage = L10n.format("file.getInfo.failed", error.localizedDescription)
        }
    }

    /// 不论当前 selection 是什么，都把「当前所在文件夹 / 标签 / 压缩包文件」自身在 Finder 里露出来。
    /// 给空白处右键菜单用 —— 那里点 `revealInFinder()` 会优先 reveal 残留的旧 selection，
    /// 跟用户的意图（"打开我现在看的这个文件夹"）对不上。
    func revealCurrentLocationInFinder() {
        switch mode {
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .tag, .aiWorkspace:
            // tag / AI 工作区没有实体路径可定位，回落到 home 目录。
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
        guard let current = currentNavigationSnapshot else { return }
        if navigationBackStack.last?.location != current.location {
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

    /// 从历史快照恢复:先按真实位置打开,再把**嵌套档案的地址显示上下文**复原
    ///（`restoreNavigationLocation` 里的 `openArchive` 会先把这俩清空,所以必须在之后重设)。
    /// 这样 ← / → 回到嵌套档案时地址栏显示嵌套链、不露 `/var/folders`。
    private func restoreNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        restoreNavigationLocation(snapshot.location)
        archiveDisplayOverride = snapshot.archiveDisplayOverride
        nestedDisplayPath = snapshot.nestedDisplayPath
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

/// #72:跨「外部打开(Spotlight 单文件 intent)」→「归档异步加载完成」的侧信道 —— 记下某归档加载完要 reveal
/// 的条目路径。`AppDelegate.openExternalArchive(_:revealEntryPath:)` 设值,`loadArchive` 收尾按 url 取出执行。
/// 按规范化磁盘路径配对(与缓存同口径),只服务真实在盘的归档(Spotlight 单文件结果都指向缓存里的真实包)。
@MainActor
enum PendingArchiveReveal {
    private static var entryPathByArchivePath: [String: String] = [:]

    static func set(entryPath: String, for url: URL) {
        entryPathByArchivePath[key(for: url)] = entryPath
    }

    static func consume(for url: URL) -> String? {
        let k = key(for: url)
        defer { entryPathByArchivePath[k] = nil }
        return entryPathByArchivePath[k]
    }

    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
