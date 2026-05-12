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
    @Published var archiveCreationRequest: ArchiveCreationRequest?
    @Published var extractArchiveRequest: ExtractArchiveRequest?
    @Published var extractSelectionRequest: ExtractSelectionRequest?
    @Published var operationProgress = ArchiveProgressState()

    private let fileManager = FileManager.default
    private var allArchiveItems: [ArchiveItem] = []
    private var archivePath = ""
    private var fileClipboard: (urls: [URL], shouldMove: Bool)?
    private var pendingHashOverwriteResults: [String: HashOverwriteResult] = [:]

    init() {
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        reload()
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

        if panel.runModal() == .OK, let url = panel.url {
            openArchive(url)
        }
    }

    func openFolder(_ url: URL) {
        archivePath = ""
        allArchiveItems = []
        mode = .folder(url)
        AppPreferences.rememberLastFolder(url)
        reload()
    }

    func openArchive(_ url: URL) {
        archivePath = ""
        allArchiveItems = []
        mode = .archive(url)
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
        selection.removeAll()
        selectedArchiveRows.removeAll()
        errorMessage = nil

        switch mode {
        case .folder(let url):
            loadFolder(url)
        case .tag(let tag):
            Task { await loadTaggedFiles(tag) }
        case .archive(let url):
            Task { await loadArchive(url) }
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
        Task {
            await runArchiveTask(L10n.format("status.creating", request.destinationURL.lastPathComponent)) { progress in
                try await ArchiveService.createArchive(from: request.sourceURLs, destination: request.destinationURL, options: request.options, progress: progress)
            }
            reload()
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

        let destination: URL
        if let defaultDestination = AppPreferences.defaultExtractURL(for: archiveURL, fileManager: fileManager) {
            destination = defaultDestination
        } else {
            let panel = NSOpenPanel()
            panel.title = L10n.text("panel.extractTo")
            panel.prompt = L10n.text("button.extract")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = archiveURL.deletingLastPathComponent()

            guard panel.runModal() == .OK, let selectedDestination = panel.url else {
                return
            }
            destination = selectedDestination
        }

        extractArchiveRequest = ExtractArchiveRequest(archiveURL: archiveURL, destinationURL: destination)
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        Task {
            await runArchiveTask(L10n.format("status.extracting", request.archiveURL.lastPathComponent)) { progress in
                let stagingURL = try self.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                try await ArchiveService.extract(
                    request.archiveURL,
                    to: stagingURL,
                    overwriteBehavior: .overwrite,
                    password: request.password,
                    progress: progress
                )
                try await self.mergeExtractedItems(from: stagingURL, to: request.destinationURL)
            }
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
        Task {
            await runArchiveTask(L10n.format("status.extractingSelected", request.entries.count)) { progress in
                let stagingURL = try self.makeExtractionStagingDirectory()
                defer { try? self.fileManager.removeItem(at: stagingURL) }

                try await ArchiveService.extract(
                    request.archiveURL,
                    entries: request.entries,
                    to: stagingURL,
                    overwriteBehavior: .overwrite,
                    pathMode: request.pathMode,
                    password: request.password,
                    progress: progress
                )
                try await self.mergeExtractedItems(from: stagingURL, to: request.destinationURL)
            }
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

        Task {
            await runArchiveTask(L10n.format("status.testing", archiveURL.lastPathComponent)) { _ in
                try await ArchiveService.test(archiveURL)
            }
            status = L10n.text("status.archiveTested")
        }
    }

    func calculateHash(algorithms: [HashAlgorithm] = HashAlgorithm.allCases) {
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

        Task {
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

        Task {
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
                    let targetURL = try await resolvedPasteDestination(for: url, requestedTargetURL: requestedTargetURL)
                    guard let targetURL else { continue }

                    if fileClipboard.shouldMove {
                        try fileManager.moveItem(at: url, to: targetURL)
                    } else {
                        try fileManager.copyItem(at: url, to: targetURL)
                    }
                    showPendingHashOverwriteResult(for: targetURL)
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
                try fileManager.moveItem(at: item.url, to: uniqueDestinationURL(for: item.url.lastPathComponent, in: destinationFolder))
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
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]
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
    private func loadTaggedFiles(_ tag: String) async {
        isWorking = true
        status = L10n.format("status.searchingTag", tag)
        defer { isWorking = false }

        do {
            let urls = try await taggedFileURLs(named: tag)
            fileItems = makeFileItems(from: urls, folderFirst: false)
            archiveItems = []
            allArchiveItems = []
            status = L10n.format("status.tagItemCount", fileItems.count)
        } catch {
            fileItems = []
            archiveItems = []
            allArchiveItems = []
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    private func makeFileItems(from urls: [URL], folderFirst: Bool) -> [FileItem] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        return urls.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                return nil
            }

            return FileItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                isDirectory: values.isDirectory == true,
                size: values.isDirectory == true ? nil : Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate,
                typeDescription: values.localizedTypeDescription ?? (values.isDirectory == true ? L10n.text("type.folder") : L10n.text("type.file"))
            )
        }
        .sorted { lhs, rhs in
            if folderFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated func taggedFileURLs(named tag: String) async throws -> [URL] {
        try await Task.detached {
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
            return text
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        .value
    }

    /// 加载压缩包内项目。具体解析交给 ArchiveService，这里只更新 UI 状态。
    private func loadArchive(_ url: URL) async {
        isWorking = true
        status = L10n.text("status.readingArchive")
        defer { isWorking = false }

        do {
            allArchiveItems = try await ArchiveService.list(url)
            fileItems = []
            refreshArchiveItems()
        } catch {
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

    private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
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
        ArchiveItem(name: name, isDirectory: true, sizeText: "", modifiedText: "", method: "")
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

    private func confirmDelete(items: [FileItem]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("confirm.delete.title", items.count)
        alert.informativeText = L10n.text("confirm.delete.message")
        alert.addButton(withTitle: L10n.text("file.moveToTrash"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func resolvedPasteDestination(for sourceURL: URL, requestedTargetURL: URL) async throws -> URL? {
        if sourceURL.standardizedFileURL == requestedTargetURL.standardizedFileURL {
            return nil
        }
        guard fileManager.fileExists(atPath: requestedTargetURL.path) else {
            return requestedTargetURL
        }

        switch pasteConflictChoice(sourceURL: sourceURL, targetURL: requestedTargetURL) {
        case .replace:
            try trashExistingItem(at: requestedTargetURL)
            return requestedTargetURL
        case .keepBoth:
            return uniqueDestinationURL(for: sourceURL.lastPathComponent, in: requestedTargetURL.deletingLastPathComponent())
        case .skip:
            return nil
        case .replaceIfDifferent:
            let result = try await compareHashesForOverwrite(sourceURL: sourceURL, targetURL: requestedTargetURL)
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

    private func pasteConflictChoice(sourceURL: URL, targetURL: URL) -> PasteConflictChoice {
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

    private func makeExtractionStagingDirectory() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-Extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func mergeExtractedItems(from stagingURL: URL, to destinationURL: URL) async throws {
        status = L10n.text("status.mergingExtractedFiles")
        operationProgress = ArchiveProgressState(fraction: nil, currentFile: destinationURL.lastPathComponent)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let extractedURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        for sourceURL in extractedURLs {
            let targetURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            try await mergeExtractedItem(sourceURL, to: targetURL)
        }
    }

    private func mergeExtractedItem(_ sourceURL: URL, to targetURL: URL) async throws {
        operationProgress = ArchiveProgressState(fraction: nil, currentFile: sourceURL.lastPathComponent)

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
                try await mergeExtractedItem(childURL, to: targetURL.appendingPathComponent(childURL.lastPathComponent))
            }
            try? fileManager.removeItem(at: sourceURL)
            return
        }

        let resolvedURL = try await resolvedPasteDestination(for: sourceURL, requestedTargetURL: targetURL)
        guard let resolvedURL else { return }
        try fileManager.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: resolvedURL)
        showPendingHashOverwriteResult(for: resolvedURL)
    }

    private func compareHashesForOverwrite(sourceURL: URL, targetURL: URL) async throws -> HashOverwriteResult {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let sourceValues = try sourceURL.resourceValues(forKeys: resourceKeys)
        let targetValues = try targetURL.resourceValues(forKeys: resourceKeys)
        guard sourceValues.isRegularFile == true, targetValues.isRegularFile == true else {
            return HashOverwriteResult(sourceURL: sourceURL, targetURL: targetURL, sourceHash: L10n.text("hash.notRegularFile"), targetHash: L10n.text("hash.notRegularFile"), isSame: false)
        }

        let progressPanel = makeHashProgressPanel()
        progressPanel.panel.makeKeyAndOrderFront(nil)
        defer { progressPanel.panel.close() }

        status = L10n.text("status.hashingForOverwrite")
        operationProgress = ArchiveProgressState(fraction: 0, currentFile: targetURL.lastPathComponent)
        updateHashProgressPanel(progressPanel, fraction: 0.1, fileName: targetURL.lastPathComponent, labelKey: "hashOverwrite.progress.existing")
        let targetHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: targetURL) }.value

        operationProgress = ArchiveProgressState(fraction: 0.5, currentFile: sourceURL.lastPathComponent)
        updateHashProgressPanel(progressPanel, fraction: 0.55, fileName: sourceURL.lastPathComponent, labelKey: "hashOverwrite.progress.incoming")
        let sourceHash = try await Task.detached(priority: .userInitiated) { try HashService.sha256(for: sourceURL) }.value

        operationProgress = ArchiveProgressState(fraction: 1, currentFile: nil)
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

    private func showPendingHashOverwriteResult(for url: URL) {
        let key = url.standardizedFileURL.path
        guard let result = pendingHashOverwriteResults.removeValue(forKey: key) else { return }
        showHashOverwriteResult(result)
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
        case "modified":
            result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
        default:
            result = lhs.name.localizedStandardCompare(rhs.name)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    private func compareArchiveItem(_ lhs: ArchiveItem, _ rhs: ArchiveItem, by key: String, ascending: Bool) -> Bool {
        let result: ComparisonResult
        switch key {
        case "size":
            result = lhs.sizeText.localizedStandardCompare(rhs.sizeText)
        case "modified":
            result = lhs.modifiedText.localizedStandardCompare(rhs.modifiedText)
        case "method":
            result = lhs.method.localizedStandardCompare(rhs.method)
        default:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        }
        return ascending ? result != .orderedDescending : result == .orderedDescending
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    private func runArchiveTask(_ workingStatus: String, operation: @escaping (@escaping @Sendable (ArchiveProgressState) -> Void) async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        operationProgress = ArchiveProgressState(fraction: 0, currentFile: nil)
        status = workingStatus
        defer {
            isWorking = false
            operationProgress = ArchiveProgressState()
        }

        do {
            try await operation { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.operationProgress = progress
                    if let currentFile = progress.currentFile, !currentFile.isEmpty {
                        self?.status = currentFile
                    }
                }
            }
            status = L10n.text("status.done")
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
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
