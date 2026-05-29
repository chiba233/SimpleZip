//
//  ArchiveExtractionCoordinator.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/13.
//

import AppKit
import CryptoKit
import Foundation
import SwiftUI

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
        targetRootURL: URL? = nil,
        defaultOverwriteBehavior: OverwriteBehavior? = nil,
        updateStatus: ((String) -> Void)? = nil,
        updateProgress: ((ArchiveProgressState) -> Void)? = nil,
        conflictSession: ConflictResolutionSession? = nil
    ) async throws -> URL? {
        if sourceURL.standardizedFileURL == requestedTargetURL.standardizedFileURL {
            return nil
        }
        if let targetRootURL {
            try validateContainedURL(requestedTargetURL, in: targetRootURL)
        }
        guard fileManager.fileExists(atPath: requestedTargetURL.path) else {
            return requestedTargetURL
        }

        if let defaultOverwriteBehavior {
            switch defaultOverwriteBehavior {
            case .ask:
                break
            case .overwrite:
                try trashExistingItem(at: requestedTargetURL)
                return requestedTargetURL
            case .skipExisting:
                return nil
            case .replaceIfDifferent:
                let result = try await compareItemsForOverwrite(
                    sourceURL: sourceURL,
                    targetURL: requestedTargetURL,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress
                )
                recordHashOverwriteResult(result, in: conflictSession)
                if result.isSame {
                    showHashOverwriteResultIfNeeded(result, session: conflictSession)
                    return nil
                }
                try trashExistingItem(at: requestedTargetURL)
                if conflictSession == nil {
                    pendingHashOverwriteResults[requestedTargetURL.standardizedFileURL.path] = result
                }
                return requestedTargetURL
            }
        }

        let choice = conflictSession?.rememberedChoice ?? pasteConflictChoice(targetURL: requestedTargetURL, conflictSession: conflictSession)
        switch choice {
        case .replace:
            try trashExistingItem(at: requestedTargetURL)
            return requestedTargetURL
        case .skip:
            return nil
        case .replaceIfDifferent:
            let result = try await compareItemsForOverwrite(
                sourceURL: sourceURL,
                targetURL: requestedTargetURL,
                updateStatus: updateStatus,
                updateProgress: updateProgress
            )
            recordHashOverwriteResult(result, in: conflictSession)
            if result.isSame {
                showHashOverwriteResultIfNeeded(result, session: conflictSession)
                return nil
            }
            try trashExistingItem(at: requestedTargetURL)
            if conflictSession == nil {
                pendingHashOverwriteResults[requestedTargetURL.standardizedFileURL.path] = result
            }
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
        let conflictSession = ConflictResolutionSession()
        updateStatus(L10n.text("status.mergingExtractedFiles"))
        updateProgress(ArchiveProgressState(fraction: nil, currentFile: destinationURL.lastPathComponent))
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let unsafeLinks = try ArchiveSafety.unsafeLinks(in: stagingURL, fileManager: fileManager)
        if !unsafeLinks.isEmpty, !confirmUnsafeArchiveLinks(unsafeLinks) {
            throw CocoaError(.userCancelled)
        }

        let extractedURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        for sourceURL in extractedURLs {
            try Task.checkCancellation()
            try validateContainedURL(sourceURL, in: stagingURL)
            let targetURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try await mergeExtractedItem(
                sourceURL,
                to: targetURL,
                stagingRootURL: stagingURL,
                destinationRootURL: destinationURL,
                defaultOverwriteBehavior: defaultOverwriteBehavior,
                updateStatus: updateStatus,
                updateProgress: updateProgress,
                conflictSession: conflictSession
            )
        }
        showHashOverwriteSummaryIfNeeded(conflictSession)
    }

    func showPendingHashOverwriteResult(for url: URL) {
        let key = url.standardizedFileURL.path
        guard let result = pendingHashOverwriteResults.removeValue(forKey: key) else { return }
        showHashOverwriteResult(result)
    }

    private func mergeExtractedItem(
        _ sourceURL: URL,
        to targetURL: URL,
        stagingRootURL: URL,
        destinationRootURL: URL,
        defaultOverwriteBehavior: OverwriteBehavior,
        updateStatus: @escaping (String) -> Void,
        updateProgress: @escaping (ArchiveProgressState) -> Void,
        conflictSession: ConflictResolutionSession
    ) async throws {
        updateProgress(ArchiveProgressState(fraction: nil, currentFile: sourceURL.lastPathComponent))
        try validateContainedURL(sourceURL, in: stagingRootURL)
        try validateResolvedContainedMovableItem(sourceURL, in: stagingRootURL)
        try validateContainedURL(targetURL, in: destinationRootURL)

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
                    stagingRootURL: stagingRootURL,
                    destinationRootURL: destinationRootURL,
                    defaultOverwriteBehavior: defaultOverwriteBehavior,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress,
                    conflictSession: conflictSession
                )
            }
            try? fileManager.removeItem(at: sourceURL)
            return
        }

        let resolvedURL = try await resolveDestination(
            for: sourceURL,
            requestedTargetURL: targetURL,
            targetRootURL: destinationRootURL,
            defaultOverwriteBehavior: defaultOverwriteBehavior,
            updateStatus: updateStatus,
            updateProgress: updateProgress,
            conflictSession: conflictSession
        )
        guard let resolvedURL else { return }
        try validateContainedURL(resolvedURL, in: destinationRootURL)
        let parentURL = resolvedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try validateContainedURL(parentURL, in: destinationRootURL)
        try validateResolvedContainedURL(parentURL, in: destinationRootURL)
        try fileManager.moveItem(at: sourceURL, to: resolvedURL)
        showPendingHashOverwriteResult(for: resolvedURL)
    }

    private func validateContainedURL(_ url: URL, in rootURL: URL) throws {
        try validateContainedPath(url.standardizedFileURL, in: rootURL.standardizedFileURL, displayPath: url.path)
    }

    private func validateResolvedContainedMovableItem(_ url: URL, in rootURL: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return }
        try validateResolvedContainedURL(url, in: rootURL)
    }

    private func validateResolvedContainedURL(_ url: URL, in rootURL: URL) throws {
        try validateContainedPath(
            url.resolvingSymlinksInPath().standardizedFileURL,
            in: rootURL.resolvingSymlinksInPath().standardizedFileURL,
            displayPath: url.path
        )
    }

    private func validateContainedPath(_ url: URL, in rootURL: URL, displayPath: String) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw ArchiveError.unsafeArchiveEntries([displayPath])
        }
    }

    func makeConflictResolutionSession() -> ConflictResolutionSession {
        ConflictResolutionSession()
    }

    func finishConflictResolutionSession(_ conflictSession: ConflictResolutionSession) {
        showHashOverwriteSummaryIfNeeded(conflictSession)
    }

    private func pasteConflictChoice(targetURL: URL, conflictSession: ConflictResolutionSession?) -> PasteConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.pasteConflict.title", targetURL.lastPathComponent)
        alert.informativeText = L10n.text("confirm.pasteConflict.message")
        alert.addButton(withTitle: L10n.text("conflict.replace"))
        alert.addButton(withTitle: L10n.text("conflict.skip"))
        alert.addButton(withTitle: L10n.text("conflict.replaceIfDifferent"))
        alert.addButton(withTitle: L10n.text("button.cancel"))

        let rememberButton = NSButton(checkboxWithTitle: L10n.text("conflict.rememberForOperation"), target: nil, action: nil)
        rememberButton.state = .off
        alert.accessoryView = rememberButton

        let choice: PasteConflictChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            choice = .replace
        case .alertSecondButtonReturn:
            choice = .skip
        case .alertThirdButtonReturn:
            choice = .replaceIfDifferent
        default:
            choice = .cancel
        }
        if rememberButton.state == .on, choice != .cancel {
            conflictSession?.rememberedChoice = choice
        }
        return choice
    }

    private func confirmUnsafeArchiveLinks(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveLinks.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveLinks.message", Array(names.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func trashExistingItem(at url: URL) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private func compareItemsForOverwrite(
        sourceURL: URL,
        targetURL: URL,
        updateStatus: ((String) -> Void)?,
        updateProgress: ((ArchiveProgressState) -> Void)?
    ) async throws -> HashOverwriteResult {
        let progressPanel = makeHashProgressPanel()
        progressPanel.panel.makeKeyAndOrderFront(nil)
        defer { progressPanel.panel.close() }

        try Task.checkCancellation()
        updateStatus?(L10n.text("status.hashingForOverwrite"))
        updateProgress?(ArchiveProgressState(fraction: 0, currentFile: targetURL.lastPathComponent))
        updateHashProgressPanel(progressPanel, fraction: 0.1, fileName: targetURL.lastPathComponent, labelKey: "hashOverwrite.progress.existing")
        let targetSnapshot = try await comparableSnapshot(for: targetURL)

        try Task.checkCancellation()
        updateProgress?(ArchiveProgressState(fraction: 0.5, currentFile: sourceURL.lastPathComponent))
        updateHashProgressPanel(progressPanel, fraction: 0.55, fileName: sourceURL.lastPathComponent, labelKey: "hashOverwrite.progress.incoming")
        let sourceSnapshot = try await comparableSnapshot(for: sourceURL)

        updateProgress?(ArchiveProgressState(fraction: 1, currentFile: nil))
        updateHashProgressPanel(progressPanel, fraction: 1, fileName: "", labelKey: "status.done")
        return HashOverwriteResult(
            sourceURL: sourceURL,
            targetURL: targetURL,
            sourceHash: sourceSnapshot.displayValue,
            targetHash: targetSnapshot.displayValue,
            isSame: sourceSnapshot == targetSnapshot
        )
    }

    private func comparableSnapshot(for url: URL) async throws -> OverwriteComparableSnapshot {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: resourceKeys)

        if values.isSymbolicLink == true {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            return .symbolicLink(destination: destination)
        }

        if values.isRegularFile == true {
            let hash = try await Task.detached(priority: .userInitiated) {
                try HashService.sha256(for: url)
            }.value
            return .regularFile(sha256: hash)
        }

        if values.isDirectory == true {
            let fileManager = self.fileManager
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                try Self.directoryFingerprint(for: url, fileManager: fileManager)
            }.value
            return .directory(fingerprint: fingerprint)
        }

        return .other(kind: L10n.text("hash.notRegularFile"))
    }

    nonisolated private static func directoryFingerprint(for rootURL: URL, fileManager: FileManager) throws -> String {
        var entries: [String] = []
        let rootPath = rootURL.standardizedFileURL.path
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else {
            return "directory:empty"
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else {
                throw ArchiveError.unsafeArchiveEntries([url.path])
            }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            let values = try url.resourceValues(forKeys: Set(resourceKeys))

            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                entries.append("link:\(relativePath):\(destination)")
            } else if values.isRegularFile == true {
                let hash = try HashService.sha256(for: url)
                entries.append("file:\(relativePath):\(hash)")
            } else if values.isDirectory == true {
                entries.append("dir:\(relativePath)")
            } else {
                entries.append("other:\(relativePath)")
            }
        }

        let joinedEntries = entries.sorted().joined(separator: "\n")
        let data = Data(joinedEntries.utf8)
        return HashService.hex(SHA256.hash(data: data))
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

    private func recordHashOverwriteResult(_ result: HashOverwriteResult, in conflictSession: ConflictResolutionSession?) {
        conflictSession?.hashResults.append(result)
    }

    private func showHashOverwriteResultIfNeeded(_ result: HashOverwriteResult, session: ConflictResolutionSession?) {
        guard session == nil else { return }
        showHashOverwriteResult(result)
    }

    private func showHashOverwriteSummaryIfNeeded(_ conflictSession: ConflictResolutionSession) {
        let results = conflictSession.hashResults
        guard results.count > 1 else {
            if let result = results.first {
                showHashOverwriteResult(result)
            }
            return
        }

        let sameCount = results.filter(\.isSame).count
        let differentCount = results.count - sameCount
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("hashOverwrite.summary.title")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 360)
        panel.contentViewController = NSHostingController(
            rootView: HashOverwriteSummaryView(
                results: results,
                sameCount: sameCount,
                differentCount: differentCount
            ) {
                NSApp.stopModal()
                panel.close()
            }
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
    }
}

