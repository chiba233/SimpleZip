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

    /// 删除选中项后，键盘光标应落到的「邻居」URL。
    /// 取 fileItems 顺序里**第一个被删项的前一项**（一定是幸存项）；若删的就是开头，则取被删之后第一个幸存项。
    /// 全删空 / 算不出 → nil。用 fileItems（模型排序顺序）近似视觉顺序，符合「回到上一个文件」的直觉。
    private func selectionNeighborURL(removing removedIDs: Set<UUID>) -> URL? {
        guard let firstIdx = fileItems.firstIndex(where: { removedIDs.contains($0.id) }) else { return nil }
        if firstIdx > 0 { return fileItems[firstIdx - 1].url }
        return fileItems[(firstIdx + 1)...].first(where: { !removedIDs.contains($0.id) })?.url
    }

    func deleteSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        if AppPreferences.confirmBeforeDeletingFiles {
            guard confirmDelete(items: selectedFileItems) else { return }
        }

        // 删除前先算好「光标该落到哪」—— 用删除前的 fileItems 顺序，删成功后置 pendingSelectionURL，
        // FileTable 刷新后会选中它并把键盘焦点交回表格（删一项后方向键从邻居继续，不回顶端）。
        let neighborURL = selectionNeighborURL(removing: Set(selectedFileItems.map(\.id)))

        // 删除前记下每项是否目录 —— 用于活动中心逐文件「已删除」记录里加「（文件夹）」后缀。
        let isDirectoryByPath = Dictionary(
            selectedFileItems.map { ($0.url.standardizedFileURL.path, $0.isDirectory) },
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
            for item in selectedFileItems {
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
            // 刷新交给 FolderWatcher：从当前文件夹移除条目会触发 FSEvents 自动 reload。
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
            // 失败时仍把已经成功移走的那些列进逐文件记录（best-effort，不假装全删了）。
            recordInstantFileTask(
                kind: .delete,
                title: L10n.format("tasks.deleteCount", selectedFileItems.count),
                detail: transferSummary(from: selectedFileItems.map(\.url), to: L10n.text("tasks.trashDestination")),
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
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let copyWord = L10n.text("file.duplicate.suffix")
        func candidate(_ tail: String) -> URL {
            let stem = base + tail
            let name = ext.isEmpty ? stem : "\(stem).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var target = candidate(copyWord)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = candidate("\(copyWord) \(n)")
            n += 1
        }
        return target
    }

    private func uniqueNewItemURL(in folderURL: URL, preferredName: String) -> URL {
        let preferredURL = folderURL.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let ext = preferredURL.pathExtension
        let base = ext.isEmpty ? preferredName : (preferredName as NSString).deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folderURL.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
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
        cancellable: Bool
    ) -> OperationTask {
        // 复制/移动/粘贴不接文本 detailsSession：覆盖前的「源 vs 目标」哈希比对存到 task.hashComparisons，
        // 活动中心用格式化卡片渲染（而非命令输出文本）。没有冲突的平凡转移 → 无比对 → 不出详情入口。
        let task = TaskCenter.shared.begin(
            category: .fileOperation,
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

    private func recordInstantFileTask(
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
