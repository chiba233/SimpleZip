//
//  ArchiveExtractionCoordinator.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/13.
//

import AppKit
import Foundation

/// 负责处理解压后合并、同名冲突和哈希比对，避免主模型承载过多文件系统细节。
@MainActor
final class ArchiveExtractionCoordinator {
    private let fileManager: FileManager
    private var pendingHashOverwriteResults: [String: HashOverwriteResult] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let initialURL = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: initialURL.path) else { return initialURL }

        let baseURL = URL(fileURLWithPath: fileName)
        let name = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension

        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    func makeExtractionStagingDirectory() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-Extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func resolveDestination(
        for sourceURL: URL,
        requestedTargetURL: URL,
        defaultOverwriteBehavior: OverwriteBehavior? = nil,
        updateStatus: ((String) -> Void)? = nil,
        updateProgress: ((ArchiveProgressState) -> Void)? = nil
    ) async throws -> URL? {
        if sourceURL.standardizedFileURL == requestedTargetURL.standardizedFileURL {
            return nil
        }
        guard fileManager.fileExists(atPath: requestedTargetURL.path) else {
            return requestedTargetURL
        }

        if let defaultOverwriteBehavior {
            switch defaultOverwriteBehavior {
            case .overwrite:
                try trashExistingItem(at: requestedTargetURL)
                return requestedTargetURL
            case .skipExisting:
                return nil
            }
        }

        switch pasteConflictChoice(targetURL: requestedTargetURL) {
        case .replace:
            try trashExistingItem(at: requestedTargetURL)
            return requestedTargetURL
        case .keepBoth:
            return uniqueDestinationURL(for: sourceURL.lastPathComponent, in: requestedTargetURL.deletingLastPathComponent())
        case .skip:
            return nil
        case .replaceIfDifferent:
            let result = try await compareHashesForOverwrite(
                sourceURL: sourceURL,
                targetURL: requestedTargetURL,
                updateStatus: updateStatus,
                updateProgress: updateProgress
            )
            if result.isSame {
                showHashOverwriteResult(result)
                return nil
            }
            try trashExistingItem(at: requestedTargetURL)
            pendingHashOverwriteResults[requestedTargetURL.standardizedFileURL.path] = result
            return requestedTargetURL
        case .cancel:
            throw CocoaError(.userCancelled)
        }
    }

    func mergeExtractedItems(
        from stagingURL: URL,
        to destinationURL: URL,
        defaultOverwriteBehavior: OverwriteBehavior,
        updateStatus: @escaping (String) -> Void,
        updateProgress: @escaping (ArchiveProgressState) -> Void
    ) async throws {
        updateStatus(L10n.text("status.mergingExtractedFiles"))
        updateProgress(ArchiveProgressState(fraction: nil, currentFile: destinationURL.lastPathComponent))
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let extractedURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        for sourceURL in extractedURLs {
            try Task.checkCancellation()
            let targetURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try await mergeExtractedItem(
                sourceURL,
                to: targetURL,
                defaultOverwriteBehavior: defaultOverwriteBehavior,
                updateStatus: updateStatus,
                updateProgress: updateProgress
            )
        }
    }

    func showPendingHashOverwriteResult(for url: URL) {
        let key = url.standardizedFileURL.path
        guard let result = pendingHashOverwriteResults.removeValue(forKey: key) else { return }
        showHashOverwriteResult(result)
    }

    private func mergeExtractedItem(
        _ sourceURL: URL,
        to targetURL: URL,
        defaultOverwriteBehavior: OverwriteBehavior,
        updateStatus: @escaping (String) -> Void,
        updateProgress: @escaping (ArchiveProgressState) -> Void
    ) async throws {
        updateProgress(ArchiveProgressState(fraction: nil, currentFile: sourceURL.lastPathComponent))

        let sourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        let sourceIsDirectory = sourceValues.isDirectory == true
        var targetIsDirectory = ObjCBool(false)
        let targetExists = fileManager.fileExists(atPath: targetURL.path, isDirectory: &targetIsDirectory)

        if sourceIsDirectory, targetExists, targetIsDirectory.boolValue {
            let childURLs = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
            for childURL in childURLs {
                try Task.checkCancellation()
                try await mergeExtractedItem(
                    childURL,
                    to: targetURL.appendingPathComponent(childURL.lastPathComponent),
                    defaultOverwriteBehavior: defaultOverwriteBehavior,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress
                )
            }
            try? fileManager.removeItem(at: sourceURL)
            return
        }

        let resolvedURL = try await resolveDestination(
            for: sourceURL,
            requestedTargetURL: targetURL,
            defaultOverwriteBehavior: defaultOverwriteBehavior,
            updateStatus: updateStatus,
            updateProgress: updateProgress
        )
        guard let resolvedURL else { return }
        try fileManager.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: resolvedURL)
        showPendingHashOverwriteResult(for: resolvedURL)
    }

    private func pasteConflictChoice(targetURL: URL) -> PasteConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.pasteConflict.title", targetURL.lastPathComponent)
        alert.informativeText = L10n.text("confirm.pasteConflict.message")
        alert.addButton(withTitle: L10n.text("conflict.replace"))
        alert.addButton(withTitle: L10n.text("conflict.keepBoth"))
        alert.addButton(withTitle: L10n.text("conflict.skip"))
        alert.addButton(withTitle: L10n.text("conflict.replaceIfDifferent"))
        alert.addButton(withTitle: L10n.text("button.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .replace
        case .alertSecondButtonReturn:
            return .keepBoth
        case .alertThirdButtonReturn:
            return .skip
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            return .replaceIfDifferent
        default:
            return .cancel
        }
    }

    private func trashExistingItem(at url: URL) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private func compareHashesForOverwrite(
        sourceURL: URL,
        targetURL: URL,
        updateStatus: ((String) -> Void)?,
        updateProgress: ((ArchiveProgressState) -> Void)?
    ) async throws -> HashOverwriteResult {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let sourceValues = try sourceURL.resourceValues(forKeys: resourceKeys)
        let targetValues = try targetURL.resourceValues(forKeys: resourceKeys)
        guard sourceValues.isRegularFile == true, targetValues.isRegularFile == true else {
            return HashOverwriteResult(
                sourceURL: sourceURL,
                targetURL: targetURL,
                sourceHash: L10n.text("hash.notRegularFile"),
                targetHash: L10n.text("hash.notRegularFile"),
                isSame: false
            )
        }

        let progressPanel = makeHashProgressPanel()
        progressPanel.panel.makeKeyAndOrderFront(nil)
        defer { progressPanel.panel.close() }

        try Task.checkCancellation()
        updateStatus?(L10n.text("status.hashingForOverwrite"))
        updateProgress?(ArchiveProgressState(fraction: 0, currentFile: targetURL.lastPathComponent))
        updateHashProgressPanel(progressPanel, fraction: 0.1, fileName: targetURL.lastPathComponent, labelKey: "hashOverwrite.progress.existing")
        let targetHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: targetURL) }.value

        try Task.checkCancellation()
        updateProgress?(ArchiveProgressState(fraction: 0.5, currentFile: sourceURL.lastPathComponent))
        updateHashProgressPanel(progressPanel, fraction: 0.55, fileName: sourceURL.lastPathComponent, labelKey: "hashOverwrite.progress.incoming")
        let sourceHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: sourceURL) }.value

        updateProgress?(ArchiveProgressState(fraction: 1, currentFile: nil))
        updateHashProgressPanel(progressPanel, fraction: 1, fileName: "", labelKey: "status.done")
        return HashOverwriteResult(sourceURL: sourceURL, targetURL: targetURL, sourceHash: sourceHash, targetHash: targetHash, isSame: sourceHash == targetHash)
    }

    private func makeHashProgressPanel() -> HashProgressPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("hashOverwrite.progress.title")
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L10n.text("status.hashingForOverwrite"))
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2

        let progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(label)
        stackView.addArrangedSubview(progressIndicator)

        let contentView = NSView()
        contentView.addSubview(stackView)
        panel.contentView = contentView
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            progressIndicator.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
        panel.center()
        return HashProgressPanel(panel: panel, label: label, progressIndicator: progressIndicator)
    }

    private func updateHashProgressPanel(_ progressPanel: HashProgressPanel, fraction: Double, fileName: String, labelKey: String) {
        progressPanel.progressIndicator.doubleValue = fraction
        if fileName.isEmpty {
            progressPanel.label.stringValue = L10n.text(labelKey)
        } else {
            progressPanel.label.stringValue = L10n.format(labelKey, fileName)
        }
        progressPanel.panel.displayIfNeeded()
    }

    private func showHashOverwriteResult(_ result: HashOverwriteResult) {
        let alert = NSAlert()
        alert.alertStyle = result.isSame ? .informational : .warning
        alert.messageText = result.isSame ? L10n.text("hashOverwrite.same.title") : L10n.text("hashOverwrite.different.title")
        alert.informativeText = L10n.format(
            result.isSame ? "hashOverwrite.same.message" : "hashOverwrite.different.message",
            result.targetURL.lastPathComponent,
            result.targetHash,
            result.sourceURL.lastPathComponent,
            result.sourceHash
        )
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.runModal()
    }
}

private enum PasteConflictChoice {
    case replace
    case keepBoth
    case skip
    case replaceIfDifferent
    case cancel
}

private struct HashOverwriteResult {
    let sourceURL: URL
    let targetURL: URL
    let sourceHash: String
    let targetHash: String
    let isSame: Bool
}

private struct HashProgressPanel {
    let panel: NSPanel
    let label: NSTextField
    let progressIndicator: NSProgressIndicator
}
