//
//  ArchiveBrowserModel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 主界面的状态模型：负责文件浏览、压缩/解压动作和状态提示。
@MainActor
final class ArchiveBrowserModel: ObservableObject {
    @Published var mode: BrowserMode
    @Published var fileItems: [FileItem] = []
    @Published var archiveItems: [ArchiveItem] = []
    @Published var selection = Set<UUID>()
    @Published var selectedArchiveRows = Set<UUID>()
    @Published var status = L10n.text("status.ready")
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var hashReport: HashReport?
    @Published var benchmarkRequest: SevenZipBenchmarkRequest?
    @Published var benchmarkSession: SevenZipBenchmarkSession?
    @Published var operationDetailsSession: ArchiveOperationDetailsSession?
    @Published var isShowingOperationDetails = false
    @Published var archiveCreationRequest: ArchiveCreationRequest?
    @Published var extractArchiveRequest: ExtractArchiveRequest?
    @Published var extractSelectionRequest: ExtractSelectionRequest?
    @Published var operationProgress = ArchiveProgressState()
    @Published private(set) var canCancelCurrentOperation = false

    private let fileManager = FileManager.default
    private let extractionCoordinator = ArchiveExtractionCoordinator(fileManager: .default)
    private var allArchiveItems: [ArchiveItem] = []
    private var archivePath = ""
    private var fileClipboard: (urls: [URL], shouldMove: Bool)?
    private var loadTask: Task<Void, Never>?
    private var activeLoadGeneration = 0
    private var operationTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var mountedDiskImage: MountedDiskImageSession?

    init() {
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        reload()
    }

    deinit {
        if let mountedDiskImage {
            try? ArchiveService.detachDiskImage(at: mountedDiskImage.mountPoint)
        }
    }

    var title: String {
        switch mode {
        case .folder(let url):
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .archive(let url):
            return url.lastPathComponent
        case .tag(let tag):
            return tag
        }
    }

