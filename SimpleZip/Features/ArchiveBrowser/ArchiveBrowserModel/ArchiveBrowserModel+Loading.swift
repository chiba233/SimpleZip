//
//  ArchiveBrowserModel+Loading.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  本地文件夹 / Spotlight tag 搜索 / 压缩包列出 + 异步任务的 generation 跟踪。
//

import Combine
import Foundation

extension ArchiveBrowserModel {
    /// 两批 FileItem 是否代表「同一份目录列表」—— 按**稳定标识**（url + 目录标志 + 符号链接 + 隐藏 +
    /// 大小 + 修改时间 + 权限 + 属主）逐项比较，忽略每次重建都会变的 `id`(UUID)。顺序敏感（makeFileItems 排序是确定的）。
    /// 用于 loadFolder 判断「内容真的变了吗」，避免 watcher 无关刷新引发空闲闪烁。
    /// permissions/owner 也要比：chmod/chown 只改 mode/属主、不动 size/mtime,漏掉这俩会让「权限 / 属主」列在
    /// 改完后被判定「列表没变」而跳过发布,显示旧值。这两列默认关时值恒为空串,不会引入额外刷新。
    nonisolated static func fileItemsRepresentSameListing(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.url != b.url
                || a.isDirectory != b.isDirectory
                || a.isSymbolicLink != b.isSymbolicLink
                || a.isHidden != b.isHidden
                || a.size != b.size
                || a.modified != b.modified
                || a.permissions != b.permissions
                || a.owner != b.owner {
                return false
            }
        }
        return true
    }

    // MARK: - 0.4.1 文件夹原位展开（子级清单的真值在模型,见 expandedFolderChildrenByPath 注释）

    /// 列某个子目录的条目，**口径与 loadFolder 完全一致**（隐藏文件开关 / 符号链接 / macOS 隐藏标志 /
    /// `.szs` 虚拟模式过滤 / 文件夹在前），但不动任何 @Published 状态 —— 纯查询。
    /// 列不动（无权限 / 已删除）返回空数组：展开后看到空层级，跟 Finder 行为一致。
    func childFileItems(of url: URL) -> [FileItem] {
        guard let rawURLs = try? fileBrowser.contents(
            of: url,
            showHiddenFiles: AppPreferences.showHiddenFiles,
            followFinderStructure: false,
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
        ) else { return [] }

        let urls: [URL]
        if let virtual = manifestVirtualMode {
            urls = rawURLs.filter { candidate in
                let std = candidate.standardizedFileURL
                return virtual.allowedFiles.contains(std) || virtual.allowedDirs.contains(std)
            }
        } else {
            urls = rawURLs
        }

        return fileBrowser.makeFileItems(
            from: urls,
            showSymbolicLinks: AppPreferences.showSymbolicLinks,
            hiddenSuffixes: AppPreferences.hiddenDisplaySuffixes,
            includeMacOSHidden: AppPreferences.hiddenDetectionMode.includesMacOSHiddenFlag,
            folderFirst: true
        )
    }

    /// 数据源懒加载入口：取某已展开文件夹的子级；没列过就现列 + 登记进注册表。
    /// 登记是模型成为「子级真值持有者」的关键 —— selectedFileItems / 选区重映射都靠它。
    func expandedChildren(of url: URL) -> [FileItem] {
        let path = url.standardizedFileURL.path
        if let cached = expandedFolderChildrenByPath[path] { return cached }
        let children = childFileItems(of: url)
        expandedFolderChildrenByPath[path] = children
        return children
    }

    /// 文件夹折叠：把它（连同其下层所有展开的子孙）从注册表移除 —— 折叠后子级不再可见,不应再可被操作。
    func folderDidCollapse(_ url: URL) {
        let path = url.standardizedFileURL.path
        expandedFolderChildrenByPath.removeValue(forKey: path)
        let prefix = path + "/"
        for key in expandedFolderChildrenByPath.keys where key.hasPrefix(prefix) {
            expandedFolderChildrenByPath.removeValue(forKey: key)
        }
    }

    /// 同文件夹 reload（FSEvents / 手动刷新）后重新核对每个已展开文件夹的子级：
    /// 目录没了 → 出表；内容变了 → 换新清单并 objectWillChange.send() 驱动表格重建
    /// （顶层没变时 loadFolder 不发布,没有这一脚,展开层里的增删改永远刷不出来）；
    /// 内容没变 → 保留原实例（id 稳定,选区 / 内容指纹都不抖）。
    func refreshExpandedFolderChildren() {
        // 偏好关掉（设置→浏览→文件夹原位展开）：清空注册表 —— 行没了,残留子级不该再可被选中 / 操作,
        // 也省得之后每次 reload 都白列一遍子目录。
        guard AppPreferences.folderInlineExpansion else {
            if !expandedFolderChildrenByPath.isEmpty {
                expandedFolderChildrenByPath = [:]
                expandedChildrenGeneration += 1
                objectWillChange.send()
            }
            return
        }
        guard !expandedFolderChildrenByPath.isEmpty else { return }
        var changed = false
        for (path, oldItems) in expandedFolderChildrenByPath {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                folderDidCollapse(URL(fileURLWithPath: path))
                changed = true
                continue
            }
            let fresh = childFileItems(of: URL(fileURLWithPath: path))
            if !Self.fileItemsRepresentSameListing(fresh, oldItems) {
                expandedFolderChildrenByPath[path] = fresh
                changed = true
            }
        }
        if changed {
            expandedChildrenGeneration += 1
            objectWillChange.send()
        }
    }

    func loadFolder(_ url: URL) {
        // 文件夹原位展开的注册表跟着「当前浏览的文件夹」走：导航到别处 → 整表清空（展开状态不跨目录）；
        // 同文件夹 reload → 留着,listing 更新后由 refreshExpandedFolderChildren 逐项核对。
        let ownerPath = url.standardizedFileURL.path
        if expandedFolderOwnerPath != ownerPath {
            expandedFolderOwnerPath = ownerPath
            expandedFolderChildrenByPath = [:]
        }
        do {
            let rawURLs = try fileBrowser.contents(
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

            // `.szs` 虚拟目录模式：在 payloadRoot 下时，过滤掉**不在 manifest 里出现 + 不是签名文件祖先目录**的条目。
            // 走出 payloadRoot 后（用户「上一级」越过 root）filter 不再适用，自动退出虚拟模式 —— 视觉上回到正常 Finder。
            let urls: [URL]
            if let virtual = manifestVirtualMode {
                let stdCurrent = url.standardizedFileURL
                let stdRoot = virtual.payloadRoot
                if stdCurrent.path == stdRoot.path || stdCurrent.path.hasPrefix(stdRoot.path + "/") {
                    urls = rawURLs.filter { candidate in
                        let std = candidate.standardizedFileURL
                        return virtual.allowedFiles.contains(std) || virtual.allowedDirs.contains(std)
                    }
                } else {
                    // 走出 root —— 自动退出虚拟模式，回到原始 listing。
                    exitManifestVirtualMode()
                    urls = rawURLs
                }
            } else {
                urls = rawURLs
            }

            let newItems = fileBrowser.makeFileItems(
                from: urls,
                showSymbolicLinks: AppPreferences.showSymbolicLinks,
                hiddenSuffixes: AppPreferences.hiddenDisplaySuffixes,
                includeMacOSHidden: AppPreferences.hiddenDetectionMode.includesMacOSHiddenFlag,
                folderFirst: true
            )
            // 列表内容（按稳定标识 url + 目录标志 + 大小 + 修改时间）没变就**一个 @Published 都不碰**。
            //
            // 关键 / 顶部 global 菜单栏闪烁的真根因（debug log 实测确认）：FileItem.id 每次都是新 UUID，
            // 无脑赋值会让等价列表看起来「变了」。FSEvents watcher 在 Desktop / Downloads / 家目录这类被
            // .DS_Store / Spotlight / 缩略图缓存等无关写入持续触发的目录上，会**每 ~120ms 触发一次 loadFolder**
            // （去抖周期），形成自维持反馈环。`fileItems` 早有等价守卫，但 `archiveItems = []` 和
            // `status = ...` 之前**每次都无条件重新赋值** —— `@Published` 不做去重，赋同样的值也照发
            // `objectWillChange` → `@FocusedObject` 把整条 `.commands`（顶部菜单栏）反复重建 → 正打开的菜单
            // 被冲掉 → 一直闪、一级菜单都难点开。所以这里**每个 @Published 都先比对、只在真变了才赋值**。
            let sameListing = Self.fileItemsRepresentSameListing(newItems, fileItems)
            if !sameListing {
                fileItems = newItems
            }
            if !archiveItems.isEmpty {
                archiveItems = []
                if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
                if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
            }
            session.clearArchive()
            // 已展开文件夹的子级同步核对（增删改 / 目录消失都在这里反映,详见方法注释）。
            refreshExpandedFolderChildren()
            let newStatus = L10n.format("status.itemCount", fileItems.count)
            if status != newStatus {
                status = newStatus
            }
        } catch {
            fileItems = []
            archiveItems = []
            if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
            if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotOpenFolder")
        }
    }

    /// 使用 Spotlight 查询 Finder tag。结果仍显示成普通文件行，方便继续打开、哈希或创建压缩包。
    func loadTaggedFiles(_ tag: String, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.format("status.searchingTag", tag))
        defer { endAsyncLoad(generation: generation) }

        do {
            let urls = try await fileBrowser.taggedFileURLs(named: tag)
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = fileBrowser.makeFileItems(
                from: urls,
                showSymbolicLinks: AppPreferences.showSymbolicLinks,
                hiddenSuffixes: AppPreferences.hiddenDisplaySuffixes,
                includeMacOSHidden: AppPreferences.hiddenDetectionMode.includesMacOSHiddenFlag,
                folderFirst: false
            )
            archiveItems = []
            if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
            if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
            session.clearArchive()
            status = L10n.format("status.tagItemCount", fileItems.count)
        } catch {
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = []
            archiveItems = []
            if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
            if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
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
    func loadArchive(_ url: URL, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.text("status.readingArchive"))
        defer { endAsyncLoad(generation: generation) }

        let force = isForced(url)
        do {
            let items: [ArchiveItem]
            do {
                items = try await ArchiveService.list(url, force: force)
                // 明文包:无口令。归档内编辑用空口令即可(新条目不加密)。
                resolvedArchivePassword = ""
            } catch {
                // header-encrypted 7z 这类「不给密码连 list 都拿不到」的档案:先用预设密码静默重试,
                // 仍失败 / 没预设 → **弹密码框**让用户输入并重试(和解压流程同款),而不是直接报错放弃
                //（之前只在「有可用预设密码」时重试,没预设就掉到外层 catch 报错 = 不弹密码直接死）。
                // 成功的口令存进 `resolvedArchivePassword`,归档内编辑复用(见该属性注释)。
                guard shouldPromptForArchivePassword(error) else { throw error }
                items = try await listArchivePromptingForPassword(url, force: force)
            }
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            session.setItems(items)
            fileItems = []
            // 0.4.1 #114：list 解析时旁路缓存了归档级注释（zip/rar 头部 Comment）——取出来给横幅展示。
            let comment = ArchiveService.headerComment(for: url)
            if archiveHeaderComment != comment {
                archiveHeaderComment = comment
            }
            refreshArchiveItems()
            // 0.4.2 #7：路径安全分析（绝对路径 / `..` / 盘符 / 控制字符 / setuid / 外指 symlink / 大小写冲突）。
            // 纯 CPU 字符串检查，丢后台跑完再回主 actor；只告知，不改变解压时的既有拦截。
            updateArchiveSecurityFindings(for: items, url: url, generation: generation)
        } catch is CancellationError {
            // 用户在密码框点了取消 → 不当错误处理,只回到中性「读不到」状态,不弹错误 alert。
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
            if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
            session.clearArchive()
            status = L10n.text("status.couldNotReadArchive")
        } catch {
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            if !archiveHeaderComment.isEmpty { archiveHeaderComment = "" }
            if !archiveSecurityFindings.isEmpty { archiveSecurityFindings = [] }
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotReadArchive")
        }
    }

    /// 0.4.2 #7：后台分析归档条目的路径安全问题，回主 actor 后核对仍是同一次加载才发布。
    private func updateArchiveSecurityFindings(for items: [ArchiveItem], url: URL, generation: Int) {
        Task.detached(priority: .utility) { [weak self] in
            let findings = ArchiveSecurityReport.analyze(items)
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentLoad(generation, mode: .archive(url)) else { return }
                if self.archiveSecurityFindings != findings {
                    self.archiveSecurityFindings = findings
                }
            }
        }
    }

    /// 列出需要密码的档案:先用预设密码静默试一次,再弹密码框重试,直到成功或用户取消(抛 `CancellationError`)。
    /// 给 header-encrypted 7z 这类「连列表都需要密码」的档案用 —— 与解压前的密码重试循环同款,复用 `promptForArchivePassword`。
    private func listArchivePromptingForPassword(_ url: URL, force: Bool) async throws -> [ArchiveItem] {
        // 先试「上一次记住的口令」—— 刚编辑完同一加密包后 reload 时免去重复输入(编辑会用同口令重写原包)。
        // 是别的包的残留口令也无妨:对不上只会静默失败,落到下面预设 / 弹框。
        let remembered = resolvedArchivePassword
        if !remembered.isEmpty,
           let items = try? await ArchiveService.list(url, password: remembered, force: force) {
            return items  // resolvedArchivePassword 已是 remembered,不变
        }
        if AppPreferences.hasUsablePresetPassword,
           let items = try? await ArchiveService.list(url, password: AppPreferences.presetPassword, force: force) {
            resolvedArchivePassword = AppPreferences.presetPassword
            return items
        }
        let detectedZipEncryption: ZipEncryptionDetection = url.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: url)
            : .unknown
        var isRetry = false
        while true {
            guard let authentication = promptForArchivePassword(
                archiveURL: url,
                displayName: url.lastPathComponent,
                detectedZipEncryption: detectedZipEncryption,
                isRetry: isRetry,
                actionTitle: L10n.text("button.open")
            ) else {
                throw CancellationError()
            }
            do {
                let items = try await ArchiveService.list(url, password: authentication.password, force: force)
                resolvedArchivePassword = authentication.password
                return items
            } catch {
                guard shouldPromptForArchivePassword(error) else { throw error }
                isRetry = true
            }
        }
    }

    /// 根据压缩包内当前路径生成"这一层"的列表，并自动补齐缺失的目录节点。
    func refreshArchiveItems() {
        let currentItems = session.currentChildren()
        archiveItems = currentItems
        status = L10n.format("status.archivedItemCount", currentItems.count)
    }

    func nextLoadGeneration() -> Int {
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
}
