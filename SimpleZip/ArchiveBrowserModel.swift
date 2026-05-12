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
    @Published var extractSelectionRequest: ExtractSelectionRequest?

    private let fileManager = FileManager.default
    private var allArchiveItems: [ArchiveItem] = []
    private var archivePath = ""
    private var fileClipboard: (urls: [URL], shouldMove: Bool)?

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
        }
    }

    var locationText: String {
        switch mode {
        case .folder(let url):
            return url.path
        case .archive(let url):
            let baseLocation = L10n.format("location.archive", url.path)
            return archivePath.isEmpty ? baseLocation : "\(baseLocation) / \(archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
    }

    var selectedFileItems: [FileItem] {
        fileItems.filter { selection.contains($0.id) }
    }

    var selectedArchiveItems: [ArchiveItem] {
        archiveItems.filter { selectedArchiveRows.contains($0.id) }
    }

    var canGoUp: Bool {
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
            await runArchiveTask(L10n.format("status.creating", request.destinationURL.lastPathComponent)) {
                try await ArchiveService.createArchive(from: request.sourceURLs, destination: request.destinationURL, options: request.options)
            }
            reload()
        }
    }

    func extractArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder:
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

        Task {
            await runArchiveTask(L10n.format("status.extracting", archiveURL.lastPathComponent)) {
                try await ArchiveService.extract(archiveURL, to: destination, overwriteBehavior: AppPreferences.overwriteBehavior)
            }
            if case .folder(let folder) = mode, folder == destination {
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

        let destination: URL
        if let defaultDestination = AppPreferences.defaultExtractURL(for: archiveURL, fileManager: fileManager) {
            destination = defaultDestination
        } else {
            let panel = NSOpenPanel()
            panel.title = L10n.text("panel.extractTo")
            panel.prompt = L10n.text("button.extractSelected")
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

        extractSelectionRequest = ExtractSelectionRequest(archiveURL: archiveURL, entries: entries, destinationURL: destination)
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        Task {
            await runArchiveTask(L10n.format("status.extractingSelected", request.entries.count)) {
                try await ArchiveService.extract(
                    request.archiveURL,
                    entries: request.entries,
                    to: request.destinationURL,
                    overwriteBehavior: AppPreferences.overwriteBehavior,
                    pathMode: request.pathMode
                )
            }
        }
    }

    func testArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        Task {
            await runArchiveTask(L10n.format("status.testing", archiveURL.lastPathComponent)) {
                try await ArchiveService.test(archiveURL)
            }
            status = L10n.text("status.archiveTested")
        }
    }

    func calculateHash() {
        let urls: [URL]
        switch mode {
        case .folder:
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
                hashReport = try await HashService.calculate(for: urls, includeHiddenFiles: AppPreferences.showHiddenFiles)
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

        do {
            for url in fileClipboard.urls {
                let targetURL = uniqueDestinationURL(for: url.lastPathComponent, in: folderURL)
                if fileClipboard.shouldMove {
                    try fileManager.moveItem(at: url, to: targetURL)
                } else {
                    try fileManager.copyItem(at: url, to: targetURL)
                }
            }
            if fileClipboard.shouldMove {
                self.fileClipboard = nil
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }

    func deleteSelectedFiles() {
        guard case .folder = mode else { return }

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

            fileItems = urls.compactMap { fileURL in
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
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

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

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    private func runArchiveTask(_ workingStatus: String, operation: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        status = workingStatus
        defer { isWorking = false }

        do {
            try await operation()
            status = L10n.text("status.done")
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.text("status.failed")
        }
    }
}