    var locationText: String {
        switch mode {
        case .folder(let url):
            return url.path
        case .archive(let url):
            let baseLocation = L10n.format("location.archive", url.path)
            return archivePath.isEmpty ? baseLocation : "\(baseLocation) / \(archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        }
    }

    var editableLocationText: String {
        switch mode {
        case .folder(let url):
            return url.path
        case .archive(let url):
            return archivePath.isEmpty ? url.path : url.path + "/" + archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        }
    }

    var selectedFileItems: [FileItem] {
        fileItems.filter { selection.contains($0.id) }
    }

    var selectedArchiveItems: [ArchiveItem] {
        archiveItems.filter { selectedArchiveRows.contains($0.id) }
    }

    var canGoUp: Bool {
        if case .tag = mode {
            return false
        }
        if case .folder(let url) = mode {
            return url.path != "/"
        }
        return true
    }

    func openHome() {
        openFolder(fileManager.homeDirectoryForCurrentUser)
    }

    func openDownloads() {
        openFolder(fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openDesktop() {
        openFolder(fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openDocuments() {
        openFolder(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser)
    }

    func openApplications() {
        openFolder(URL(fileURLWithPath: "/Applications"))
    }

    func openTag(_ tag: String) {
        cleanupMountedDiskImageIfNeeded(for: nil)
        archivePath = ""
        allArchiveItems = []
        mode = .tag(tag)
        reload()
    }

    func pinCurrentFolderToSidebar() {
        guard case .folder(let url) = mode else { return }
        AppPreferences.pinSidebarURL(url)
        status = L10n.format("status.pinnedLocation", url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    }

    func openLocationText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .archive(let archiveURL):
            openArchiveLocationText(trimmed, archiveURL: archiveURL)
        case .folder, .tag:
            openFolder(lastExistingFolder(for: URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openFolder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openArchive")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveService.supportedArchiveTypes
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let url = panel.url {
            openArchive(url)
        }
    }

    func openFolder(_ url: URL) {
        cleanupMountedDiskImageIfNeeded(for: url)
        archivePath = ""
        allArchiveItems = []
        mode = .folder(url)
        if let mountedDiskImage {
            if !url.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
                AppPreferences.rememberLastFolder(url)
            }
        } else {
            AppPreferences.rememberLastFolder(url)
        }
        reload()
    }

    func openArchive(_ url: URL) {
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        if supportedURL.pathExtension.lowercased() == "dmg" {
            openDiskImage(supportedURL)
            return
        }
        cleanupMountedDiskImageIfNeeded(for: nil)
        archivePath = ""
        allArchiveItems = []
        mode = .archive(supportedURL)
        reload()
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            openFolder(item.url)
        } else if ArchiveService.isSupportedArchive(item.url) {
            openArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func open(_ item: ArchiveItem) {
        guard item.isDirectory else { return }
        archivePath = normalizedDirectoryPrefix(item.name)
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    func openSelectedItem() {
        switch mode {
        case .folder:
            if let item = selectedFileItems.first {
                open(item)
            }
        case .tag:
            if let item = selectedFileItems.first {
                open(item)
            }
        case .archive:
            if let item = selectedArchiveItems.first {
                open(item)
            }
        }
    }

    func openDroppedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }

        if urls.count == 1 {
            openDroppedURL(first)
            return
        }

        let archiveURL = urls.first(where: { ArchiveService.isSupportedArchive($0) })
        if let archiveURL {
            openArchive(archiveURL)
        } else {
            openFolder(first.deletingLastPathComponent())
        }
    }

    private func openDroppedURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            openFolder(url)
        } else if ArchiveService.isSupportedArchive(url) {
            openArchive(url)
        } else {
            openFolder(url.deletingLastPathComponent())
        }
    }

    func goUp() {
        switch mode {
        case .folder(let url):
            openFolder(url.deletingLastPathComponent())
        case .tag:
            openHome()
        case .archive(let url):
            if archivePath.isEmpty {
                openFolder(url.deletingLastPathComponent())
            } else {
                archivePath = parentArchivePath(for: archivePath)
                selectedArchiveRows.removeAll()
                refreshArchiveItems()
            }
        }
    }

    func reload() {
        loadTask?.cancel()
        selection.removeAll()
        selectedArchiveRows.removeAll()
        errorMessage = nil
        let loadGeneration = nextLoadGeneration()

        switch mode {
        case .folder(let url):
            loadTask = nil
            loadFolder(url)
        case .tag(let tag):
            loadTask = Task { [weak self] in
                await self?.loadTaggedFiles(tag, generation: loadGeneration)
            }
        case .archive(let url):
            loadTask = Task { [weak self] in
                await self?.loadArchive(url, generation: loadGeneration)
            }
        }
    }

    func createArchive() {
        guard case .folder(let currentFolder) = mode else {
            errorMessage = L10n.text("error.openFolderFirst")
            return
        }

        let items = selectedFileItems
        guard !items.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let destination = currentFolder.appendingPathComponent(defaultArchiveName(for: items))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: items.map(\.url), directoryURL: currentFolder, destinationURL: destination)
    }

    func performCreateArchive(_ request: ArchiveCreationRequest) {
        let detailsSession = prepareOperationDetailsSession(
            title: L10n.format("status.creating", request.destinationURL.lastPathComponent),
            showsDetails: request.options.showDetails
        )
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            await runArchiveTask(L10n.format("status.creating", request.destinationURL.lastPathComponent)) { progress in
                try await ArchiveService.createArchive(
                    from: request.sourceURLs,
                    destination: request.destinationURL,
                    options: request.options,
                    progress: progress,
                    outputObserver: outputObserver
                )
            }
            finishOperationDetailsSession(detailsSession)
            reload()
        }
    }

    func extractFromCurrentContext() {
        if case .archive = mode, !selectedArchiveItems.isEmpty {
            extractSelectedArchiveItems()
        } else {
            extractArchive()
        }
    }

    func extractArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        extractArchiveRequest = ExtractArchiveRequest(
            archiveURL: archiveURL,
            destinationURL: archiveURL.deletingLastPathComponent()
        )
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        let detailsSession = prepareOperationDetailsSession(
            title: L10n.format("status.extracting", request.archiveURL.lastPathComponent),
            showsDetails: request.showDetails
        )
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            await runArchiveTask(L10n.format("status.extracting", request.archiveURL.lastPathComponent)) { progress in
                let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
                try await ArchiveService.extract(
                    request.archiveURL,
                    to: stagingURL,
                    overwriteBehavior: backendOverwriteBehavior,
                    password: request.password,
                    progress: progress,
                    outputObserver: outputObserver
                )
                try await self.extractionCoordinator.mergeExtractedItems(
                    from: stagingURL,
                    to: request.destinationURL,
                    defaultOverwriteBehavior: AppPreferences.overwriteBehavior
                ) { [weak self] status in
                    self?.status = status
                } updateProgress: { [weak self] progress in
                    self?.operationProgress = progress
                }
            }
            finishOperationDetailsSession(detailsSession)
            if case .folder(let folder) = mode, folder == request.destinationURL {
                reload()
            }
        }
    }

