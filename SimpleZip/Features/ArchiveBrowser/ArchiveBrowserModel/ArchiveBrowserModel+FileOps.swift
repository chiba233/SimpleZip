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
