//
//  ContentView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let typeDescription: String
}

struct ArchiveItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let sizeText: String
    let modifiedText: String
    let method: String
}

enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
}

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

    private let fileManager = FileManager.default

    init() {
        mode = .folder(fileManager.homeDirectoryForCurrentUser)
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

        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.extractTo")
        panel.prompt = L10n.text("button.extract")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = archiveURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        Task {
            await runArchiveTask(L10n.format("status.extracting", archiveURL.lastPathComponent)) {
                try await ArchiveService.extract(archiveURL, to: destination)
            }
            if case .folder(let folder) = mode, folder == destination {
                reload()
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

    func revealInFinder() {
        switch mode {
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting(selectedFileItems.map(\.url).isEmpty ? [url] : selectedFileItems.map(\.url))
        case .archive(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func loadFolder(_ url: URL) {
        do {
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]
            let urls = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsPackageDescendants])

            fileItems = urls.compactMap { fileURL in
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys), values.isHidden != true else {
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

enum ArchiveService {
    static let supportedExtensions = ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    static func isSupportedArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    static func createZipArchive(from sourceURLs: [URL], destination: URL) async throws {
        guard let first = sourceURLs.first else { return }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }
        var arguments = ["-r", "-q", destination.path]
        arguments.append(contentsOf: relativeNames)
        try await run("/usr/bin/zip", arguments: arguments, currentDirectory: parent)
    }

    static func extract(_ archive: URL, to destination: URL) async throws {
        switch archive.pathExtension.lowercased() {
        case "zip":
            try await run("/usr/bin/unzip", arguments: ["-o", archive.path, "-d", destination.path])
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            try await run(tool, arguments: ["x", archive.path, "-o\(destination.path)", "-y"])
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func test(_ archive: URL) async throws {
        switch archive.pathExtension.lowercased() {
        case "zip":
            try await run("/usr/bin/unzip", arguments: ["-t", archive.path])
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            try await run(tool, arguments: ["t", archive.path])
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func list(_ archive: URL) async throws -> [ArchiveItem] {
        switch archive.pathExtension.lowercased() {
        case "zip":
            let output = try await runAndCapture("/usr/bin/unzip", arguments: ["-l", archive.path])
            return parseUnzipList(output)
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let output = try await runAndCapture(tool, arguments: ["l", "-slt", archive.path])
            return parseSevenZipList(output)
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    private static func sevenZipTool() throws -> String {
        let candidates = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw ArchiveError.missingSevenZip
    }

    private static func run(_ executable: String, arguments: [String], currentDirectory: URL? = nil) async throws {
        _ = try await runAndCapture(executable, arguments: arguments, currentDirectory: currentDirectory)
    }

    private static func runAndCapture(_ executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw ArchiveError.commandFailed(error.isEmpty ? output : error)
            }

            return output
        }.value
    }

    private static func parseUnzipList(_ output: String) -> [ArchiveItem] {
        output
            .split(separator: "\n")
            .compactMap { line -> ArchiveItem? in
                let text = String(line)
                guard text.range(of: #"^\s*\d+\s+\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}\s+.+$"#, options: .regularExpression) != nil else {
                    return nil
                }

                let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4 else { return nil }

                return ArchiveItem(
                    name: String(parts[3]),
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(parts[0]) ?? 0, countStyle: .file),
                    modifiedText: "\(parts[1]) \(parts[2])",
                    method: "Deflate"
                )
            }
    }

    private static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        var rows: [ArchiveItem] = []
        var values: [String: String] = [:]

        func flush() {
            guard let path = values["Path"], path != "." else {
                values.removeAll()
                return
            }

            let size = Int64(values["Size"] ?? "") ?? 0
            rows.append(
                ArchiveItem(
                    name: path,
                    sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: values["Modified"] ?? "",
                    method: values["Method"] ?? ""
                )
            )
            values.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.isEmpty {
                flush()
                continue
            }

            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        flush()
        return rows
    }
}

enum ArchiveError: LocalizedError {
    case unsupportedFormat
    case missingSevenZip
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L10n.text("error.unsupportedFormat")
        case .missingSevenZip:
            return L10n.text("error.missingSevenZip")
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ArchiveBrowserModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            VStack(spacing: 0) {
                TopBar(model: model)

                Divider()

                if case .archive = model.mode {
                    ArchiveTable(model: model)
                } else {
                    FileTable(model: model)
                }

                Divider()
                StatusBar(model: model)
            }
            .navigationTitle(model.title)
        }
        .frame(minWidth: 980, minHeight: 620)
        .alert(L10n.text("alert.operationFailed"), isPresented: Binding(get: {
            model.errorMessage != nil
        }, set: { newValue in
            if !newValue { model.errorMessage = nil }
        })) {
            Button(L10n.text("button.ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
        .onOpenURL { url in
            openExternalURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openExternalFile)) { _ in
            ExternalFileOpenQueue.shared.drain().forEach(openExternalURL)
        }
    }

    private func openExternalURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            model.openFolder(url)
        } else if ArchiveService.isSupportedArchive(url) {
            model.openArchive(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        List {
            Section(L10n.text("section.locations")) {
                SidebarButton(title: L10n.text("location.home"), systemImage: "house", action: model.openHome)
                SidebarButton(title: L10n.text("location.downloads"), systemImage: "arrow.down.circle", action: model.openDownloads)
                SidebarButton(title: L10n.text("location.desktop"), systemImage: "display", action: model.openDesktop)
            }

            Section(L10n.text("section.archives")) {
                SidebarButton(title: L10n.text("button.openArchive"), systemImage: "doc.zipper", action: model.chooseArchive)
                SidebarButton(title: L10n.text("button.openFolder"), systemImage: "folder", action: model.chooseFolder)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SimpleZip")
    }
}

struct SidebarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

struct TopBar: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ToolButton(title: L10n.text("button.add"), systemImage: "plus.square.on.square", action: model.createArchive)
                ToolButton(title: L10n.text("button.extract"), systemImage: "arrow.down.doc", action: model.extractArchive)
                ToolButton(title: L10n.text("button.test"), systemImage: "checkmark.seal", action: model.testArchive)
                ToolButton(title: L10n.text("button.open"), systemImage: "folder.badge.gearshape", action: model.chooseFolder)
                ToolButton(title: L10n.text("button.reveal"), systemImage: "arrow.up.forward.app", action: model.revealInFinder)

                Spacer()

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("help.refresh"))
            }

            HStack(spacing: 6) {
                Button(action: model.goUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canGoUp)
                .help(L10n.text("help.goUp"))

                Text(model.locationText)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 19))
                Text(title)
                    .font(.caption)
            }
            .frame(width: 66, height: 52)
        }
        .buttonStyle(.bordered)
        .help(title)
    }
}

struct FileTable: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        Table(model.fileItems, selection: $model.selection) {
            TableColumn(L10n.text("column.name")) { item in
                Label(item.name, systemImage: item.isDirectory ? "folder.fill" : (ArchiveService.isSupportedArchive(item.url) ? "doc.zipper" : "doc"))
                    .lineLimit(1)
            }
            .width(min: 280, ideal: 420)

            TableColumn(L10n.text("column.size")) { item in
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn(L10n.text("column.type")) { item in
                Text(item.typeDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)

            TableColumn(L10n.text("column.modified")) { item in
                Text(item.modified.map(Self.dateFormatter.string(from:)) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(160)
        }
        .onSubmit {
            if let first = model.selectedFileItems.first {
                model.open(first)
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { _ in
            Button(L10n.text("button.open")) {
                if let first = model.selectedFileItems.first {
                    model.open(first)
                }
            }
            Button(L10n.text("button.addToArchive")) {
                model.createArchive()
            }
            Button(L10n.text("button.extractHere")) {
                model.extractArchive()
            }
            Divider()
            Button(L10n.text("button.revealInFinder")) {
                model.revealInFinder()
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = model.fileItems.first(where: { $0.id == id }) {
                model.open(item)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        Table(model.archiveItems, selection: $model.selectedArchiveRows) {
            TableColumn(L10n.text("column.name")) { item in
                Label(item.name, systemImage: "doc")
                    .lineLimit(1)
            }
            .width(min: 300, ideal: 520)

            TableColumn(L10n.text("column.size")) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
            }
            .width(120)

            TableColumn(L10n.text("column.modified")) { item in
                Text(item.modifiedText)
                    .foregroundStyle(.secondary)
            }
            .width(180)

            TableColumn(L10n.text("column.method")) { item in
                Text(item.method)
                    .foregroundStyle(.secondary)
            }
            .width(120)
        }
        .overlay {
            if model.archiveItems.isEmpty && model.isWorking {
                ProgressView(L10n.text("status.readingArchive"))
                    .padding()
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        HStack {
            Text(model.status)
                .lineLimit(1)
            Spacer()
            Text(L10n.text("status.backend"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
