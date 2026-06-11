//
//  ArchiveBrowserModel+Loading.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  本地文件夹 / Spotlight tag 搜索 / 压缩包列出 + 异步任务的 generation 跟踪。
//

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

    /// 加载本地文件夹内容，并按"文件夹优先、名称自然排序"展示。
    /// 0.4.1 文件夹原位展开：列某个子目录的条目，**口径与 loadFolder 完全一致**
    /// （隐藏文件开关 / 符号链接 / macOS 隐藏标志 / `.szs` 虚拟模式过滤 / 文件夹在前），
    /// 但不动任何 @Published 状态 —— 纯查询给 NSOutlineView 的懒加载子级用。
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

    func loadFolder(_ url: URL) {
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
            }
            session.clearArchive()
            let newStatus = L10n.format("status.itemCount", fileItems.count)
            if status != newStatus {
                status = newStatus
            }
        } catch {
            fileItems = []
            archiveItems = []
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
            refreshArchiveItems()
        } catch is CancellationError {
            // 用户在密码框点了取消 → 不当错误处理,只回到中性「读不到」状态,不弹错误 alert。
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            session.clearArchive()
            status = L10n.text("status.couldNotReadArchive")
        } catch {
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            session.clearArchive()
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotReadArchive")
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
