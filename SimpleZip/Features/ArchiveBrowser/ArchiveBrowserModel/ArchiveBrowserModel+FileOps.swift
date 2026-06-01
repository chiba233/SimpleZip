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
                var undoPairs: [(URL, URL)] = []
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
                    undoPairs.append((url, targetURL))
                    extractionCoordinator.showPendingHashOverwriteResult(for: targetURL)
                }
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                if fileClipboard.shouldMove {
                    registerMoveUndo(undoPairs.map { (from: $0.0, to: $0.1) }, actionName: L10n.text("undo.action.move"))
                    self.fileClipboard = nil
                } else {
                    registerCopyUndo(undoPairs.map { (source: $0.0, dest: $0.1) }, actionName: L10n.text("undo.action.copy"))
                }
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: total, totalUnitCount: total)
                SystemSound.operationComplete?.play()
                // 刷新交给 FolderWatcher：写入当前文件夹会触发 FSEvents 自动 reload。
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
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
            // 刷新交给 FolderWatcher：同目录改名会触发 FSEvents 自动 reload。
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
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

    func deleteSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        if AppPreferences.confirmBeforeDeletingFiles {
            guard confirmDelete(items: selectedFileItems) else { return }
        }

        do {
            var trashed: [(original: URL, trashURL: URL)] = []
            for item in selectedFileItems {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as URL? {
                    trashed.append((original: item.url, trashURL: trashURL))
                }
            }
            // 撤销 = 从废纸篓移回原位；重做 = 移回废纸篓那个路径。
            registerTrashUndo(trashed, actionName: L10n.text("undo.action.delete"))
            // 复刻 Finder：移到废纸篓后播放系统「move to trash」音效。
            SystemSound.moveToTrash?.play()
            // 刷新交给 FolderWatcher：从当前文件夹移除条目会触发 FSEvents 自动 reload。
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    /// 「创建副本」—— Finder 式：在同目录复制成「<名字> 副本[.ext]」，重名再「<名字> 副本 2」…
    /// 刷新交给 FolderWatcher（新文件落在当前目录会触发 FSEvents）。
    func duplicateSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        do {
            var copies: [(source: URL, dest: URL)] = []
            for item in selectedFileItems {
                let dest = duplicateDestinationURL(for: item.url)
                try fileManager.copyItem(at: item.url, to: dest)
                copies.append((source: item.url, dest: dest))
            }
            registerCopyUndo(copies, actionName: L10n.text("undo.action.duplicate"))
            SystemSound.operationComplete?.play()
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
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
                var undoPairs: [(URL, URL)] = []
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
                    undoPairs.append((url, targetURL))
                    extractionCoordinator.showPendingHashOverwriteResult(for: targetURL)
                }
                extractionCoordinator.finishConflictResolutionSession(conflictSession)
                if shouldMove {
                    registerMoveUndo(undoPairs.map { (from: $0.0, to: $0.1) }, actionName: L10n.text("undo.action.move"))
                } else {
                    registerCopyUndo(undoPairs.map { (source: $0.0, dest: $0.1) }, actionName: L10n.text("undo.action.copy"))
                }
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: total, totalUnitCount: total)
                status = L10n.text("status.done")
                SystemSound.operationComplete?.play()
                // 刷新交给 FolderWatcher：拖入 / 拖出当前文件夹都会触发 FSEvents 自动 reload，
                // 不必再手动判断 destination 是否等于当前目录。
            } catch is CancellationError {
                errorMessage = nil
                status = L10n.text("status.cancelled")
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
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

/// 复刻 Finder 反馈音的系统音效。系统音文件路径多年稳定；缓存一份 `NSSound` 复用
/// （`byReference` 不把音频读进内存）。文件缺失（极旧 / 极新系统）则为 nil，静默不响。
enum SystemSound {
    static let moveToTrash: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true
    )
    /// 操作成功完成的提示音（粘贴 / 移动 / 创建副本 / 创建压缩包 / 解压等）。
    /// 用系统 Glass 提示音；文件缺失则 nil、静默。
    static let operationComplete: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Sounds/Glass.aiff",
        byReference: true
    )
}