final class ConflictResolutionSession {
    var rememberedChoice: PasteConflictChoice?
    var hashResults: [HashOverwriteResult] = []
}

enum PasteConflictChoice: Equatable {
    case replace
    case skip
    case replaceIfDifferent
    case cancel
}

struct HashOverwriteResult {
    let sourceURL: URL
    let targetURL: URL
    let sourceHash: String
    let targetHash: String
    let isSame: Bool
}

private struct HashOverwriteSummaryView: View {
    let results: [HashOverwriteResult]
    let sameCount: Int
    let differentCount: Int
    let close: () -> Void

    private var replacedResults: [HashOverwriteResult] {
        results.filter { !$0.isSame }
    }

    private var skippedResults: [HashOverwriteResult] {
        results.filter(\.isSame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("hashOverwrite.summary.title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L10n.format("hashOverwrite.summary.message", sameCount, differentCount))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !replacedResults.isEmpty {
                            HashOverwriteSummaryGroup(
                                title: L10n.text("hashOverwrite.summary.section.replaced"),
                                count: differentCount,
                                results: replacedResults
                            )
                        }
                        if !skippedResults.isEmpty {
                            HashOverwriteSummaryGroup(
                                title: L10n.text("hashOverwrite.summary.section.skipped"),
                                count: sameCount,
                                results: skippedResults
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25))
            }

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 480)
    }
}