    func extractSelectedArchiveItems() {
        guard case .archive(let archiveURL) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let entries = expandedSelectedArchiveItems()
        guard !entries.isEmpty else {
            errorMessage = L10n.text("error.selectArchiveItemsToExtract")
            return
        }

        extractSelectionRequest = ExtractSelectionRequest(
            archiveURL: archiveURL,
            entries: entries,
            destinationURL: archiveURL.deletingLastPathComponent()
        )
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        let detailsSession = prepareOperationDetailsSession(
            title: L10n.format("status.extractingSelected", request.entries.count),
            showsDetails: request.showDetails
        )
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            await runArchiveTask(L10n.format("status.extractingSelected", request.entries.count)) { progress in
                let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
                try await ArchiveService.extract(
                    request.archiveURL,
                    entries: request.entries,
                    to: stagingURL,
                    overwriteBehavior: backendOverwriteBehavior,
                    pathMode: request.pathMode,
                    password: request.password,
                    progress: progress,
                    outputObserver: outputObserver
                )
                try await self.extractionCoordinator.mergeExtractedItems(
                    from: stagingURL,
                    to: request.destinationURL,
                    defaultOverwriteBehavior: AppPreferences.overwriteBehavior
                ) { [weak self] status in
                    self?.status = status
                } updateProgress: { [weak self] progress in
                    self?.operationProgress = progress
                }
            }
            finishOperationDetailsSession(detailsSession)
            if case .folder(let folder) = mode, folder == request.destinationURL {
                reload()
            }
        }
    }

    func testArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            await runArchiveTask(L10n.format("status.testing", archiveURL.lastPathComponent)) { _ in
                try await ArchiveService.test(archiveURL)
            }
            status = L10n.text("status.archiveTested")
        }
    }

    func showSevenZipBenchmarkOptions() {
        benchmarkRequest = SevenZipBenchmarkRequest()
    }

    func runSevenZipBenchmark(_ request: SevenZipBenchmarkRequest) {
        let session = SevenZipBenchmarkSession(options: request.options)
        benchmarkSession = session
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            await runArchiveTask(
                L10n.text("status.benchmarking"),
                initialProgress: ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.benchmarking"))
            ) { _ in
                let report = try await ArchiveService.benchmark(options: request.options) { report, output in
                    Task { @MainActor [weak session] in
                        session?.report = report
                        session?.rawOutput = output
                    }
                }
                await MainActor.run {
                    session.report = report
                    session.rawOutput = report.output
                }
            }
            session.finishedAt = Date()
            if session.report != nil {
                status = L10n.text("status.benchmarkReady")
            }
        }
    }

    func calculateHash() {
        calculateHash(algorithms: HashAlgorithm.allCases)
    }

    func showOperationDetails() {
        guard operationDetailsSession != nil else { return }
        isShowingOperationDetails = true
    }

    func calculateHash(algorithms: [HashAlgorithm]) {
        let urls: [URL]
        switch mode {
        case .folder, .tag:
            urls = selectedFileItems.map(\.url)
        case .archive(let url):
            urls = [url]
        }

        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.selectFilesForHash")
            return
        }

        startOperationTask { [weak self] in
            guard let self else { return }
            isWorking = true
            errorMessage = nil
            status = L10n.text("status.hashing")
            defer { isWorking = false }

            do {
                hashReport = try await HashService.calculate(for: urls, includeHiddenFiles: AppPreferences.showHiddenFiles, algorithms: algorithms)
                status = L10n.text("status.hashReady")
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
        }
    }

    func revealInFinder() {
        switch mode {
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting(selectedFileItems.map(\.url).isEmpty ? [url] : selectedFileItems.map(\.url))
        case .tag:
            NSWorkspace.shared.activateFileViewerSelecting(selectedFileItems.map(\.url))
        case .archive(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

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
            operationProgress = ArchiveProgressState(fraction: 0, currentFile: nil)
            defer {
                isWorking = false
                operationProgress = ArchiveProgressState()
            }

            do {
                let total = max(1, fileClipboard.urls.count)
                for (index, url) in fileClipboard.urls.enumerated() {
                    operationProgress = ArchiveProgressState(fraction: Double(index) / Double(total), currentFile: url.lastPathComponent)
                    let requestedTargetURL = folderURL.appendingPathComponent(url.lastPathComponent)
                    let targetURL = try await extractionCoordinator.resolveDestination(
                        for: url,
                        requestedTargetURL: requestedTargetURL,
                        updateStatus: { [weak self] status in self?.status = status },
                        updateProgress: { [weak self] progress in self?.operationProgress = progress }
                    )
                    guard let targetURL else { continue }

                    if fileClipboard.shouldMove {
                        try fileManager.moveItem(at: url, to: targetURL)
                    } else {
                        try fileManager.copyItem(at: url, to: targetURL)
                    }
                    extractionCoordinator.showPendingHashOverwriteResult(for: targetURL)
                }
                if fileClipboard.shouldMove {
                    self.fileClipboard = nil
                }
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
        }
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        operationTask?.cancel()
        ArchiveService.cancelRunningCommand()
    }

    func deleteSelectedFiles() {
        guard case .folder = mode, !selectedFileItems.isEmpty else { return }
        guard confirmDelete(items: selectedFileItems) else { return }

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

    func sortFileItems(by key: String, ascending: Bool) {
        fileItems.sort { lhs, rhs in
            compareFileItem(lhs, rhs, by: key, ascending: ascending)
        }
    }

    func sortArchiveItems(by key: String, ascending: Bool) {
        archiveItems.sort { lhs, rhs in
            compareArchiveItem(lhs, rhs, by: key, ascending: ascending)
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

        do {
            for item in selectedFileItems {
                try fileManager.moveItem(
                    at: item.url,
                    to: extractionCoordinator.uniqueDestinationURL(for: item.url.lastPathComponent, in: destinationFolder)
                )
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    /// 加载本地文件夹内容，并按“文件夹优先、名称自然排序”展示。
    private func loadFolder(_ url: URL) {
        do {
            let resourceKeys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .contentAccessDateKey,
                .addedToDirectoryDateKey,
                .localizedTypeDescriptionKey,
                .isHiddenKey
            ]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !AppPreferences.showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }

            let urls = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: options)

            fileItems = makeFileItems(from: urls, folderFirst: true)

            archiveItems = []
            allArchiveItems = []
            status = L10n.format("status.itemCount", fileItems.count)
        } catch {
            fileItems = []
            archiveItems = []
            allArchiveItems = []
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotOpenFolder")
        }
    }

    /// 使用 Spotlight 查询 Finder tag。结果仍显示成普通文件行，方便继续打开、哈希或创建压缩包。
    private func loadTaggedFiles(_ tag: String, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.format("status.searchingTag", tag))
        defer { endAsyncLoad(generation: generation) }

        do {
            let urls = try await taggedFileURLs(named: tag)
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = makeFileItems(from: urls, folderFirst: false)
            archiveItems = []
            allArchiveItems = []
            status = L10n.format("status.tagItemCount", fileItems.count)
        } catch {
            guard isCurrentLoad(generation, mode: .tag(tag)) else { return }
            fileItems = []
            archiveItems = []
            allArchiveItems = []
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    private func makeFileItems(from urls: [URL], folderFirst: Bool) -> [FileItem] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey,
            .localizedTypeDescriptionKey
        ]
        var applicationNameCache: [String: String] = [:]
        return urls.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            let isDirectory = values.isDirectory == true
            let typeDescription = values.localizedTypeDescription ?? (isDirectory ? L10n.text("type.folder") : L10n.text("type.file"))
            let applicationKey = isDirectory ? "__folder__" : fileURL.pathExtension.lowercased()
            let applicationName = applicationNameCache[applicationKey] ?? preferredApplicationName(for: fileURL, isDirectory: isDirectory)
            applicationNameCache[applicationKey] = applicationName

            return FileItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                isDirectory: isDirectory,
                size: isDirectory ? nil : Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                created: values.creationDate,
                dateAdded: values.addedToDirectoryDate,
                lastOpened: values.contentAccessDate,
                typeDescription: typeDescription,
                applicationName: applicationName
            )
        }
        .sorted { lhs, rhs in
            if folderFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated func taggedFileURLs(named tag: String) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let output = Pipe()
                    let escapedTag = tag.replacingOccurrences(of: "\"", with: "\\\"")
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                    process.arguments = [
                        "-onlyin",
                        FileManager.default.homeDirectoryForCurrentUser.path,
                        "kMDItemUserTags == \"\(escapedTag)\""
                    ]
                    process.standardOutput = output
                    try process.run()
                    process.waitUntilExit()

                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self)
                    let urls = text
                        .split(separator: "\n")
                        .map { URL(fileURLWithPath: String($0)) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    continuation.resume(returning: urls)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 加载压缩包内项目。具体解析交给 ArchiveService，这里只更新 UI 状态。
    private func loadArchive(_ url: URL, generation: Int) async {
        beginAsyncLoad(generation: generation, statusText: L10n.text("status.readingArchive"))
        defer { endAsyncLoad(generation: generation) }

        do {
            let items = try await ArchiveService.list(url)
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            allArchiveItems = items
            fileItems = []
            refreshArchiveItems()
        } catch {
            guard isCurrentLoad(generation, mode: .archive(url)) else { return }
            archiveItems = []
            allArchiveItems = []
            errorMessage = error.localizedDescription
            status = L10n.text("status.couldNotReadArchive")
        }
    }

    private func defaultArchiveName(for items: [FileItem]) -> String {
        if items.count == 1 {
            return items[0].url.deletingPathExtension().lastPathComponent + ".zip"
        }
        return "Archive.zip"
    }

    /// 选中压缩包内目录时，展开成目录下所有项目，避免后端只收到目录占位项。
    private func expandedSelectedArchiveItems() -> [ArchiveItem] {
        let selectedItems = selectedArchiveItems
        let expanded = selectedItems.flatMap { item -> [ArchiveItem] in
            guard item.isDirectory else { return [item] }

            let prefix = normalizedDirectoryPrefix(item.name)
            let children = allArchiveItems.filter { child in
                let childName = normalizedEntryName(child.name, isDirectory: child.isDirectory)
                return childName.hasPrefix(prefix) && childName != prefix
            }
            return children.isEmpty ? [item] : children
        }

        return Array(Set(expanded)).sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 根据压缩包内当前路径生成“这一层”的列表，并自动补齐缺失的目录节点。
    private func refreshArchiveItems() {
        let currentItems = immediateArchiveChildren(from: archiveItemsWithSyntheticDirectories(), in: archivePath)
        archiveItems = currentItems
        status = L10n.format("status.archivedItemCount", currentItems.count)
    }

    private func immediateArchiveChildren(from items: [ArchiveItem], in path: String) -> [ArchiveItem] {
        var childrenByName: [String: ArchiveItem] = [:]

        for item in items {
            let itemName = normalizedEntryName(item.name, isDirectory: item.isDirectory)
            guard itemName.hasPrefix(path), itemName != path else { continue }

            let remainder = String(itemName.dropFirst(path.count))
            guard !remainder.isEmpty else { continue }

            if let slashIndex = remainder.firstIndex(of: "/") {
                let directoryName = path + remainder[..<slashIndex] + "/"
                if childrenByName[directoryName] == nil {
                    childrenByName[directoryName] = syntheticDirectory(named: String(directoryName))
                }
            } else {
                childrenByName[itemName] = item
            }
        }

        return childrenByName.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func archiveItemsWithSyntheticDirectories() -> [ArchiveItem] {
        var itemsByName: [String: ArchiveItem] = [:]

        for item in allArchiveItems {
            let itemName = normalizedEntryName(item.name, isDirectory: item.isDirectory)
            itemsByName[itemName] = item

            let components = itemName
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .map(String.init)
            let directoryComponents = item.isDirectory ? components : Array(components.dropLast())

            var prefix = ""
            for component in directoryComponents {
                prefix += component + "/"
                if itemsByName[prefix] == nil {
                    itemsByName[prefix] = syntheticDirectory(named: prefix)
                }
            }
        }

        return Array(itemsByName.values)
    }

    private func syntheticDirectory(named name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
    }

    private func parentArchivePath(for path: String) -> String {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/") + "/"
    }

    private func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name, isDirectory: true)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    private func normalizedEntryName(_ name: String, isDirectory: Bool) -> String {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedName.isEmpty { return "" }
        return isDirectory ? trimmedName + "/" : trimmedName
    }

    private func nextLoadGeneration() -> Int {
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

    private func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        if canCancelCurrentOperation {
            ArchiveService.cancelRunningCommand()
        }
        let operationID = UUID()
        activeOperationID = operationID
        canCancelCurrentOperation = cancellable
        operationTask = Task { [weak self] in
            await operation()
            await MainActor.run {
                guard let self, self.activeOperationID == operationID else { return }
                self.operationTask = nil
                self.activeOperationID = nil
                self.canCancelCurrentOperation = false
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

    private func lastExistingFolder(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return fileManager.homeDirectoryForCurrentUser
            }
            candidate = parent
        }
        return candidate
    }

    private func openArchiveLocationText(_ text: String, archiveURL: URL) {
        let archivePathPrefix = archiveURL.path + "/"
        let requestedArchivePath: String
        if text == archiveURL.path {
            requestedArchivePath = ""
        } else if text.hasPrefix(archivePathPrefix) {
            requestedArchivePath = String(text.dropFirst(archivePathPrefix.count))
        } else if FileManager.default.fileExists(atPath: text) {
            openFolder(lastExistingFolder(for: URL(fileURLWithPath: text)))
            return
        } else {
            requestedArchivePath = text
        }

        archivePath = lastExistingArchivePath(for: requestedArchivePath)
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    private func lastExistingArchivePath(for path: String) -> String {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty else { return "" }

        var candidate = ""
        let directories = Set(archiveItemsWithSyntheticDirectories().filter(\.isDirectory).map { normalizedDirectoryPrefix($0.name) })
        for component in components {
            let next = candidate + component + "/"
            if directories.contains(next) {
                candidate = next
            } else {
                break
            }
        }
        return candidate
    }

    private func compareFileItem(_ lhs: FileItem, _ rhs: FileItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "type":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "application":
            result = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        case "lastOpened":
            result = (lhs.lastOpened ?? .distantPast).compare(rhs.lastOpened ?? .distantPast)
        case "dateAdded":
            result = (lhs.dateAdded ?? .distantPast).compare(rhs.dateAdded ?? .distantPast)
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "created":
            result = (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
        default:
            result = lhs.name.localizedStandardCompare(rhs.name)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func compareArchiveItem(_ lhs: ArchiveItem, _ rhs: ArchiveItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "kind":
            result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
        case "size":
            result = NSNumber(value: lhs.size ?? -1).compare(NSNumber(value: rhs.size ?? -1))
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        case "method":
            result = lhs.method.localizedStandardCompare(rhs.method)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func openDiskImage(_ url: URL) {
        do {
            cleanupMountedDiskImageIfNeeded(for: nil)
            let mountPoint = try ArchiveService.mountDiskImage(url)
            mountedDiskImage = MountedDiskImageSession(sourceURL: url, mountPoint: mountPoint)
            archivePath = ""
            allArchiveItems = []
            mode = .folder(mountPoint)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    private func cleanupMountedDiskImageIfNeeded(for targetURL: URL?) {
        guard let mountedDiskImage else { return }
        if let targetURL, targetURL.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
            return
        }
        try? ArchiveService.detachDiskImage(at: mountedDiskImage.mountPoint)
        self.mountedDiskImage = nil
    }

    private func preferredApplicationName(for url: URL, isDirectory: Bool) -> String {
        if isDirectory {
            return "Finder"
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return ""
        }
        if let bundle = Bundle(url: appURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    private func prepareOperationDetailsSession(title: String, showsDetails: Bool) -> ArchiveOperationDetailsSession? {
        guard showsDetails else {
            operationDetailsSession = nil
            isShowingOperationDetails = false
            return nil
        }
        let session = ArchiveOperationDetailsSession(title: title)
        operationDetailsSession = session
        isShowingOperationDetails = true
        return session
    }

    private func makeOperationOutputObserver(for session: ArchiveOperationDetailsSession?) -> (@Sendable (String) -> Void)? {
        guard let session else { return nil }
        return { chunk in
            Task { @MainActor [weak session] in
                session?.append(chunk)
            }
        }
    }

    private func finishOperationDetailsSession(_ session: ArchiveOperationDetailsSession?) {
        session?.finishedAt = Date()
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    private func runArchiveTask(
        _ workingStatus: String,
        initialProgress: ArchiveProgressState = ArchiveProgressState(fraction: 0, currentFile: nil),
        operation: @escaping (@escaping @Sendable (ArchiveProgressState) -> Void) async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        operationProgress = initialProgress
        status = workingStatus
        defer {
            isWorking = false
            operationProgress = ArchiveProgressState()
        }

        do {
            try await operation { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.operationProgress = progress
                    if let statusText = progress.statusText, !statusText.isEmpty {
                        self?.status = statusText
                    } else if let currentFile = progress.currentFile, !currentFile.isEmpty {
                        self?.status = currentFile
                    }
                }
            }
            status = L10n.text("status.done")
        } catch is CancellationError {
            errorMessage = nil
            status = L10n.text("status.cancelled")
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }
}

private struct MountedDiskImageSession {
    let sourceURL: URL
    let mountPoint: URL
}
