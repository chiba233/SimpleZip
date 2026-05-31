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
    /// 大小 + 修改时间）逐项比较，忽略每次重建都会变的 `id`(UUID)。顺序敏感（makeFileItems 排序是确定的）。
    /// 用于 loadFolder 判断「内容真的变了吗」，避免 watcher 无关刷新引发空闲闪烁。
    nonisolated static func fileItemsRepresentSameListing(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.url != b.url
                || a.isDirectory != b.isDirectory
                || a.isSymbolicLink != b.isSymbolicLink
                || a.isHidden != b.isHidden
                || a.size != b.size
                || a.modified != b.modified {
                return false
            }
        }
        return true
    }

    /// 加载本地文件夹内容，并按"文件夹优先、名称自然排序"展示。
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
            // 列表内容（按稳定标识 url + 目录标志 + 大小 + 修改时间）没变就**不重新赋值**。
            // 关键：FileItem.id 每次都是新 UUID，无脑赋值会让等价列表看起来「变了」。FSEvents watcher 在
            // Desktop 这类目录被 .DS_Store / Spotlight 等无关写入频繁触发时，会一遍遍 loadFolder 出等价但
            // 全新 UUID 的 items → @Published → reloadData → **空闲时反复闪烁**。内容真变了才赋值刷新。
            if !Self.fileItemsRepresentSameListing(newItems, fileItems) {
                fileItems = newItems
            }

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