private struct HashOverwriteSummaryGroup: View {
    let title: String
    let count: Int
    let results: [HashOverwriteResult]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.format("hashOverwrite.summary.section.title", title, count))
                        .font(.callout)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor))

                HStack(spacing: 12) {
                    Text(L10n.text("hashOverwrite.summary.column.file"))
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("hashOverwrite.summary.column.existingHash"))
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("hashOverwrite.summary.column.incomingHash"))
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08))
            }

            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                HashOverwriteSummaryRow(result: result)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
            }
        }
    }
}

private struct HashOverwriteSummaryRow: View {
    let result: HashOverwriteResult

    var body: some View {
        HStack(spacing: 12) {
            Text(result.targetURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.targetURL.path)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(result.targetHash)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.targetHash)
                .foregroundStyle(.secondary)
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            Text(result.sourceHash)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.sourceHash)
                .foregroundStyle(.secondary)
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private enum OverwriteComparableSnapshot: Equatable {
    case regularFile(sha256: String)
    case symbolicLink(destination: String)
    case directory(fingerprint: String)
    case other(kind: String)

    var displayValue: String {
        switch self {
        case .regularFile(let sha256):
            return sha256
        case .symbolicLink(let destination):
            return "symbolic link -> \(destination)"
        case .directory(let fingerprint):
            return "directory fingerprint \(fingerprint)"
        case .other(let kind):
            return kind
        }
    }
}

private struct HashProgressPanel {
    let panel: NSPanel
    let label: NSTextField
    let progressIndicator: NSProgressIndicator
}
