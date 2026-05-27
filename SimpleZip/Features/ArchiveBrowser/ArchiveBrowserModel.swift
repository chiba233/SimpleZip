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
    @Published private var navigationBackStack: [NavigationLocation] = []
    @Published private var navigationForwardStack: [NavigationLocation] = []

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
    private var openedArchiveItemDirectories: [URL] = []

    init() {
        TemporaryResourceManager.cleanStaleOpenedArchiveItems(fileManager: fileManager)
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        reload()
    }

    deinit {
        let openedArchiveItemDirectories = openedArchiveItemDirectories
        Task.detached {
            for directory in openedArchiveItemDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        if let mountedDiskImage {
            Task.detached {
                try? await ArchiveService.detachDiskImage(at: mountedDiskImage.mountPoint)
            }
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

    var canGoBack: Bool {
        !navigationBackStack.isEmpty
    }

    var canGoForward: Bool {
        !navigationForwardStack.isEmpty
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
        recordCurrentLocationForNavigation()
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

    func locationCompletions(for text: String) -> [LocationCompletion] {
        guard case .folder(let currentFolder) = mode else { return [] }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return directoryCompletions(in: currentFolder, matching: "")
        }

        let expandedQuery = NSString(string: query).expandingTildeInPath
        let queryURL = URL(fileURLWithPath: expandedQuery)
        var isDirectory = ObjCBool(false)

        if query.hasSuffix("/") || fileManager.fileExists(atPath: queryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
            return directoryCompletions(in: queryURL, matching: "")
        }

        let parentURL = queryURL.deletingLastPathComponent()
        let prefix = queryURL.lastPathComponent
        return directoryCompletions(in: parentURL, matching: prefix)
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
        openFolder(url, recordsHistory: true)
    }

    private func openFolder(_ url: URL, recordsHistory: Bool) {
        let destination = NavigationLocation.folder(url.standardizedFileURL)
        if recordsHistory, currentNavigationLocation != destination {
            recordCurrentLocationForNavigation()
        }
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
        openArchive(url, recordsHistory: true)
    }

    private func openArchive(_ url: URL, recordsHistory: Bool) {
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        if supportedURL.pathExtension.lowercased() == "dmg" {
            if recordsHistory, currentNavigationLocation != .folder(supportedURL.standardizedFileURL) {
                recordCurrentLocationForNavigation()
            }
            openDiskImage(supportedURL)
            return
        }
        let destination = NavigationLocation.archive(supportedURL.standardizedFileURL, "")
        if recordsHistory, currentNavigationLocation != destination {
            recordCurrentLocationForNavigation()
        }
        cleanupMountedDiskImageIfNeeded(for: nil)
        archivePath = ""
        allArchiveItems = []
        mode = .archive(supportedURL)
        reload()
    }

    func open(_ item: FileItem) {
        if isNavigableDirectory(item) {
            openFolder(item.url)
        } else if ArchiveService.isSupportedArchive(item.url) {
            openArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func canShowPackageContents(_ item: FileItem) -> Bool {
        item.isDirectory && isLocalFilePackage(item.url)
    }

    func showPackageContents(_ item: FileItem) {
        guard canShowPackageContents(item) else { return }
        openFolder(item.url)
    }

    func open(_ item: ArchiveItem) {
        if item.isDirectory, !isOpenableArchiveDirectoryPackage(item) {
            openArchiveDirectory(item)
            return
        }
        openArchiveItemExternally(item)
    }

    private func openArchiveDirectory(_ item: ArchiveItem) {
        let destinationPath = normalizedDirectoryPrefix(item.name)
        if currentNavigationLocation != .archive(currentArchiveURLForNavigation, destinationPath) {
            recordCurrentLocationForNavigation()
        }
        archivePath = destinationPath
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    private func openArchiveItemExternally(_ item: ArchiveItem) {
        guard case .archive(let archiveURL) = mode else { return }

        if ArchiveSafety.requiresExternalOpenConfirmation(item), !allowPotentiallyUnsafeArchiveItemOpen(item) {
            return
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else { return }

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(L10n.format("status.openingArchiveItem", item.displayName)) { progress in
                let destination = try self.makeArchiveItemOpenDirectory()
                self.openedArchiveItemDirectories.append(destination)
                try self.confirmArchiveExtractionSafety(entries: entries)
                try await ArchiveService.extract(
                    archiveURL,
                    entries: entries,
                    to: destination,
                    overwriteBehavior: .overwrite,
                    pathMode: .preserve,
                    safetyPolicy: .skipValidation,
                    operationID: operationID,
                    progress: progress
                )
                try self.confirmExtractedArchiveLinks(at: destination)

                let extractedURL = try self.extractedURL(for: item, in: destination)
                guard NSWorkspace.shared.open(extractedURL) else {
                    throw ArchiveError.openExtractedItemFailed
                }
            }
            if didSucceed {
                status = L10n.format("status.openedArchiveItem", item.displayName)
            }
        }
    }

    func exportArchiveItem(_ item: ArchiveItem, to destinationFolder: URL) async throws {
        guard case .archive(let archiveURL) = mode else {
            throw ArchiveError.unsupportedFormat
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else {
            throw ArchiveError.extractedItemNotFound
        }

        status = L10n.format("status.exportingArchiveItem", item.displayName)
        let stagingURL = try extractionCoordinator.makeExtractionStagingDirectory()
        defer { try? fileManager.removeItem(at: stagingURL) }

        try confirmArchiveExtractionSafety(entries: entries)
        try await ArchiveService.extract(
            archiveURL,
            entries: entries,
            to: stagingURL,
            overwriteBehavior: .overwrite,
            pathMode: .preserve,
            safetyPolicy: .skipValidation
        )
        try confirmExtractedArchiveLinks(at: stagingURL)

        let extractedURL = try extractedURL(for: item, in: stagingURL)
        let destinationURL = destinationFolder.appendingPathComponent(item.displayName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw ArchiveError.exportDestinationExists
        }
        try fileManager.moveItem(at: extractedURL, to: destinationURL)
        status = L10n.format("status.exportedArchiveItem", item.displayName)
    }

    private func confirmOpeningPotentiallyUnsafeArchiveItem(_ item: ArchiveItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.openUnsafeArchiveItem.title", item.displayName)
        alert.informativeText = L10n.text("confirm.openUnsafeArchiveItem.message")
        alert.addButton(withTitle: L10n.text("button.open"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func allowPotentiallyUnsafeArchiveItemOpen(_ item: ArchiveItem) -> Bool {
        switch AppPreferences.activeContentOpenPolicy {
        case .allow:
            return true
        case .deny:
            errorMessage = L10n.text("error.blockedBySecurityPolicy")
            status = L10n.text("status.failed")
            return false
        case .ask:
            return confirmOpeningPotentiallyUnsafeArchiveItem(item)
        }
    }

    private func confirmArchiveExtractionSafety(archiveURL: URL) async throws {
        let items = try await ArchiveService.list(archiveURL)
        try confirmArchiveExtractionSafety(entries: items)
    }

    private func confirmArchiveExtractionSafety(entries: [ArchiveItem]) throws {
        let unsafeNames = ArchiveSafety.unsafeEntryNames(in: entries)
        guard !unsafeNames.isEmpty else { return }

        switch AppPreferences.suspiciousPathPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveEntries.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveEntries.message", Array(unsafeNames.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
    }

    private func confirmExtractedArchiveLinks(at directory: URL) throws {
        let unsafeLinks = try ArchiveSafety.unsafeLinks(in: directory, fileManager: fileManager)
        guard !unsafeLinks.isEmpty else { return }

        switch AppPreferences.symbolicLinkPolicy {
        case .allow:
            return
        case .deny:
            throw ArchiveError.blockedBySecurityPolicy
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("confirm.unsafeArchiveLinks.title")
        alert.informativeText = L10n.format("confirm.unsafeArchiveLinks.message", Array(unsafeLinks.prefix(5)).joined(separator: ", "))
        alert.addButton(withTitle: L10n.text("button.continue"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        if alert.runModal() != .alertFirstButtonReturn {
            throw CocoaError(.userCancelled)
        }
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
                recordCurrentLocationForNavigation()
                archivePath = parentArchivePath(for: archivePath)
                selectedArchiveRows.removeAll()
                refreshArchiveItems()
            }
        }
    }

    func goBack() {
        guard let destination = navigationBackStack.popLast() else { return }
        if let current = currentNavigationLocation {
            navigationForwardStack.append(current)
        }
        restoreNavigationLocation(destination)
    }

    func goForward() {
        guard let destination = navigationForwardStack.popLast() else { return }
        if let current = currentNavigationLocation {
            navigationBackStack.append(current)
        }
        restoreNavigationLocation(destination)
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
        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(L10n.format("status.creating", request.destinationURL.lastPathComponent)) { progress in
                try await ArchiveService.createArchive(
                    from: request.sourceURLs,
                    destination: request.destinationURL,
                    options: request.options,
                    operationID: operationID,
                    progress: progress,
                    outputObserver: outputObserver
                )
            }
            finishOperationDetailsSession(detailsSession)
            if didSucceed {
                refreshVisibleFolder(containing: request.destinationURL)
            }
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
            destinationURL: archiveURL.deletingLastPathComponent(),
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        let detailsSession = prepareOperationDetailsSession(
            title: L10n.format("status.extracting", request.archiveURL.lastPathComponent),
            showsDetails: request.showDetails
        )
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(L10n.format("status.extracting", request.archiveURL.lastPathComponent)) { progress in
                let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                try await self.confirmArchiveExtractionSafety(archiveURL: request.archiveURL)
                let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
                try await ArchiveService.extract(
                    request.archiveURL,
                    to: stagingURL,
                    overwriteBehavior: backendOverwriteBehavior,
                    password: request.password,
                    zipDecryptionMethod: request.zipDecryptionMethod,
                    safetyPolicy: .skipValidation,
                    operationID: operationID,
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
            if didSucceed {
                refreshVisibleFolder(request.destinationURL)
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
            destinationURL: archiveURL.deletingLastPathComponent(),
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        let detailsSession = prepareOperationDetailsSession(
            title: L10n.format("status.extractingSelected", request.entries.count),
            showsDetails: request.showDetails
        )
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(L10n.format("status.extractingSelected", request.entries.count)) { progress in
                let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                try self.confirmArchiveExtractionSafety(entries: request.entries)
                let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
                try await ArchiveService.extract(
                    request.archiveURL,
                    entries: request.entries,
                    to: stagingURL,
                    overwriteBehavior: backendOverwriteBehavior,
                    pathMode: request.pathMode,
                    password: request.password,
                    zipDecryptionMethod: request.zipDecryptionMethod,
                    safetyPolicy: .skipValidation,
                    operationID: operationID,
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
            if didSucceed {
                refreshVisibleFolder(request.destinationURL)
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

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(L10n.format("status.testing", archiveURL.lastPathComponent)) { _ in
                try await ArchiveService.test(archiveURL, operationID: operationID)
            }
            if didSucceed {
                status = L10n.text("status.archiveTested")
            }
        }
    }

    func showSevenZipBenchmarkOptions() {
        benchmarkRequest = SevenZipBenchmarkRequest()
    }

    func runSevenZipBenchmark(_ request: SevenZipBenchmarkRequest) {
        let session = SevenZipBenchmarkSession(options: request.options)
        benchmarkSession = session
        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(
                L10n.text("status.benchmarking"),
                initialProgress: ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.benchmarking"))
            ) { _ in
                let report = try await ArchiveService.benchmark(options: request.options, operationID: operationID) { report, output in
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
            if didSucceed, session.report != nil {
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
        let operationID = activeOperationID
        operationTask?.cancel()
        ArchiveService.cancelRunningCommand(operationID: operationID)
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

    func dropFileURLs(_ urls: [URL], to destinationFolder: URL, shouldMove: Bool) {
        guard !urls.isEmpty else { return }
        startOperationTask(cancellable: true) { [weak self] in
            guard let self else { return }
            isWorking = true
            errorMessage = nil
            status = shouldMove ? L10n.text("status.movingFiles") : L10n.text("status.copyingFiles")
            operationProgress = ArchiveProgressState(fraction: 0, currentFile: nil)
            defer {
                isWorking = false
                operationProgress = ArchiveProgressState()
            }

            do {
                let total = max(1, urls.count)
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    operationProgress = ArchiveProgressState(fraction: Double(index) / Double(total), currentFile: url.lastPathComponent)
                    if shouldMove && url.deletingLastPathComponent().standardizedFileURL == destinationFolder.standardizedFileURL {
                        continue
                    }
                    let targetURL = extractionCoordinator.uniqueDestinationURL(for: url.lastPathComponent, in: destinationFolder)
                    if shouldMove {
                        try fileManager.moveItem(at: url, to: targetURL)
                    } else {
                        try fileManager.copyItem(at: url, to: targetURL)
                    }
                }
                operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil)
                status = L10n.text("status.done")
                if case .folder(let currentFolder) = mode, currentFolder.standardizedFileURL == destinationFolder.standardizedFileURL {
                    reload()
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
            let isPackage = isDirectory && isLocalFilePackage(fileURL)
            let typeDescription = values.localizedTypeDescription ?? (isDirectory ? L10n.text("type.folder") : L10n.text("type.file"))
            let applicationKey = isDirectory && !isPackage ? "__folder__" : fileURL.pathExtension.lowercased()
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
            if folderFirst, isNavigableDirectory(lhs) != isNavigableDirectory(rhs) { return isNavigableDirectory(lhs) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func directoryCompletions(in directoryURL: URL, matching prefix: String) -> [LocationCompletion] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !AppPreferences.showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            return []
        }

        let lowercasedPrefix = prefix.lowercased()
        return urls.compactMap { url -> LocationCompletion? in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  !isLocalFilePackage(url)
            else {
                return nil
            }

            let displayName = fileManager.displayName(atPath: url.path).isEmpty ? url.lastPathComponent : fileManager.displayName(atPath: url.path)
            if !lowercasedPrefix.isEmpty, !displayName.lowercased().hasPrefix(lowercasedPrefix), !url.lastPathComponent.lowercased().hasPrefix(lowercasedPrefix) {
                return nil
            }
            return LocationCompletion(url: url, displayName: displayName, path: url.path)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
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
        let expanded = selectedArchiveItems.flatMap(expandedArchiveItems)

        return Array(Set(expanded)).sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func expandedArchiveItems(for item: ArchiveItem) -> [ArchiveItem] {
        guard item.isDirectory else { return [item] }

        let prefix = normalizedDirectoryPrefix(item.name)
        let children = allArchiveItems.filter { child in
            let childName = normalizedEntryName(child.name, isDirectory: child.isDirectory)
            return childName.hasPrefix(prefix) && childName != prefix
        }
        return children.isEmpty ? [item] : children
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

    private func isOpenableArchiveDirectoryPackage(_ item: ArchiveItem) -> Bool {
        guard item.isDirectory else { return false }
        let ext = URL(fileURLWithPath: item.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .applicationBundle)
    }

    private func isNavigableDirectory(_ item: FileItem) -> Bool {
        item.isDirectory && !isLocalFilePackage(item.url)
    }

    private func isLocalFilePackage(_ url: URL) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private func makeArchiveItemOpenDirectory() throws -> URL {
        try TemporaryResourceManager.makeOpenedArchiveItemDirectory(fileManager: fileManager)
    }

    private func extractedURL(for item: ArchiveItem, in destination: URL) throws -> URL {
        let relativePath = item.isDirectory
            ? normalizedDirectoryPrefix(item.name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : normalizedEntryName(item.name, isDirectory: false)
        let expectedURL = destination.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }

        if let fallbackURL = firstExtractedURL(named: item.displayName, in: destination) {
            return fallbackURL
        }
        throw ArchiveError.extractedItemNotFound
    }

    private func firstExtractedURL(named fileName: String, in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
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
        startOperationTask(cancellable: cancellable) { _ in
            await operation()
        }
    }

    private func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor (UUID) async -> Void) {
        operationTask?.cancel()
        if canCancelCurrentOperation {
            ArchiveService.cancelRunningCommand(operationID: activeOperationID)
        }
        let operationID = UUID()
        activeOperationID = operationID
        canCancelCurrentOperation = cancellable
        operationTask = Task { [weak self] in
            await operation(operationID)
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

        let destinationPath = lastExistingArchivePath(for: requestedArchivePath)
        if currentNavigationLocation != .archive(archiveURL.standardizedFileURL, destinationPath) {
            recordCurrentLocationForNavigation()
        }
        archivePath = destinationPath
        selectedArchiveRows.removeAll()
        refreshArchiveItems()
    }

    private var currentArchiveURLForNavigation: URL {
        if case .archive(let url) = mode {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: "/")
    }

    private var currentNavigationLocation: NavigationLocation? {
        switch mode {
        case .folder(let url):
            return .folder(url.standardizedFileURL)
        case .archive(let url):
            return .archive(url.standardizedFileURL, archivePath)
        case .tag(let tag):
            return .tag(tag)
        }
    }

    private func recordCurrentLocationForNavigation() {
        guard let current = currentNavigationLocation else { return }
        if navigationBackStack.last != current {
            navigationBackStack.append(current)
            if navigationBackStack.count > 100 {
                navigationBackStack.removeFirst(navigationBackStack.count - 100)
            }
        }
        navigationForwardStack.removeAll()
    }

    private func restoreNavigationLocation(_ location: NavigationLocation) {
        switch location {
        case .folder(let url):
            openFolder(url, recordsHistory: false)
        case .archive(let url, let path):
            openArchive(url, recordsHistory: false)
            archivePath = path
        case .tag(let tag):
            cleanupMountedDiskImageIfNeeded(for: nil)
            archivePath = ""
            allArchiveItems = []
            mode = .tag(tag)
            reload()
        }
    }

    private func refreshVisibleFolder(_ folderURL: URL) {
        guard case .folder(let currentFolder) = mode else { return }
        if currentFolder.standardizedFileURL == folderURL.standardizedFileURL {
            reload()
        }
    }

    private func refreshVisibleFolder(containing url: URL) {
        refreshVisibleFolder(url.deletingLastPathComponent())
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
        cleanupMountedDiskImageIfNeeded(for: nil)
        status = L10n.text("status.readingArchive")
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let mountPoint = try await ArchiveService.mountDiskImage(url)
                mountedDiskImage = MountedDiskImageSession(sourceURL: url, mountPoint: mountPoint)
                archivePath = ""
                allArchiveItems = []
                mode = .folder(mountPoint)
                reload()
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
            }
            isWorking = false
        }
    }

    private func cleanupMountedDiskImageIfNeeded(for targetURL: URL?) {
        guard let mountedDiskImage else { return }
        if let targetURL, targetURL.standardizedFileURL.path.hasPrefix(mountedDiskImage.mountPoint.standardizedFileURL.path) {
            return
        }
        let mountPoint = mountedDiskImage.mountPoint
        self.mountedDiskImage = nil
        Task.detached {
            try? await ArchiveService.detachDiskImage(at: mountPoint)
        }
    }

    private func preferredApplicationName(for url: URL, isDirectory: Bool) -> String {
        if isDirectory, !isLocalFilePackage(url) {
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

    private func preserveFailureDetailsIfNeeded(title: String, error: Error) {
        guard operationDetailsSession == nil else { return }
        let session = ArchiveOperationDetailsSession(title: title)
        session.append(error.localizedDescription)
        session.finishedAt = Date()
        operationDetailsSession = session
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    private func runArchiveTask(
        _ workingStatus: String,
        initialProgress: ArchiveProgressState = ArchiveProgressState(fraction: 0, currentFile: nil),
        operation: @escaping (@escaping @Sendable (ArchiveProgressState) -> Void) async throws -> Void
    ) async -> Bool {
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
            return true
        } catch is CancellationError {
            errorMessage = nil
            status = L10n.text("status.cancelled")
            return false
        } catch {
            preserveFailureDetailsIfNeeded(title: workingStatus, error: error)
            if isShowingOperationDetails && operationDetailsSession != nil {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
            status = L10n.text("status.failed")
            return false
        }
    }
}

private struct MountedDiskImageSession {
    let sourceURL: URL
    let mountPoint: URL
}

private enum NavigationLocation: Equatable {
    case folder(URL)
    case archive(URL, String)
    case tag(String)
}
