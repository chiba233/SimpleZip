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
    @Published var selection = Set<FileItem.ID>()
    @Published var selectedArchiveRows = Set<ArchiveItem.ID>()
    @Published var status = L10n.text("status.ready")
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var hashReport: HashReport?

    private let fileManager = FileManager.default

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
            return L10n.format("location.archive", url.path)
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
        mode = .folder(url)
        AppPreferences.rememberLastFolder(url)
        reload()
    }

    func openArchive(_ url: URL) {
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

    func goUp() {
        switch mode {
        case .folder(let url):
            openFolder(url.deletingLastPathComponent())
        case .archive(let url):
            openFolder(url.deletingLastPathComponent())
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

        let panel = NSSavePanel()
        panel.title = L10n.text("panel.createArchive")
        panel.nameFieldStringValue = defaultArchiveName(for: items)
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = currentFolder

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        Task {
            await runArchiveTask(L10n.format("status.creating", destination.lastPathComponent)) {
                try await ArchiveService.createZipArchive(from: items.map(\.url), destination: destination)
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

        let entries = selectedArchiveItems.map(\.name)
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

        Task {
            await runArchiveTask(L10n.format("status.extractingSelected", entries.count)) {
                try await ArchiveService.extract(
                    archiveURL,
                    entries: entries,
                    to: destination,
                    overwriteBehavior: AppPreferences.overwriteBehavior
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
            status = L10n.format("status.itemCount", fileItems.count)
        } catch {
            fileItems = []
            archiveItems = []
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
            archiveItems = try await ArchiveService.list(url)
            fileItems = []
            status = L10n.format("status.archivedItemCount", archiveItems.count)
        } catch {
            archiveItems = []
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
