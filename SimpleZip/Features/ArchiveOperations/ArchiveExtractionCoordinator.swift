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
    private var recentHashOverwriteResults: [String: HashOverwriteResult] = [:]

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

        let choice = conflictSession?.rememberedChoice ?? conflictChoice(targetURL: requestedTargetURL, isDirectory: false, conflictSession: conflictSession)
        // resolveDestination 只解决文件级（或整体）冲突；文件夹深度合并在 transferItem 拦截。
        // 因此这里把 .merge 当作 .replace、.mergeIfDifferent 当作 .replaceIfDifferent 处理。
        switch choice {
        case .replace, .merge:
            try trashExistingItem(at: requestedTargetURL)
            return requestedTargetURL
        case .skip:
            return nil
        case .replaceIfDifferent, .mergeIfDifferent:
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

    /// 复制 / 移动 / 拖放共用的统一传输入口。
    /// - 目标不存在 → 直接 copy/move。
    /// - 源是文件夹且目标是同名文件夹（且为交互式 `.ask`）→ 弹冲突对话框：可选「合并 / 整体替换」×「仅哈希不同时覆盖」。
    ///   合并＝深度递归（像普通文件系统的 `cp -r`），保留目标里多余的文件、对同名项执行所选覆盖策略，不整体移废纸篓。
    /// - 其余冲突（文件 vs 文件、目录 vs 文件等）→ 复用现有 `resolveDestination`。
    ///
    /// `recordPair(src, dst)` 每次实际写入后回调，调用方据此注册撤销（合并时按真实写入子项逐个登记，
    /// 撤销复制只删写进目标的子项、不动目标原有文件）。`recordHashComparison` 转发覆盖前的源/目标哈希比对。
    func transferItem(
        source: URL,
        requestedTarget: URL,
        isMove: Bool,
        defaultOverwriteBehavior: OverwriteBehavior?,
        conflictSession: ConflictResolutionSession?,
        updateStatus: ((String) -> Void)? = nil,
        updateProgress: ((ArchiveProgressState) -> Void)? = nil,
        recordPair: (URL, URL) -> Void,
        recordHashComparison: (HashOverwriteResult) -> Void
    ) async throws -> TransferStats {
        var stats = TransferStats()
        let name = requestedTarget.lastPathComponent
        let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

        // 源 == 目标（如把剪贴板粘贴回原文件夹）→ 视为无操作的跳过，绝不自我覆盖。
        if source.standardizedFileURL == requestedTarget.standardizedFileURL {
            stats.skipped += 1
            conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .skipped, isDirectory: sourceIsDirectory))
            return stats
        }

        var targetIsDirectory = ObjCBool(false)
        let targetExists = fileManager.fileExists(atPath: requestedTarget.path, isDirectory: &targetIsDirectory)
        let effectiveBehavior = defaultOverwriteBehavior ?? .ask

        // 文件夹 vs 同名文件夹，且为交互式询问 → 提供「合并 / 整体替换」×「仅哈希不同时覆盖」。
        // 非 .ask 偏好（用户已显式选「总是覆盖 / 跳过」）保持旧的整体行为，交给下方 resolveDestination。
        if sourceIsDirectory, targetExists, targetIsDirectory.boolValue, effectiveBehavior == .ask {
            let choice = conflictSession?.rememberedChoice
                ?? conflictChoice(targetURL: requestedTarget, isDirectory: true, conflictSession: conflictSession)
            switch choice {
            case .merge, .mergeIfDifferent:
                // 合并：深度递归。子文件冲突由 mergeDirectory 逐个询问（或用 rememberedChoice）。
                // 注意：若用户在文件夹对话框勾了「仅哈希不同时」但没勾「应用到全部」，该修饰符不会传给子项——
                // 子项会各自重新弹窗，用户在子项对话框里自行选择（含「应用到全部」）。
                let childStats = try await mergeDirectory(
                    source: source,
                    target: requestedTarget,
                    isMove: isMove,
                    conflictSession: conflictSession,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress,
                    recordPair: recordPair,
                    recordHashComparison: recordHashComparison
                )
                stats.merge(childStats)
                return stats
            case .replace:
                try trashExistingItem(at: requestedTarget)
                try await performTransfer(source: source, target: requestedTarget, isMove: isMove)
                recordPair(source, requestedTarget)
                stats.transferred += 1
                conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .overwritten, isDirectory: true))
                return stats
            case .replaceIfDifferent:
                // 整体替换：比对目录指纹，相同则跳过，不同才整体替换。
                let resolved = try await resolveDestination(
                    for: source,
                    requestedTargetURL: requestedTarget,
                    defaultOverwriteBehavior: .replaceIfDifferent,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress,
                    conflictSession: conflictSession
                )
                if let result = consumeHashOverwriteResult(for: requestedTarget) {
                    recordHashComparison(result)
                    if resolved == nil, result.isSame { stats.sameHashSkips += 1 }
                }
                guard let resolved else {
                    stats.skipped += 1
                    conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .skipped, isDirectory: true))
                    return stats
                }
                try await performTransfer(source: source, target: resolved, isMove: isMove)
                recordPair(source, resolved)
                stats.transferred += 1
                conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .overwritten, isDirectory: true))
                return stats
            case .skip:
                stats.skipped += 1
                conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .skipped, isDirectory: true))
                return stats
            case .cancel:
                throw CocoaError(.userCancelled)
            }
        }

        // 文件冲突 / 目录 vs 文件 / 无冲突 → 复用现有 resolveDestination。
        let resolved = try await resolveDestination(
            for: source,
            requestedTargetURL: requestedTarget,
            defaultOverwriteBehavior: defaultOverwriteBehavior,
            updateStatus: updateStatus,
            updateProgress: updateProgress,
            conflictSession: conflictSession
        )
        if let result = consumeHashOverwriteResult(for: requestedTarget) {
            recordHashComparison(result)
            if resolved == nil, result.isSame {
                stats.sameHashSkips += 1
            }
        }
        guard let resolved else {
            stats.skipped += 1
            conflictSession?.transferLog.append(TransferLogEntry(name: name, action: .skipped, isDirectory: sourceIsDirectory))
            return stats
        }
        try await performTransfer(source: source, target: resolved, isMove: isMove)
        recordPair(source, resolved)
        showPendingHashOverwriteResult(for: resolved)
        stats.transferred += 1
        conflictSession?.transferLog.append(TransferLogEntry(name: name, action: targetExists ? .overwritten : .added, isDirectory: sourceIsDirectory))
        return stats
    }

    /// 深度递归合并：源目录的每个子项落到目标同名位置。
    /// - 子项是「目录 vs 同名目录」→ 递归继续合并。子文件夹**本身不弹**文件夹级「合并/替换」对话框
    ///   （深合并语义），但它里面的同名文件该问还是问 —— 嵌套多少层都一样。
    /// - 同名**文件**冲突 → 走 `resolveDestination(.ask)`：用 `conflictSession.rememberedChoice`
    ///   （仅当用户勾过「应用到全部」）或**逐个弹窗**询问。没勾就一个个问，任何深度都不豁免、绝不静默统一处理。
    /// - 完全无冲突的文件（目标缺该项）→ 唯一豁免：`resolveDestination` 直接返回目标、不弹窗，原样写入。
    /// 目标里源没有的多余文件全部保留。move 语义下子项搬空后删掉空的源目录。
    private func mergeDirectory(
        source: URL,
        target: URL,
        isMove: Bool,
        conflictSession: ConflictResolutionSession?,
        updateStatus: ((String) -> Void)?,
        updateProgress: ((ArchiveProgressState) -> Void)?,
        recordPair: (URL, URL) -> Void,
        recordHashComparison: (HashOverwriteResult) -> Void
    ) async throws -> TransferStats {
        var stats = TransferStats()
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        updateProgress?(ArchiveProgressState(fraction: nil, currentFile: target.lastPathComponent))

        let children = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
        }.value

        for child in children {
            try Task.checkCancellation()
            let childTarget = target.appendingPathComponent(child.lastPathComponent)
            let childIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var childTargetIsDirectory = ObjCBool(false)
            let childTargetExists = fileManager.fileExists(atPath: childTarget.path, isDirectory: &childTargetIsDirectory)

            if childIsDirectory, childTargetExists, childTargetIsDirectory.boolValue {
                // 目录 vs 同名目录 → 继续深合并（不重复询问子文件夹）。
                let nested = try await mergeDirectory(
                    source: child,
                    target: childTarget,
                    isMove: isMove,
                    conflictSession: conflictSession,
                    updateStatus: updateStatus,
                    updateProgress: updateProgress,
                    recordPair: recordPair,
                    recordHashComparison: recordHashComparison
                )
                stats.merge(nested)
                continue
            }

            // 子文件冲突 / 目标缺该项 → resolveDestination(.ask)：
            // 目标缺该项直接返回；冲突则用 rememberedChoice 或逐个弹窗。
            let childName = child.lastPathComponent
            let resolved = try await resolveDestination(
                for: child,
                requestedTargetURL: childTarget,
                defaultOverwriteBehavior: nil,
                updateStatus: updateStatus,
                updateProgress: updateProgress,
                conflictSession: conflictSession
            )
            if let result = consumeHashOverwriteResult(for: childTarget) {
                recordHashComparison(result)
                if resolved == nil, result.isSame { stats.sameHashSkips += 1 }
            }
            guard let resolved else {
                stats.skipped += 1
                conflictSession?.transferLog.append(TransferLogEntry(name: childName, action: .skipped, isDirectory: childIsDirectory))
                continue
            }
            try await performTransfer(source: child, target: resolved, isMove: isMove)
            recordPair(child, resolved)
            stats.transferred += 1
            conflictSession?.transferLog.append(TransferLogEntry(name: childName, action: childTargetExists ? .overwritten : .added, isDirectory: childIsDirectory))
        }

        // move 语义：子项搬空后删掉空的源目录；非空（有跳过项）则保留，避免误删数据。
        if isMove, (try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fileManager.removeItem(at: source)
        }
        return stats
    }

    private func performTransfer(source: URL, target: URL, isMove: Bool) async throws {
        // 实际写入（可能跨卷逐文件拷贝或大子树）放后台线程，别堵主线程。
        try await Task.detached(priority: .userInitiated) {
            if isMove {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }.value
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
        // 整棵解压树的符号链接扫描放后台线程 —— 几万文件时在主线程走会卡死 GUI（Thread 1 main-thread 阻塞）。
        let unsafeLinks = try await Task.detached(priority: .userInitiated) {
            try ArchiveSafety.unsafeLinks(in: stagingURL, fileManager: .default)
        }.value
        if !unsafeLinks.isEmpty, !confirmUnsafeArchiveLinks(unsafeLinks) {
            throw CocoaError(.userCancelled)
        }

        let extractedURLs = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.contentsOfDirectory(
                at: stagingURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
        }.value

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

    func consumeHashOverwriteResult(for url: URL) -> HashOverwriteResult? {
        let key = url.standardizedFileURL.path
        return recentHashOverwriteResults.removeValue(forKey: key)
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
            let childURLs = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: []
                )
            }.value
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
        // 实际移动（可能是跨卷的逐文件拷贝，或大子树）放后台线程，别堵主线程。
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: sourceURL, to: resolvedURL)
        }.value
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

    func makeConflictResolutionSession(allowsRememberedChoice: Bool = true) -> ConflictResolutionSession {
        ConflictResolutionSession(allowsRememberedChoice: allowsRememberedChoice)
    }

    func finishConflictResolutionSession(_ conflictSession: ConflictResolutionSession) {
        showHashOverwriteSummaryIfNeeded(conflictSession)
    }

    /// 紧凑冲突对话框（自绘 SwiftUI，复用本文件哈希汇总弹窗那套 NSPanel + NSHostingController + runModal）。
    /// 默认（不勾任何项，直接「继续」）＝ Finder 式深度合并：保留目标里多余的文件、只处理同名项。
    /// 勾「替换整个文件夹」改为整体替换（丢弃目标里多余的文件）。
    /// 勾「仅当内容不同时才覆盖」是个修饰符，对合并与替换都生效。
    /// 文件（非文件夹）冲突不显示「替换整个文件夹」（合并对文件无意义，「继续」即覆盖）。
    private func conflictChoice(targetURL: URL, isDirectory: Bool, conflictSession: ConflictResolutionSession?) -> PasteConflictChoice {
        var result: PasteConflictChoice = .cancel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = ""

        let rootView = ConflictResolutionView(
            fileName: targetURL.lastPathComponent,
            isDirectory: isDirectory,
            allowsRememberedChoice: conflictSession?.allowsRememberedChoice == true
        ) { choice, rememberForAll in
            result = choice
            if rememberForAll, choice != .cancel {
                conflictSession?.rememberedChoice = choice
            }
            NSApp.stopModal()
            panel.close()
        }

        let hosting = NSHostingController(rootView: rootView)
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        return result
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
        recentHashOverwriteResults[result.targetURL.standardizedFileURL.path] = result
        conflictSession?.hashResults.append(result)
    }

    private func showHashOverwriteResultIfNeeded(_ result: HashOverwriteResult, session: ConflictResolutionSession?) {
        guard session == nil else { return }
        showHashOverwriteResult(result)
    }

    private func showHashOverwriteSummaryIfNeeded(_ conflictSession: ConflictResolutionSession) {
        // 文件操作（transferItem）填了逐文件日志 → 用完整的「新增/覆盖/跳过」传输汇总。
        // 解压合并（mergeExtractedItem）只填 hashResults → 走下面原哈希汇总。
        if !conflictSession.transferLog.isEmpty {
            showTransferSummaryIfNeeded(conflictSession)
            return
        }

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

    /// 文件操作的结束汇总：基于完整逐文件日志，含「已新增」。只在发生冲突（覆盖 / 跳过）的多项操作里弹，
    /// 纯新增或单项不打扰（活动中心有完整记录）。哈希比对过的项按文件名带上源 / 目标哈希。
    private func showTransferSummaryIfNeeded(_ conflictSession: ConflictResolutionSession) {
        // 只在真正发生了哈希比对（用户勾了「仅哈希不同时覆盖」）时才弹汇总窗。
        // 普通覆盖 / 跳过不弹——活动中心已有完整逐文件记录，不打扰。
        guard !conflictSession.hashResults.isEmpty else { return }
        let log = conflictSession.transferLog

        var hashByName: [String: HashOverwriteResult] = [:]
        for result in conflictSession.hashResults {
            hashByName[result.targetURL.lastPathComponent] = result
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("transfer.summary.title")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 320)
        panel.contentViewController = NSHostingController(
            rootView: TransferSummaryView(entries: log, hashByName: hashByName) {
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
    let allowsRememberedChoice: Bool
    var rememberedChoice: PasteConflictChoice?
    var hashResults: [HashOverwriteResult] = []
    /// 本次操作的逐文件结果（新增 / 覆盖 / 跳过）—— 结束汇总弹窗与活动中心都从这里取，统一来源。
    var transferLog: [TransferLogEntry] = []

    init(allowsRememberedChoice: Bool = true) {
        self.allowsRememberedChoice = allowsRememberedChoice
    }
}

/// 同名冲突时用户的处理选择。两个正交的轴：合并/整体替换 × 总是覆盖/仅当哈希不同时覆盖。
/// - `.replace` / `.replaceIfDifferent`：把目标当整体处理（替换 / 仅指纹不同时替换）。
/// - `.merge` / `.mergeIfDifferent`：仅文件夹 vs 同名文件夹，深度递归合并、保留目标里多余的文件，
///   对同名项分别执行覆盖 / 仅哈希不同时覆盖。
enum PasteConflictChoice: Equatable {
    case replace
    case replaceIfDifferent
    case merge
    case mergeIfDifferent
    case skip
    case cancel

    /// 该选择在「仅当哈希不同时才覆盖」这个轴上是否开启。
    var prefersHashGate: Bool {
        self == .replaceIfDifferent || self == .mergeIfDifferent
    }

    /// 该选择是否要求对文件夹做深度合并（而非整体替换）。
    var prefersMerge: Bool {
        self == .merge || self == .mergeIfDifferent
    }
}

/// 一次传输里对单个项目实际做了什么 —— 供活动中心逐文件展示，避免「只记哈希比对、新增文件无痕」的盲点。
enum TransferAction: String, Codable {
    case added        // 新增：目标原本没有，直接写入
    case overwritten  // 覆盖：目标已有同名项，被替换
    case skipped      // 跳过：同名项未替换（用户选跳过 / 哈希相同）
}

/// 活动中心逐文件日志条目。随任务历史持久化，重启后仍可查看。
struct TransferLogEntry: Codable {
    let name: String
    let action: TransferAction
    let isDirectory: Bool

    init(name: String, action: TransferAction, isDirectory: Bool) {
        self.name = name
        self.action = action
        self.isDirectory = isDirectory
    }

    // 自定义解码：旧版本历史没有 isDirectory 键，缺省按 false，避免整段历史解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        action = try container.decode(TransferAction.self, forKey: .action)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }
}

/// `transferItem` 递归传输的统计结果，供活动中心汇总「成功 / 跳过 / 哈希相同跳过」数量。
struct TransferStats {
    var transferred = 0
    var skipped = 0
    var sameHashSkips = 0

    mutating func merge(_ other: TransferStats) {
        transferred += other.transferred
        skipped += other.skipped
        sameHashSkips += other.sameHashSkips
    }
}

struct HashOverwriteResult: Codable {
    let sourceURL: URL
    let targetURL: URL
    let sourceHash: String
    let targetHash: String
    let isSame: Bool
}

/// 同名冲突对话框的内容视图。两个正交的轴各一个开关 + 「应用到全部」，动作按钮三个一行。
private struct ConflictResolutionView: View {
    let fileName: String
    let isDirectory: Bool
    let allowsRememberedChoice: Bool
    let onChoice: (PasteConflictChoice, Bool) -> Void

    @State private var replaceWholeFolder = false
    @State private var hashGate = false
    @State private var applyToAll = false

    private var continueChoice: PasteConflictChoice {
        if isDirectory, !replaceWholeFolder {
            return hashGate ? .mergeIfDifferent : .merge
        }
        return hashGate ? .replaceIfDifferent : .replace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.format("confirm.pasteConflict.title", fileName))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(L10n.text(isDirectory ? "confirm.folderConflict.message" : "confirm.pasteConflict.message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if isDirectory {
                    Toggle(L10n.text("conflict.replaceWholeFolder"), isOn: $replaceWholeFolder)
                }
                Toggle(L10n.text("conflict.hashGate"), isOn: $hashGate)
                if allowsRememberedChoice {
                    Toggle(L10n.text("conflict.applyToAll"), isOn: $applyToAll)
                }
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                Button(L10n.text("button.cancel")) { onChoice(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("conflict.skip")) { onChoice(.skip, applyToAll) }
                Button(L10n.text("button.continue")) { onChoice(continueChoice, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}

/// 文件操作结束汇总：沿用原哈希汇总的列对齐表格样式（文件 | 原文件哈希 | 试图覆盖文件哈希），
/// 加上「已新增」段（新增项无哈希，只列文件名）。每段可折叠，避免长列表炸开。
private struct TransferSummaryView: View {
    let entries: [TransferLogEntry]
    let hashByName: [String: HashOverwriteResult]
    let close: () -> Void

    private var added: [TransferLogEntry] { entries.filter { $0.action == .added } }
    private var overwritten: [TransferLogEntry] { entries.filter { $0.action == .overwritten } }
    private var skipped: [TransferLogEntry] { entries.filter { $0.action == .skipped } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("transfer.summary.title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L10n.format("transfer.summary.message", added.count, overwritten.count, skipped.count))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !added.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.added"), entries: added, hashByName: [:], showsHashColumns: false)
                    }
                    if !overwritten.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.overwritten"), entries: overwritten, hashByName: hashByName, showsHashColumns: true)
                    }
                    if !skipped.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.skipped"), entries: skipped, hashByName: hashByName, showsHashColumns: true)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
            }

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }
}

/// 传输汇总里的一个分组（已新增 / 已覆盖 / 已跳过）。可折叠；带哈希列时显示三列表格，否则只列文件名。
private struct TransferSummaryGroup: View {
    let title: String
    let entries: [TransferLogEntry]
    let hashByName: [String: HashOverwriteResult]
    let showsHashColumns: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.format("hashOverwrite.summary.section.title", title, entries.count))
                        .font(.callout)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if showsHashColumns {
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

                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    TransferSummaryRow(entry: entry, hash: hashByName[entry.name], showsHashColumns: showsHashColumns)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                }
            }
        }
    }
}

private struct TransferSummaryRow: View {
    let entry: TransferLogEntry
    let hash: HashOverwriteResult?
    let showsHashColumns: Bool

    private var displayName: String {
        entry.isDirectory ? L10n.format("transfer.folderName", entry.name) : entry.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.name)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            if showsHashColumns {
                Text(hash?.targetHash ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hash?.targetHash ?? "")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                Text(hash?.sourceHash ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hash?.sourceHash ?? "")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
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
