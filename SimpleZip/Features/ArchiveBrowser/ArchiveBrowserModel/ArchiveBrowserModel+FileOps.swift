//
//  ArchiveBrowserModel+FileOps.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  剪切板（copy/cut/paste）+ 删除到废纸篓 + Move To + 拖放到目录。
//

import AppKit
import Foundation

extension ArchiveBrowserModel {
    enum NewFileTemplate: String, CaseIterable, Identifiable {
        case empty
        case text
        case markdown
        case json

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty:
                return L10n.text("file.newFile.empty")
            case .text:
                return L10n.text("file.newFile.text")
            case .markdown:
                return L10n.text("file.newFile.markdown")
            case .json:
                return L10n.text("file.newFile.json")
            }
        }

        var systemImage: String {
            switch self {
            case .empty:
                return "doc"
            case .text:
                return "doc.text"
            case .markdown:
                return "text.alignleft"
            case .json:
                return "curlybraces"
            }
        }

        var defaultName: String {
            switch self {
            case .empty:
                return L10n.text("file.newFile.empty.defaultName")
            case .text:
                return L10n.text("file.newFile.text.defaultName")
            case .markdown:
                return L10n.text("file.newFile.markdown.defaultName")
            case .json:
                return L10n.text("file.newFile.json.defaultName")
            }
        }

        var contents: Data {
            switch self {
            case .empty, .text, .markdown:
                return Data()
            case .json:
                return Data("{\n}\n".utf8)
            }
        }
    }

    func createNewFolderAndBeginRename() {
        // 同一入口,归档模式(可编辑 zip/7z)走「往归档里加空文件夹条目」分支。
        if canDropIntoOpenArchive {
            createNewArchiveEntry(isDirectory: true, contents: nil, defaultName: L10n.text("archive.newFolder.defaultName"))
            return
        }
        guard case .folder(let folderURL) = mode else { return }
        let target = uniqueNewItemURL(in: folderURL, preferredName: L10n.text("file.newFolder.defaultName"))
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            registerCreateUndo([target], actionName: L10n.text("undo.action.create"))
            pendingInlineRenameURL = target.standardizedFileURL
            loadFolder(folderURL)
            recordInstantFileTask(
                kind: .create,
                title: L10n.text("tasks.createFolder"),
                detail: transferSummary(from: target.lastPathComponent, to: displayPath(folderURL))
            )
        } catch {
            reportCreateFailure(error, title: L10n.text("tasks.createFolder"), target: target, folderURL: folderURL)
        }
    }

    func createNewFileAndBeginRename(template: NewFileTemplate) {
        // 同一入口,归档模式(可编辑 zip/7z)走「往归档里加空文件条目」分支,复用模板的默认名 / 内容。
        if canDropIntoOpenArchive {
            createNewArchiveEntry(isDirectory: false, contents: template.contents, defaultName: template.defaultName)
            return
        }
        guard case .folder(let folderURL) = mode else { return }
        let target = uniqueNewItemURL(in: folderURL, preferredName: template.defaultName)
        do {
            guard fileManager.createFile(atPath: target.path, contents: template.contents, attributes: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            registerCreateUndo([target], actionName: L10n.text("undo.action.create"))
            pendingInlineRenameURL = target.standardizedFileURL
            loadFolder(folderURL)
            recordInstantFileTask(
                kind: .create,
                title: L10n.format("tasks.createFile", target.lastPathComponent),
                detail: transferSummary(from: target.lastPathComponent, to: displayPath(folderURL))
            )
        } catch {
            reportCreateFailure(error, title: L10n.format("tasks.createFile", target.lastPathComponent), target: target, folderURL: folderURL)
        }
    }

    func copySelectedFiles() {
        guard case .folder = mode else { return }
        copyFileURLs(selectedFileItems.map(\.url))
    }

    func cutSelectedFiles() {
        guard case .folder = mode else { return }
        cutFileURLs(selectedFileItems.map(\.url))
    }

    func copyFileURLs(_ urls: [URL]) {
        guard case .folder = mode, !urls.isEmpty else { return }
        fileClipboard = (urls, false)
    }

    func cutFileURLs(_ urls: [URL]) {
        guard case .folder = mode, !urls.isEmpty else { return }
        fileClipboard = (urls, true)
    }

    func pasteFiles() {
        guard case .folder(let folderURL) = mode, let fileClipboard, !fileClipboard.urls.isEmpty else { return }

        let operationTask = beginFileTask(
            kind: fileClipboard.shouldMove ? .move : .paste,
            title: fileClipboard.shouldMove
                ? L10n.format("tasks.moveCount", fileClipboard.urls.count)
                : L10n.format("tasks.pasteCount", fileClipboard.urls.count),
            detail: transferSummary(from: fileClipboard.urls, to: folderURL),
            total: fileClipboard.urls.count,
            cancellable: true
        )
        var swiftTask: Task<Void, Never>?
        operationTask.cancel = {
            swiftTask?.cancel()
        }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            status = L10n.text("status.pasting")
            var undoPairs: [(URL, URL)] = []
            var skippedCount = 0
            var sameHashSkips = 0
            var completed = false
            defer {
                registerTransferUndo(undoPairs, shouldMove: fileClipboard.shouldMove)
                if fileClipboard.shouldMove, completed || !undoPairs.isEmpty {
                    self.fileClipboard = nil
                }
            }

            do {
                let total = max(1, fileClipboard.urls.count)
                let hasFolder = fileClipboard.urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                let conflictSession = extractionCoordinator.makeConflictResolutionSession(allowsRememberedChoice: fileClipboard.urls.count > 1 || hasFolder)
                for (index, url) in fileClipboard.urls.enumerated() {
                    try Task.checkCancellation()
                    updateFileTask(
                        operationTask,
                        progress: ArchiveProgressState(
                        fraction: Double(index) / Double(total),
                        currentFile: url.lastPathComponent,
                        completedUnitCount: index + 1,
                        totalUnitCount: total
                        )
                    )
                    let requestedTargetURL = folderURL.appendingPathComponent(url.lastPathComponent)
                    let stats = try await extractionCoordinator.transferItem(
                        source: url,
                        requestedTarget: requestedTargetURL,
                        isMove: fileClipboard.shouldMove,
                        defaultOverwriteBehavior: AppPreferences.overwriteBehavior,
                        conflictSession: conflictSession,
                        updateStatus: { [weak operationTask] status in
                            guard let operationTask else { return }
                            operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status)
                            TaskCenter.shared.notifyTaskChanged()
                        },
                        updateProgress: { [weak operationTask] progress in
                            guard let operationTask else { return }
                            operationTask.progress = progress
                            TaskCenter.shared.notifyTaskChanged()
                        },
                        recordPair: { undoPairs.append(($0, $1)) },
                        recordHashComparison: { operationTask.hashComparisons.append($0) }
                    )
                    skippedCount += stats.skipped
                    sameHashSkips += stats.sameHashSkips
                }
                operationTask.transferLog = conflictSession.transferLog
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                completed = true
                updateFileTask(
                    operationTask,
                    progress: ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.done"), completedUnitCount: total, totalUnitCount: total)
                )
                let outcome = transferOutcome(transferred: undoPairs.count, skipped: skippedCount, sameHashSkips: sameHashSkips)
                TaskCenter.shared.finish(operationTask, outcome: outcome)
                if case .succeeded = outcome { SystemSound.operationComplete?.play() }
                // 刷新交给 FolderWatcher：写入当前文件夹会触发 FSEvents 自动 reload。
            } catch is CancellationError {
                errorMessage = nil
                status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    private func registerTransferUndo(_ pairs: [(URL, URL)], shouldMove: Bool) {
        guard !pairs.isEmpty else { return }
        if shouldMove {
            registerMoveUndo(pairs.map { (from: $0.0, to: $0.1) }, actionName: L10n.text("undo.action.move"))
        } else {
            registerCopyUndo(pairs.map { (source: $0.0, dest: $0.1) }, actionName: L10n.text("undo.action.copy"))
        }
    }

    /// 重命名单个文件 / 文件夹（同目录内改名）。非法名 / 重名都报错不覆盖，绝不静默盖掉已有文件。
    /// 由 FileTable 的内联编辑提交 newName 后调用；newName 是用户键入的纯文件名（不含路径）。
    func renameFile(_ item: FileItem, to newName: String) {
        guard case .folder = mode else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = item.url.lastPathComponent
        // 空名或没改 → 直接当取消，不打扰用户。
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        // 非法名：含路径分隔符，或是 . / ..（这些会让目标 URL 跳出当前目录或指向自身）。
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentRenameAlert(message: L10n.text("file.rename.invalidName"))
            return
        }

        let target = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // 大小写不敏感文件系统上「File → file」这种纯大小写改名：目标 path 会「存在」（同一 inode），
        // 但确实是合法改名，交给 moveItem 处理，不当成冲突。
        let sameFileCaseOnly = target.path.caseInsensitiveCompare(item.url.path) == .orderedSame
        if !sameFileCaseOnly, fileManager.fileExists(atPath: target.path) {
            presentRenameAlert(message: L10n.format("file.rename.conflict.message", trimmed))
            return
        }

        do {
            try fileManager.moveItem(at: item.url, to: target)
            registerMoveUndo([(from: item.url, to: target)], actionName: L10n.text("undo.action.rename"))
            // 改名后旧 URL 没了、选区重映射会变空，光标会丢回顶端 —— 让刷新后光标停在改名后的文件并恢复键盘焦点。
            pendingSelectionURL = target.standardizedFileURL
            recordInstantFileTask(
                kind: .rename,
                title: L10n.format("tasks.renameItem", oldName),
                detail: transferSummary(from: item.url, to: target)
            )
            // 刷新交给 FolderWatcher：同目录改名会触发 FSEvents 自动 reload。
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
            recordInstantFileTask(
                kind: .rename,
                title: L10n.format("tasks.renameItem", oldName),
                detail: transferSummary(from: item.url, to: target),
                outcome: .failed(error.localizedDescription)
            )
        }
    }

    private func presentRenameAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("file.rename.failed.title")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.runModal()
    }

    // MARK: - Task4 权限 / 属主（chmod / chown）

    /// 右键「权限与属主…」：从选中的真实文件构造编辑请求（仅文件夹浏览模式;虚拟只读浏览不适用）。
    func editSelectedPermissions() {
        guard case .folder = mode else { return }
        let items = selectedFileItems
        guard let first = items.first else { return }
        let initialMode = FilePermissionService.currentMode(of: first.url) ?? 0o644
        let initialOwner = FilePermissionService.currentOwner(of: first.url)
        let mixed = items.dropFirst().contains { FilePermissionService.currentMode(of: $0.url) != initialMode }
        permissionsEditRequest = FilePermissionsEditRequest(
            urls: items.map(\.url),
            title: items.count == 1 ? first.displayName : L10n.format("file.permissions.multiTitle", "\(items.count)"),
            initialMode: initialMode,
            initialOwner: initialOwner,
            isDirectory: first.isDirectory,
            containsDirectory: items.contains { $0.isDirectory },
            mixedSelection: mixed
        )
    }

    /// 应用权限 / 属主改动 —— 走**文件操作**类活动中心任务（不是归档操作）,跟复制 / 移动 / 删除同类。
    /// 标题带真实目标值（「更改 a.txt 的权限为 755」/「…属主为 alice」/多选「更改 3 个项目的…」）。
    /// 真正的 chmod / chown 在后台线程执行（自有文件免提权直改,失败的 + 改属主合并成一次系统授权);
    /// 用户取消授权弹窗 → 任务标「已取消」,部分失败 → 活动中心红色行带原因。
    func applyPermissions(mode newMode: UInt16?, owner newOwner: String?, recursive: Bool, to urls: [URL]) {
        guard newMode != nil || (newOwner?.isEmpty == false), !urls.isEmpty else { return }

        // 撤销快照：在改之前抓每个 url 的旧 mode / owner（仅非递归 —— 递归整棵树的旧权限无法可靠快照）。
        let undoSteps: [UndoPermissionsStep] = recursive ? [] : urls.map { url in
            UndoPermissionsStep(
                url: url,
                mode: newMode != nil ? FilePermissionService.currentMode(of: url) : nil,
                owner: (newOwner?.isEmpty == false) ? FilePermissionService.currentOwner(of: url) : nil
            )
        }

        let baseSubject = urls.count == 1
            ? urls[0].lastPathComponent
            : L10n.format("status.permissions.items", "\(urls.count)")
        // 递归时标题点明「含子项」,让活动中心一眼看出是整棵树而非仅选中项。
        let subject = recursive ? L10n.format("status.permissions.recursiveSubject", baseSubject) : baseSubject
        let clauses = permissionChangeClauses(mode: newMode, owner: newOwner)
        let changingTitle = L10n.format("status.permissions.changing", subject, clauses)

        let operationTask = beginFileTask(
            kind: .permissions,
            title: changingTitle,
            detail: nil,
            total: urls.count,
            cancellable: false   // 取消点就是系统授权弹窗本身;操作本身瞬时,不另设中途取消。
        )

        Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            self.status = changingTitle
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try FilePermissionService.apply(mode: newMode, owner: newOwner, to: urls, recursive: recursive)
                }.value

                var log = outcome.changed.map { url -> TransferLogEntry in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return TransferLogEntry(
                        name: url.lastPathComponent,
                        action: .changed,
                        isDirectory: isDir,
                        detail: self.permissionAppliedDetail(mode: newMode, owner: newOwner, isDirectory: isDir)
                    )
                }
                log += outcome.failures.map {
                    TransferLogEntry(name: $0.url.lastPathComponent, action: .failed, isDirectory: false, detail: $0.reason)
                }
                operationTask.transferLog = log

                if outcome.failures.isEmpty {
                    // 撤销 = 恢复改之前的 mode / owner（非递归才注册,见 undoSteps 的说明）。
                    if !undoSteps.isEmpty {
                        self.registerPermissionsUndo(undoSteps, actionName: L10n.text("undo.action.permissions"))
                    }
                    self.status = L10n.format("status.permissions.changed", subject, clauses)
                    TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
                    SystemSound.operationComplete?.play()
                } else {
                    let partial = L10n.format("status.permissionsChangedPartial", "\(outcome.changed.count)", "\(outcome.failures.count)")
                    self.status = outcome.changed.isEmpty ? L10n.text("status.failed") : partial
                    TaskCenter.shared.finish(operationTask, outcome: .failed(outcome.changed.isEmpty ? (outcome.failures.first?.reason ?? partial) : partial))
                }
                self.reload()
            } catch FilePermissionService.Failure.cancelled {
                // 用户取消授权弹窗 → 标「已取消」而非失败。
                self.status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                self.status = L10n.text("status.failed")
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Finder 标签

    /// 给文件追加一个 Finder 标签（拖文件到侧栏标签行触发，Finder 同款交互）。
    /// 已有该标签的文件跳过；瞬时操作不进活动中心，结果走状态栏，失败弹错误。
    func applyFinderTag(_ tag: String, to urls: [URL]) {
        var failureCount = 0
        for url in urls {
            do {
                let existing = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
                guard !existing.contains(tag) else { continue }
                if #available(macOS 26.0, *) {
                    // 原生 setter（macOS 26 起开放）：系统补全颜色等元数据。
                    var writable = url
                    var values = URLResourceValues()
                    values.tagNames = existing + [tag]
                    try writable.setResourceValues(values)
                } else {
                    try Self.appendTagViaExtendedAttribute(tag, to: url)
                }
            } catch {
                failureCount += 1
            }
        }
        if failureCount == 0 {
            status = L10n.format("status.taggedCount", "\(urls.count)", tag)
        } else {
            status = L10n.text("status.failed")
            errorMessage = L10n.format("error.tagFailed", "\(failureCount)")
        }
        reload()
    }

    /// 右键「从标签移除」：把当前浏览的标签从选中文件上摘掉（文件本体不动）。
    /// 只在 `.tag` 模式有意义 —— 菜单也只在该模式渲染此项。
    func removeSelectedFromCurrentTag() {
        guard case .tag(let tag) = mode, !selectedFileItems.isEmpty else { return }
        let urls = selectedFileItems.map(\.url)
        var removedURLs: [URL] = []
        var failureCount = 0
        for url in urls {
            do {
                if #available(macOS 26.0, *) {
                    let existing = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
                    guard existing.contains(tag) else { continue }
                    var writable = url
                    var values = URLResourceValues()
                    values.tagNames = existing.filter { $0 != tag }
                    try writable.setResourceValues(values)
                } else {
                    try Self.removeTagViaExtendedAttribute(tag, from: url)
                }
                removedURLs.append(url.standardizedFileURL)
            } catch {
                failureCount += 1
            }
        }
        if !removedURLs.isEmpty {
            let removedURLSet = Set(removedURLs)
            let removedItemIDs = Set(fileItems.compactMap { item in
                removedURLSet.contains(item.url.standardizedFileURL) ? item.id : nil
            })
            fileItems.removeAll { removedURLSet.contains($0.url.standardizedFileURL) }
            selection.subtract(removedItemIDs)
        }
        if failureCount == 0 {
            status = L10n.format("status.untaggedCount", "\(removedURLs.count)", tag)
        } else {
            status = L10n.text("status.failed")
            errorMessage = L10n.format("error.tagFailed", "\(failureCount)")
        }
    }

    /// macOS 26 以下的标签移除兜底：过滤 `kMDItemUserTags` 原始条目（名字或「名字\n颜色号」），
    /// 清空则整个删掉扩展属性。
    private nonisolated static func removeTagViaExtendedAttribute(_ tag: String, from url: URL) throws {
        let attributeName = "com.apple.metadata:_kMDItemUserTags"
        let length = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard length > 0 else { return }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, attributeName, buffer.baseAddress, length, 0, 0)
        }
        guard read > 0,
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return }
        let remaining = entries.filter { $0 != tag && !$0.hasPrefix(tag + "\n") }
        guard remaining.count != entries.count else { return }
        if remaining.isEmpty {
            guard removexattr(url.path, attributeName, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return
        }
        let payload = try PropertyListSerialization.data(fromPropertyList: remaining, format: .binary, options: 0)
        let result = payload.withUnsafeBytes { buffer in
            setxattr(url.path, attributeName, buffer.baseAddress, payload.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// macOS 26 以下的兜底：直接写 `com.apple.metadata:_kMDItemUserTags` 扩展属性。
    /// 读**原始条目**再追加 —— 既有标签可能带「名字\n颜色号」后缀，从 tagNames getter 读会丢颜色。
    private nonisolated static func appendTagViaExtendedAttribute(_ tag: String, to url: URL) throws {
        let attributeName = "com.apple.metadata:_kMDItemUserTags"
        var entries: [String] = []
        let length = getxattr(url.path, attributeName, nil, 0, 0, 0)
        if length > 0 {
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { buffer in
                getxattr(url.path, attributeName, buffer.baseAddress, length, 0, 0)
            }
            if read > 0, let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                entries = decoded
            }
        }
        guard !entries.contains(where: { $0 == tag || $0.hasPrefix(tag + "\n") }) else { return }
        entries.append(tag)
        let payload = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let result = payload.withUnsafeBytes { buffer in
            setxattr(url.path, attributeName, buffer.baseAddress, payload.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - #112 批量格式转换（extract → repack，引擎在 Core/ArchiveConversion）

    /// 选中的归档文件是否都可转换（是 ArchiveService 支持的归档类型）。菜单据此显隐「转换格式…」。
    var canConvertSelectedArchives: Bool {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return false }
        return selectedFileItems.allSatisfy { !$0.isDirectory && ArchiveService.isSupportedArchive($0.url) }
    }

    /// 右键「转换格式…」：弹确认 sheet（选目标格式 / 级别 / 可选密码），确认后批量转换。
    func requestConvertSelectedArchives() {
        guard canConvertSelectedArchives else { return }
        convertArchiveRequest = ConvertArchiveRequest(sourceURLs: selectedFileItems.map(\.url))
    }

    /// 执行批量转换：逐个源走 `ArchiveConversion.convert`，每个一条可取消的活动中心任务。
    /// 目标落在源同目录，文件名避让重名（UniqueFileName）。失败 / 取消逐项独立,不影响其它。
    func performConversion(_ request: ConvertArchiveRequest) {
        for sourceURL in request.sourceURLs {
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let destination = UniqueFileName.numbered(
                in: sourceURL.deletingLastPathComponent(),
                preferredName: "\(baseName).\(request.targetFormat.pathExtension)",
                exists: { fileManager.fileExists(atPath: $0.path) }
            )
            var options = ArchiveCreationOptions()
            options.format = request.targetFormat
            options.compressionLevel = request.compressionLevel
            options.password = request.password
            options.passwordConfirmation = request.password

            let convertRequest = ArchiveConversionRequest(
                sourceURL: sourceURL,
                sourcePassword: resolvedArchivePassword,
                targetOptions: options,
                destinationURL: destination
            )
            let title = L10n.format("convert.task.title", sourceURL.lastPathComponent, request.targetFormat.title)
            let operationTask = beginFileTask(kind: .convert, title: title, detail: destination.lastPathComponent, total: 1, cancellable: true, category: .archive)
            let operationID = UUID()
            operationTask.cancel = { BackendProcessRunner.cancelRunningCommand(operationID: operationID) }
            // 0.4.2 #21：整单重跑（仅本源包；输出名会按「名 2」避让，不覆盖上次产物）。
            operationTask.rerun = { [weak self] in
                var rerunRequest = ConvertArchiveRequest(sourceURLs: [sourceURL])
                rerunRequest.targetFormat = request.targetFormat
                rerunRequest.compressionLevel = request.compressionLevel
                rerunRequest.password = request.password
                self?.performConversion(rerunRequest)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await ArchiveConversion.convert(
                        convertRequest,
                        operationID: operationID,
                        progress: { state in
                            Task { @MainActor in operationTask.progress = state }
                        }
                    )
                    operationTask.transferLog = [
                        TransferLogEntry(name: destination.lastPathComponent, action: .added, isDirectory: false)
                    ]
                    // 撤销 = 把转换产物移废纸篓（源包不动）；重做 = 移回。
                    self.registerCreateUndo([destination], actionName: L10n.text("undo.action.convert"))
                    TaskCenter.shared.finish(operationTask, outcome: .succeeded(destination))
                    SystemSound.operationComplete?.play()
                    self.reload()
                } catch is CancellationError {
                    TaskCenter.shared.finish(operationTask, outcome: .cancelled)
                } catch {
                    self.errorMessage = error.localizedDescription
                    TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
                }
            }
        }
        status = L10n.format("convert.status.started", "\(request.sourceURLs.count)")
    }

    // MARK: - 拆分 / 合并分卷（字节级，对齐官方 7-Zip 的 Split / Combine；引擎在 Core/FileSplitCombine）

    /// 右键「拆分…」：单选非目录文件 → 弹卷大小 sheet（确认后走 `performSplit`）。
    func splitSelectedFile() {
        guard selectedFileItems.count == 1,
              let item = selectedFileItems.first,
              !item.isDirectory else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path)
        fileSplitRequest = FileSplitRequest(url: item.url, fileSize: (attributes?[.size] as? Int64) ?? 0)
    }

    /// 字节级拆分成 `<名>.001/002…`。文件操作类任务：可取消（块间检查）、逐分片记到活动中心。
    func performSplit(_ url: URL, volumeSize: Int64) {
        let title = L10n.format("status.splitting", url.lastPathComponent)
        let operationTask = beginFileTask(kind: .split, title: title, detail: nil, total: 1, cancellable: true, category: .archive)
        // 0.4.2 #21：整单重跑（同样的卷大小；目标分片已存在会照常整组拒绝，不覆盖）。
        operationTask.rerun = { [weak self] in self?.performSplit(url, volumeSize: volumeSize) }

        let worker = Task.detached(priority: .userInitiated) {
            try FileSplitCombine.split(url, volumeSize: volumeSize) { written, total in
                let fraction = total > 0 ? min(1, Double(written) / Double(total)) : nil
                Task { @MainActor in
                    operationTask.progress = ArchiveProgressState(fraction: fraction, currentFile: url.lastPathComponent)
                }
            }
        }
        operationTask.cancel = { worker.cancel() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = title
            do {
                let parts = try await worker.value
                operationTask.transferLog = parts.map {
                    TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false)
                }
                // 撤销 = 把拆出来的分片移废纸篓（registerCreateUndo,非破坏可恢复）；重做 = 从废纸篓移回。
                self.registerCreateUndo(parts, actionName: L10n.text("undo.action.split"))
                self.status = L10n.format("status.splitDone", "\(parts.count)")
                TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
                SystemSound.operationComplete?.play()
                self.reload()
            } catch is CancellationError {
                self.status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
                self.reload()
            } catch {
                self.status = L10n.text("status.failed")
                self.errorMessage = error.localizedDescription
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// 右键「合并分卷」：选中 `.001` 首卷 → 把连续分片按序拼回单文件（输出避让重名，不覆盖）。
    func combineSelectedVolumes() {
        guard selectedFileItems.count == 1,
              let item = selectedFileItems.first,
              FileSplitCombine.isFirstVolume(item.url) else { return }
        let firstVolume = item.url

        // 0.4.2 合并前预检：卷数 + 总大小 + 中断警告，确认后才动手（同步 NSAlert，跟口令弹窗同一体例）。
        let parts = FileSplitCombine.volumeParts(for: firstVolume)
        guard !parts.isEmpty else { return }
        let totalBytes = parts.reduce(Int64(0)) { sum, part in
            sum + (((try? fileManager.attributesOfItem(atPath: part.path))?[.size] as? Int64) ?? 0)
        }
        let outputName = firstVolume.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("file.combine.menuItem")
        var message = L10n.format(
            "combine.confirm.message",
            "\(parts.count)",
            outputName,
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        )
        // 连续前缀之外还有更高卷号（中段缺卷）→ 拼出来必然不完整，给醒目警告但允许继续（用户可能就要前段）。
        if let siblings = try? fileManager.contentsOfDirectory(atPath: firstVolume.deletingLastPathComponent().path),
           let set = FileSplitCombine.volumeSet(forMemberNamed: firstVolume.lastPathComponent, among: siblings),
           set.highestIndex > parts.count {
            alert.alertStyle = .warning
            message += "\n\n" + L10n.format("combine.confirm.gapWarning", String(format: "%03d", parts.count + 1), "\(parts.count)")
        }
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("file.combine.menuItem"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let title = L10n.format("status.combining", firstVolume.lastPathComponent)
        let operationTask = beginFileTask(kind: .combine, title: title, detail: nil, total: 1, cancellable: true, category: .archive)

        let worker = Task.detached(priority: .userInitiated) {
            try FileSplitCombine.combine(firstVolume: firstVolume) { written, total in
                let fraction = total > 0 ? min(1, Double(written) / Double(total)) : nil
                Task { @MainActor in
                    operationTask.progress = ArchiveProgressState(fraction: fraction, currentFile: firstVolume.lastPathComponent)
                }
            }
        }
        operationTask.cancel = { worker.cancel() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = title
            do {
                let output = try await worker.value
                operationTask.transferLog = [
                    TransferLogEntry(name: output.lastPathComponent, action: .added, isDirectory: false)
                ]
                // 撤销 = 把合并出来的文件移废纸篓；重做 = 移回。
                self.registerCreateUndo([output], actionName: L10n.text("undo.action.combine"))
                self.status = L10n.format("status.combined", output.lastPathComponent)
                TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
                SystemSound.operationComplete?.play()
                self.reload()
            } catch is CancellationError {
                self.status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
                self.reload()
            } catch {
                self.status = L10n.text("status.failed")
                self.errorMessage = error.localizedDescription
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// 标题 / 状态栏用的「权限为 755、属主为 alice」描述片段（按实际要改的项拼）。
    private func permissionChangeClauses(mode: UInt16?, owner: String?) -> String {
        var parts: [String] = []
        if let mode {
            parts.append(L10n.format("status.permissions.modeClause", String(format: "%03o", Int(mode) & 0o777)))
        }
        if let owner, !owner.isEmpty {
            parts.append(L10n.format("status.permissions.ownerClause", owner))
        }
        return parts.joined(separator: L10n.text("status.permissions.clauseSeparator"))
    }

    /// 活动中心逐文件「已更改」行的明细：`rwxr-xr-x (755) · alice`（只列实际改了的项）。
    private func permissionAppliedDetail(mode: UInt16?, owner: String?, isDirectory: Bool) -> String? {
        var parts: [String] = []
        if let mode {
            let symbolic = FileBrowserService.posixModeString(mode: mode, isDirectory: isDirectory, isSymbolicLink: false)
            parts.append("\(symbolic) (\(String(format: "%03o", Int(mode) & 0o777)))")
        }
        if let owner, !owner.isEmpty {
            parts.append(owner)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 删除选中项后，键盘光标应落到的「邻居」URL。
    /// 取 fileItems 顺序里**第一个被删项的前一项**（一定是幸存项）；若删的就是开头，则取被删之后第一个幸存项。
    /// 全删空 / 算不出 → nil。用 fileItems（模型排序顺序）近似视觉顺序，符合「回到上一个文件」的直觉。
    private func selectionNeighborURL(removing removedIDs: Set<UUID>) -> URL? {
        guard let firstIdx = fileItems.firstIndex(where: { removedIDs.contains($0.id) }) else { return nil }
        if firstIdx > 0 { return fileItems[firstIdx - 1].url }
        return fileItems[(firstIdx + 1)...].first(where: { !removedIDs.contains($0.id) })?.url
    }

    func deleteSelectedFiles() {
        // 文件夹和标签两种模式列出的都是真实文件,都可删 —— 旧 guard 只认 .folder,
        // 标签视图里删除**静默无操作**(用户报的 bug)。归档模式的条目删除走归档自己的入口。
        switch mode {
        case .folder, .tag:
            break
        case .archive:
            return
        }
        guard !selectedFileItems.isEmpty else { return }
        // 0.4.2 #4：选中项属于分卷家族且家族还有未选中成员 → 问「删除整组还是仅所选」。
        // 折叠显示下选中首卷删除,十有八九是想删整组;但绝不静默扩大删除范围 —— 必须显式确认。
        var targets = selectedFileItems
        if AppPreferences.collapseVolumeSets {
            let names = fileItems.filter { !$0.isDirectory }.map { $0.url.lastPathComponent }
            let selectedNames = Set(targets.map { $0.url.lastPathComponent })
            var extraNames: Set<String> = []
            for item in targets where !item.isDirectory {
                if let set = FileSplitCombine.volumeSet(forMemberNamed: item.url.lastPathComponent, among: names),
                   set.volumeCount >= 2 {
                    for name in set.presentNames where !selectedNames.contains(name) {
                        extraNames.insert(name)
                    }
                }
            }
            if !extraNames.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.text("file.deleteVolumeFamily.title")
                alert.informativeText = L10n.format("file.deleteVolumeFamily.message", "\(extraNames.count)")
                alert.addButton(withTitle: L10n.text("file.deleteVolumeFamily.whole"))
                alert.addButton(withTitle: L10n.text("file.deleteVolumeFamily.selectionOnly"))
                alert.addButton(withTitle: L10n.text("button.cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let byName = Dictionary(fileItems.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
                    targets += extraNames.compactMap { byName[$0] }
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
            }
        }
        if AppPreferences.confirmBeforeDeletingFiles {
            guard confirmDelete(items: targets) else { return }
        }

        // 删除前先算好「光标该落到哪」—— 用删除前的 fileItems 顺序，删成功后置 pendingSelectionURL，
        // FileTable 刷新后会选中它并把键盘焦点交回表格（删一项后方向键从邻居继续，不回顶端）。
        let neighborURL = selectionNeighborURL(removing: Set(targets.map(\.id)))

        // 删除前记下每项是否目录 —— 用于活动中心逐文件「已删除」记录里加「（文件夹）」后缀。
        let isDirectoryByPath = Dictionary(
            targets.map { ($0.url.standardizedFileURL.path, $0.isDirectory) },
            uniquingKeysWith: { first, _ in first }
        )
        func deleteLog(_ urls: [URL]) -> [TransferLogEntry] {
            urls.map { TransferLogEntry(name: $0.lastPathComponent, action: .deleted, isDirectory: isDirectoryByPath[$0.standardizedFileURL.path] ?? false) }
        }

        var trashed: [(original: URL, trashURL: URL)] = []
        defer {
            // 撤销 = 从废纸篓移回原位；重做 = 移回废纸篓那个路径。
            registerTrashUndo(trashed, actionName: L10n.text("undo.action.delete"))
        }
        do {
            for item in targets {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as URL? {
                    trashed.append((original: item.url, trashURL: trashURL))
                }
            }
            // trashItem 自身不出声，显式播放 Finder「移到废纸篓」音效（whoosh + 落下，一次播放）。
            SystemSound.moveToTrash?.play()
            if let neighborURL { pendingSelectionURL = neighborURL }
            recordInstantFileTask(
                kind: .delete,
                title: L10n.format("tasks.deleteCount", trashed.count),
                detail: transferSummary(from: trashed.map(\.original), to: L10n.text("tasks.trashDestination")),
                transferLog: deleteLog(trashed.map(\.original))
            )
            // 文件夹模式刷新交给 FolderWatcher（FSEvents 自动 reload）；
            // 标签模式没有 watcher（搜索结果），删完显式重跑标签搜索。
            if case .tag = mode {
                reload()
            }
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
            // 失败时仍把已经成功移走的那些列进逐文件记录（best-effort，不假装全删了）。
            recordInstantFileTask(
                kind: .delete,
                title: L10n.format("tasks.deleteCount", targets.count),
                detail: transferSummary(from: targets.map(\.url), to: L10n.text("tasks.trashDestination")),
                outcome: .failed(error.localizedDescription),
                transferLog: deleteLog(trashed.map(\.original))
            )
        }
    }

    /// 「创建副本」—— Finder 式：在同目录复制成「<名字> 副本[.ext]」，重名再「<名字> 副本 2」…
    /// 刷新交给 FolderWatcher（新文件落在当前目录会触发 FSEvents）。
    func duplicateSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        var copies: [(source: URL, dest: URL)] = []
        defer {
            registerCopyUndo(copies, actionName: L10n.text("undo.action.duplicate"))
        }
        do {
            for item in selectedFileItems {
                let dest = duplicateDestinationURL(for: item.url)
                try fileManager.copyItem(at: item.url, to: dest)
                copies.append((source: item.url, dest: dest))
            }
            SystemSound.operationComplete?.play()
            recordInstantFileTask(
                kind: .duplicate,
                title: L10n.format("tasks.duplicateCount", copies.count),
                detail: transferSummary(from: copies.map(\.source), to: copies.first?.dest.deletingLastPathComponent())
            )
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
            recordInstantFileTask(
                kind: .duplicate,
                title: L10n.format("tasks.duplicateCount", selectedFileItems.count),
                detail: transferSummary(from: selectedFileItems.map(\.url), to: selectedFileItems.first?.url.deletingLastPathComponent()),
                outcome: .failed(error.localizedDescription)
            )
        }
    }

    /// 给 `url` 在同目录算一个不冲突的「副本」目标名。后缀用本地化的「 副本」/「 copy」，
    /// 插在扩展名之前（`a.zip` → `a 副本.zip`），与 Finder 行为一致。
    private func duplicateDestinationURL(for url: URL) -> URL {
        // 普通文件：`fileExists`（跟随符号链接）即可。命名递增逻辑在 Core `UniqueFileName`。
        UniqueFileName.suffixed(
            for: url,
            suffix: L10n.text("file.duplicate.suffix"),
            exists: { fileManager.fileExists(atPath: $0.path) }
        )
    }

    /// 右键「创建符号链接」：给每个选中项在**同目录**建一个指向它的符号链接。
    /// 链接目标用**相对路径**（仅文件名）—— 链接与目标同目录，整个文件夹被移动后链接仍有效。
    /// 撤销 = 删掉建出来的链接（registerCreateUndo，移废纸篓）。
    func createSymbolicLinkForSelection() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        var created: [URL] = []
        defer {
            if !created.isEmpty {
                registerCreateUndo(created, actionName: L10n.text("undo.action.symlink"))
            }
        }
        do {
            for item in selectedFileItems {
                let linkURL = symbolicLinkDestinationURL(for: item.url)
                try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: item.url.lastPathComponent)
                created.append(linkURL)
            }
            SystemSound.operationComplete?.play()
            if let first = created.first {
                pendingSelectionURL = first.standardizedFileURL
            }
            recordInstantFileTask(
                kind: .create,
                title: L10n.format("tasks.symlinkCount", "\(created.count)"),
                transferLog: created.map { TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false) }
            )
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
            // 失败任务也带上**已经建出来的**链接，让用户在活动中心看到哪些已生成（defer 已登记它们的撤销）。
            recordInstantFileTask(
                kind: .create,
                title: L10n.format("tasks.symlinkCount", "\(selectedFileItems.count)"),
                outcome: .failed(error.localizedDescription),
                transferLog: created.map { TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false) }
            )
        }
    }

    /// 给 `url` 在同目录算一个不冲突的符号链接名：`a.zip` → `a 符号链接.zip`，重名递增。
    /// 用 `attributesOfItem`（lstat 语义）判存在 —— 能识别**已有同名符号链接**（含失效链接），`fileExists` 会跟随链接漏判。
    private func symbolicLinkDestinationURL(for url: URL) -> URL {
        // **lstat 语义**（`attributesOfItem`）：能识别已有的同名符号链接（含失效链接）；`fileExists` 会跟随链接漏判。
        UniqueFileName.suffixed(
            for: url,
            suffix: L10n.text("file.symlink.suffix"),
            exists: { (try? fileManager.attributesOfItem(atPath: $0.path)) != nil }
        )
    }

    private func uniqueNewItemURL(in folderURL: URL, preferredName: String) -> URL {
        UniqueFileName.numbered(
            in: folderURL,
            preferredName: preferredName,
            exists: { fileManager.fileExists(atPath: $0.path) }
        )
    }

    private func reportCreateFailure(_ error: Error, title: String, target: URL, folderURL: URL) {
        errorMessage = error.localizedDescription
        status = L10n.text("status.failed")
        recordInstantFileTask(
            kind: .create,
            title: title,
            detail: transferSummary(from: target.lastPathComponent, to: displayPath(folderURL)),
            outcome: .failed(error.localizedDescription)
        )
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
        let operationTask = beginFileTask(
            kind: shouldMove ? .move : .copy,
            title: shouldMove ? L10n.format("tasks.moveCount", urls.count) : L10n.format("tasks.copyCount", urls.count),
            detail: transferSummary(from: urls, to: destinationFolder),
            total: urls.count,
            cancellable: true
        )
        var swiftTask: Task<Void, Never>?
        operationTask.cancel = {
            swiftTask?.cancel()
        }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            errorMessage = nil
            status = shouldMove ? L10n.text("status.movingFiles") : L10n.text("status.copyingFiles")
            var undoPairs: [(URL, URL)] = []
            var skippedCount = 0
            var sameHashSkips = 0
            defer {
                registerTransferUndo(undoPairs, shouldMove: shouldMove)
            }

            do {
                let total = max(1, urls.count)
                let hasFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                let conflictSession = extractionCoordinator.makeConflictResolutionSession(allowsRememberedChoice: urls.count > 1 || hasFolder)
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    updateFileTask(
                        operationTask,
                        progress: ArchiveProgressState(
                        fraction: Double(index) / Double(total),
                        currentFile: url.lastPathComponent,
                        completedUnitCount: index + 1,
                        totalUnitCount: total
                        )
                    )
                    if shouldMove && url.deletingLastPathComponent().standardizedFileURL == destinationFolder.standardizedFileURL {
                        skippedCount += 1   // 移到同一文件夹 = 无操作，计入跳过
                        continue
                    }
                    let requestedTargetURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
                    let stats = try await extractionCoordinator.transferItem(
                        source: url,
                        requestedTarget: requestedTargetURL,
                        isMove: shouldMove,
                        defaultOverwriteBehavior: AppPreferences.overwriteBehavior,
                        conflictSession: conflictSession,
                        updateStatus: { [weak operationTask] status in
                            guard let operationTask else { return }
                            operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status)
                            TaskCenter.shared.notifyTaskChanged()
                        },
                        updateProgress: { [weak operationTask] progress in
                            guard let operationTask else { return }
                            operationTask.progress = progress
                            TaskCenter.shared.notifyTaskChanged()
                        },
                        recordPair: { undoPairs.append(($0, $1)) },
                        recordHashComparison: { operationTask.hashComparisons.append($0) }
                    )
                    skippedCount += stats.skipped
                    sameHashSkips += stats.sameHashSkips
                }
                operationTask.transferLog = conflictSession.transferLog
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                updateFileTask(
                    operationTask,
                    progress: ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.done"), completedUnitCount: total, totalUnitCount: total)
                )
                status = L10n.text("status.done")
                let outcome = transferOutcome(transferred: undoPairs.count, skipped: skippedCount, sameHashSkips: sameHashSkips)
                TaskCenter.shared.finish(operationTask, outcome: outcome)
                if case .succeeded = outcome { SystemSound.operationComplete?.play() }
                // 刷新交给 FolderWatcher：拖入 / 拖出当前文件夹都会触发 FSEvents 自动 reload，
                // 不必再手动判断 destination 是否等于当前目录。
            } catch is CancellationError {
                errorMessage = nil
                status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    private func beginFileTask(
        kind: OperationTask.Kind,
        title: String,
        detail: String?,
        total: Int,
        cancellable: Bool,
        category: OperationTask.Category = .fileOperation
    ) -> OperationTask {
        // 复制/移动/粘贴不接文本 detailsSession：覆盖前的「源 vs 目标」哈希比对存到 task.hashComparisons，
        // 活动中心用格式化卡片渲染（而非命令输出文本）。没有冲突的平凡转移 → 无比对 → 不出详情入口。
        // category 默认文件操作；拆分 / 合并分卷 / 转换格式这类**作用于归档**的操作传 .archive，
        // 落在活动中心「归档操作」分区（用户预期在那找,而非文件操作）。
        let task = TaskCenter.shared.begin(
            category: category,
            kind: kind,
            title: title,
            detail: detail,
            cancellable: cancellable
        )
        task.progress = ArchiveProgressState(
            fraction: total > 0 ? 0 : 1,
            currentFile: nil,
            statusText: title,
            completedUnitCount: 0,
            totalUnitCount: total
        )
        TaskCenter.shared.notifyTaskChanged()
        return task
    }

    private func updateFileTask(_ task: OperationTask, progress: ArchiveProgressState) {
        task.progress = progress
        TaskCenter.shared.notifyTaskChanged()
    }

    // 0.4.2:批量重命名(+CreateExtract.swift)也要记即时任务 —— private 降 internal(跨 extension 文件,同仓库拆分惯例)。
    func recordInstantFileTask(
        kind: OperationTask.Kind,
        title: String,
        detail: String? = nil,
        outcome: OperationTask.Status = .succeeded(nil),
        transferLog: [TransferLogEntry] = []
    ) {
        let task = TaskCenter.shared.begin(
            category: .fileOperation,
            kind: kind,
            title: title,
            detail: detail,
            cancellable: false
        )
        task.progress = ArchiveProgressState(fraction: 1, currentFile: nil, statusText: statusText(for: outcome))
        task.transferLog = transferLog
        TaskCenter.shared.finish(task, outcome: outcome)
    }


    /// 根据实际转移项数 / 跳过项数决定整体结果：真转移了东西 = 成功；什么都没动、全是跳过 =
    /// 中性的「已跳过」（含内容相同时的专门文案），避免活动中心画成绿色让人误以为覆盖成功。
    private func transferOutcome(transferred: Int, skipped: Int, sameHashSkips: Int) -> OperationTask.Status {
        guard transferred == 0, skipped > 0 else { return .succeeded(nil) }
        let reason = sameHashSkips > 0
            ? L10n.text("tasks.fileOperation.skipped.sameHash")
            : L10n.text("tasks.fileOperation.skipped.noChange")
        return .skipped(reason)
    }

    private func transferSummary(from urls: [URL], to destination: URL?) -> String? {
        guard let destination else { return nil }
        return transferSummary(from: sourceSummary(urls), to: displayPath(destination))
    }

    private func transferSummary(from source: URL, to destination: URL) -> String {
        transferSummary(from: displayPath(source), to: displayPath(destination))
    }

    private func transferSummary(from urls: [URL], to destination: String) -> String {
        transferSummary(from: sourceSummary(urls), to: destination)
    }

    private func transferSummary(from source: String, to destination: String) -> String {
        L10n.format("tasks.fileOperation.summary", source, destination)
    }

    private func sourceSummary(_ urls: [URL]) -> String {
        guard urls.count != 1 else {
            return urls[0].lastPathComponent
        }
        return L10n.format("tasks.itemCount", urls.count)
    }

    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func statusText(for outcome: OperationTask.Status) -> String {
        switch outcome {
        case .running:
            return L10n.text("tasks.running")
        case .succeeded:
            return L10n.text("status.done")
        case .skipped(let reason):
            return reason ?? L10n.text("tasks.fileOperation.skipped.noChange")
        case .failed(let message):
            return message
        case .cancelled:
            return L10n.text("status.cancelled")
        }
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
}

/// 操作反馈音。系统音文件路径多年稳定；缓存一份 `NSSound` 复用（`byReference` 不把音频读进内存）。
/// 文件缺失（极旧 / 极新系统）则为 nil、静默不响。
enum SystemSound {
    /// 「移到废纸篓」音效 —— `FileManager.trashItem` 本身**不出声**，删除要响必须显式播。
    /// 这个 Finder 系统音本身就是「whoosh + 落下」两段，听起来像两声，但只是一次播放、不是重复触发。
    static let moveToTrash: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true
    )
    /// 操作成功完成的提示音（粘贴 / 移动 / 创建副本 / 创建压缩包 / 解压等）。
    /// 用系统 Pop（轻柔、不刺耳）—— 之前的 Glass 太像通知音、用于粘贴这类操作显得突兀（用户反馈）。
    static let operationComplete: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Sounds/Pop.aiff",
        byReference: true
    )
}
