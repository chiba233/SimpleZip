//
//  ArchiveService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import UniformTypeIdentifiers

/// 归档命令服务：封装 zip/unzip/7zz 调用，让界面层不直接接触命令行细节。
enum ArchiveService {
    static let supportedExtensions = ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    static func contentTypes(for format: ArchiveCreateFormat) -> [UTType] {
        UTType(filenameExtension: format.pathExtension).map { [$0] } ?? []
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    static func createZipArchive(from sourceURLs: [URL], destination: URL) async throws {
        try await createArchive(from: sourceURLs, destination: destination, options: ArchiveCreationOptions())
    }

    static func createArchive(from sourceURLs: [URL], destination: URL, options: ArchiveCreationOptions, progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in }) async throws {
        guard let first = sourceURLs.first else { return }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }
        let totalFiles = max(1, fileCount(in: sourceURLs))
        let parser = ProgressOutputParser(totalFiles: totalFiles, progress: progress)

        switch options.format {
        case .zip:
            var arguments = ["-r", "-\(options.compressionLevel.rawValue)"]
            if !options.password.isEmpty {
                arguments.append(contentsOf: ["-P", options.password])
            }
            arguments.append(destination.path)
            arguments.append(contentsOf: relativeNames)
            let excludes = zipExcludePatterns(from: options)
            if !excludes.isEmpty {
                arguments.append("-x")
                arguments.append(contentsOf: excludes)
            }
            try await run("/usr/bin/zip", arguments: arguments, currentDirectory: parent, progressParser: parser)
        case .sevenZip:
            let tool = try sevenZipTool()
            var arguments = ["a", "-t7z", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
            if !options.password.isEmpty {
                arguments.append("-p\(options.password)")
                arguments.append("-mhe=on")
            }
            arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
            arguments.append(destination.path)
            arguments.append(contentsOf: relativeNames)
            try await run(tool, arguments: arguments, currentDirectory: parent, progressParser: parser)
        }
    }

    static func extract(_ archive: URL, to destination: URL, overwriteBehavior: OverwriteBehavior = .overwrite, password: String = "", progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in }) async throws {
        let parser = ProgressOutputParser(totalFiles: nil, progress: progress)
        switch archive.pathExtension.lowercased() {
        case "zip":
            let overwriteArgument = overwriteBehavior == .overwrite ? "-o" : "-n"
            var arguments = [overwriteArgument]
            if !password.isEmpty {
                arguments.append(contentsOf: ["-P", password])
            }
            arguments.append(contentsOf: [archive.path, "-d", destination.path])
            try await run("/usr/bin/unzip", arguments: arguments, progressParser: parser)
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let overwriteArgument = overwriteBehavior == .overwrite ? "-aoa" : "-aos"
            var arguments = ["x", archive.path, "-o\(destination.path)", overwriteArgument, "-bb1", "-bsp1", "-y"]
            if !password.isEmpty {
                arguments.append("-p\(password)")
            }
            try await run(tool, arguments: arguments, progressParser: parser)
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func extract(_ archive: URL, entries: [ArchiveItem], to destination: URL, overwriteBehavior: OverwriteBehavior = .overwrite, pathMode: ExtractPathMode = .preserve, password: String = "", progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in }) async throws {
        let entryNames = expandedEntryNames(for: entries)
        guard !entryNames.isEmpty else { return }
        let parser = ProgressOutputParser(totalFiles: max(1, entryNames.count), progress: progress)

        switch archive.pathExtension.lowercased() {
        case "zip":
            if password.isEmpty {
                var arguments = ["-xvf", archive.path, "-C", destination.path]
                if overwriteBehavior != .overwrite {
                    arguments.insert("-k", at: 0)
                }
                arguments.append(contentsOf: entryNames)
                try await run("/usr/bin/tar", arguments: arguments, progressParser: parser)
            } else {
                var arguments = [overwriteBehavior == .overwrite ? "-o" : "-n", "-P", password, archive.path]
                arguments.append(contentsOf: entryNames)
                arguments.append(contentsOf: ["-d", destination.path])
                try await run("/usr/bin/unzip", arguments: arguments, progressParser: parser)
            }
            if pathMode == .flatten {
                try flattenExtractedItems(entryNames: entryNames, in: destination)
            }
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let overwriteArgument = overwriteBehavior == .overwrite ? "-aoa" : "-aos"
            var arguments = [pathMode == .flatten ? "e" : "x", archive.path]
            arguments.append(contentsOf: entryNames)
            arguments.append(contentsOf: ["-o\(destination.path)", overwriteArgument, "-bb1", "-bsp1", "-y"])
            if !password.isEmpty {
                arguments.append("-p\(password)")
            }
            try await run(tool, arguments: arguments, progressParser: parser)
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
            let unzipOutput = try await runAndCapture("/usr/bin/unzip", arguments: ["-l", archive.path])
            let tarOutput = try await runAndCapture("/usr/bin/tar", arguments: ["-tf", archive.path])
            return parseZipList(tarOutput: tarOutput, unzipOutput: unzipOutput)
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let output = try await runAndCapture(tool, arguments: ["l", "-slt", archive.path])
            return parseSevenZipList(output)
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func sevenZipBackendDescription() -> String {
        do {
            let tool = try resolvedSevenZipTool()
            return L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    static func sevenZipVersion() async -> String {
        do {
            let tool = try resolvedSevenZipTool()
            let output = try await runAndCapture(tool.path, arguments: ["i"])
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
            return L10n.format("settings.7zip.resolvedVersion", tool.source.title, firstLine.isEmpty ? tool.path : firstLine)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    /// 按设置查找 7zz/7z。App 内置版本可放在 Contents/Resources/Tools/7zz 或 7z。
    private static func sevenZipTool() throws -> String {
        try resolvedSevenZipTool().path
    }

    private static func resolvedSevenZipTool() throws -> ResolvedSevenZipTool {
        let candidates: [ResolvedSevenZipTool]
        switch AppPreferences.sevenZipBackend {
        case .automatic:
            candidates = bundledSevenZipCandidates + systemSevenZipCandidates
        case .bundled:
            candidates = bundledSevenZipCandidates
        case .system:
            candidates = systemSevenZipCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingSevenZip
    }

    private static var bundledSevenZipCandidates: [ResolvedSevenZipTool] {
        guard let resourcePath = Bundle.main.resourceURL?.path else { return [] }
        return [
            "\(resourcePath)/Tools/7zz",
            "\(resourcePath)/Tools/7z",
            "\(resourcePath)/7zz",
            "\(resourcePath)/7z"
        ].map { ResolvedSevenZipTool(path: $0, source: .bundled) }
    }

    private static var systemSevenZipCandidates: [ResolvedSevenZipTool] {
        uniqueExistingCandidatePaths(
            [
                "/opt/homebrew/bin/7zz",
                "/opt/homebrew/bin/7z",
                "/usr/local/bin/7zz",
                "/usr/local/bin/7z",
                "/opt/homebrew/opt/sevenzip/bin/7zz",
                "/opt/homebrew/opt/sevenzip/bin/7z",
                "/opt/homebrew/opt/p7zip/bin/7z",
                "/usr/local/opt/sevenzip/bin/7zz",
                "/usr/local/opt/sevenzip/bin/7z",
                "/usr/local/opt/p7zip/bin/7z",
                envPath(for: "7zz"),
                envPath(for: "7z")
            ].compactMap { $0 } + cellarCandidates(formula: "sevenzip", tools: ["7zz", "7z"]) + cellarCandidates(formula: "p7zip", tools: ["7z"])
        ).map { ResolvedSevenZipTool(path: $0, source: .system) }
    }

    private static func uniqueExistingCandidatePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func envPath(for executable: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", executable]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").first.map(String.init)
        } catch {
            return nil
        }
    }

    private static func cellarCandidates(formula: String, tools: [String]) -> [String] {
        ["/opt/homebrew/Cellar/\(formula)", "/usr/local/Cellar/\(formula)"].flatMap { root -> [String] in
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
            return versions.flatMap { version in
                tools.map { "\(root)/\(version)/bin/\($0)" }
            }
        }
    }

    private static func run(_ executable: String, arguments: [String], currentDirectory: URL? = nil, progressParser: ProgressOutputParser? = nil) async throws {
        _ = try await runAndCapture(executable, arguments: arguments, currentDirectory: currentDirectory, progressParser: progressParser)
    }

    private static func zipExcludePatterns(from options: ArchiveCreationOptions) -> [String] {
        var patterns: [String] = []
        if options.skipDSStore {
            patterns.append(contentsOf: ["*.DS_Store", "*/.DS_Store"])
        }
        if options.skipHiddenFiles {
            patterns.append(contentsOf: [".*", "*/.*"])
        }
        patterns.append(contentsOf: customExcludePatterns(from: options.customExcludes))
        return Array(Set(patterns)).sorted()
    }

    private static func sevenZipExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-xr!\($0)" }
    }

    private static func customExcludePatterns(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// ZIP 扁平化解压：先按原结构抽出，再把文件移动到目标目录根部。
    private static func flattenExtractedItems(entryNames: [String], in destination: URL) throws {
        let fileManager = FileManager.default
        for entryName in entryNames where !entryName.hasSuffix("/") {
            let sourceURL = destination.appendingPathComponent(entryName)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            var targetURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: targetURL.path), targetURL != sourceURL {
                targetURL = destination.appendingPathComponent(uniqueFileName(for: sourceURL.lastPathComponent, in: destination))
            }
            if targetURL != sourceURL {
                try? fileManager.removeItem(at: targetURL)
                try fileManager.moveItem(at: sourceURL, to: targetURL)
            }
        }
    }

    private static func uniqueFileName(for fileName: String, in directory: URL) -> String {
        let fileManager = FileManager.default
        let baseURL = URL(fileURLWithPath: fileName)
        let name = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension

        for index in 1...999 {
            let candidate = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }

        return UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// 在后台线程运行命令，避免压缩/解压时阻塞主界面。
    private static func runAndCapture(_ executable: String, arguments: [String], currentDirectory: URL? = nil, progressParser: ProgressOutputParser? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let outputBuffer = LockedStringBuffer()
            let errorBuffer = LockedStringBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                outputBuffer.append(text)
                progressParser?.consume(text)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                errorBuffer.append(text)
                progressParser?.consume(text)
            }

            try process.run()
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            let output = outputBuffer.value + (String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            let error = errorBuffer.value + (String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

            guard process.terminationStatus == 0 else {
                throw ArchiveError.commandFailed(error.isEmpty ? output : error)
            }

            progressParser?.finish()
            return output
        }.value
    }

    /// zip 的条目路径以 bsdtar 为准，unzip 输出只用来补充大小和时间，避免列表路径和解压路径不一致。
    private static func parseZipList(tarOutput: String, unzipOutput: String) -> [ArchiveItem] {
        let metadataByName = Dictionary(uniqueKeysWithValues: parseUnzipList(unzipOutput).map { item in
            (normalizedEntryName(item.name), item)
        })

        return tarOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { name in
                let isDirectory = name.hasSuffix("/")
                let metadata = metadataByName[normalizedEntryName(name)]
                return ArchiveItem(
                    name: name,
                    isDirectory: isDirectory,
                    sizeText: isDirectory ? "" : (metadata?.sizeText ?? ""),
                    modifiedText: metadata?.modifiedText ?? "",
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    /// 解析 macOS 自带 unzip -l 的列表输出。
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

                let name = String(parts[3])
                let size = Int64(parts[0]) ?? 0
                let isDirectory = name.hasSuffix("/")
                return ArchiveItem(
                    name: name,
                    isDirectory: isDirectory,
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: "\(parts[1]) \(parts[2])",
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    /// 解析 7zz -slt 的 key/value 输出，兼容 7z/tar/gz 等格式。
    private static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        var rows: [ArchiveItem] = []
        var values: [String: String] = [:]

        func flush() {
            guard let path = values["Path"], path != "." else {
                values.removeAll()
                return
            }

            let size = Int64(values["Size"] ?? "") ?? 0
            let isDirectory = values["Folder"] == "+"
            rows.append(
                ArchiveItem(
                    name: path,
                    isDirectory: isDirectory,
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
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

    /// 选中目录时展开为其所有子项目，避免 unzip 对目录项本身报 filename not matched。
    private static func expandedEntryNames(for entries: [ArchiveItem]) -> [String] {
        let selectedDirectories = entries
            .filter(\.isDirectory)
            .map { normalizedDirectoryPrefix($0.name) }

        let names = entries.flatMap { item -> [String] in
            if item.isDirectory {
                return entries
                    .map(\.name)
                    .filter { childName in
                        let normalizedName = normalizedEntryName(childName)
                        return selectedDirectories.contains { prefix in
                            normalizedName.hasPrefix(prefix) && normalizedName != prefix
                        }
                    }
            }
            return [item.name]
        }

        return Array(Set(names)).sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    private static func normalizedEntryName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (name.hasSuffix("/") ? "/" : "")
    }

    private static func fileCount(in urls: [URL]) -> Int {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        return urls.reduce(0) { count, url in
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return count + 1 }
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) else {
                    return count + 1
                }
                return count + enumerator.compactMap { entry -> URL? in entry as? URL }.filter { fileURL in
                    (try? fileURL.resourceValues(forKeys: resourceKeys).isRegularFile) == true
                }.count
            }
            return count + 1
        }
    }
}

private final class ProgressOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int?
    private let progress: @Sendable (ArchiveProgressState) -> Void
    private var processedFiles = 0
    private var remainder = ""

    nonisolated init(totalFiles: Int?, progress: @escaping @Sendable (ArchiveProgressState) -> Void) {
        self.totalFiles = totalFiles
        self.progress = progress
    }

    nonisolated func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }

        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        let combined = remainder + normalized
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        remainder = lines.last ?? ""
        lines.dropLast().forEach(handleLine)
    }

    nonisolated func finish() {
        lock.lock()
        defer { lock.unlock() }

        if !remainder.isEmpty {
            handleLine(remainder)
            remainder = ""
        }
        progress(ArchiveProgressState(fraction: 1, currentFile: nil))
    }

    private nonisolated func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let percent = parsePercent(from: trimmed) {
            progress(ArchiveProgressState(fraction: percent, currentFile: currentFile(from: trimmed)))
            return
        }

        guard let file = currentFile(from: trimmed), !file.isEmpty else { return }
        processedFiles += 1
        let fraction = totalFiles.map { min(0.99, Double(processedFiles) / Double(max(1, $0))) }
        progress(ArchiveProgressState(fraction: fraction, currentFile: file))
    }

    private nonisolated func parsePercent(from line: String) -> Double? {
        guard let match = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let number = line[match].dropLast()
        guard let value = Double(number) else { return nil }
        return min(1, max(0, value / 100))
    }

    private nonisolated func currentFile(from line: String) -> String? {
        let prefixes = ["adding:", "updating:", "extracting:", "inflating:", "creating:", "x ", "- "]
        for prefix in prefixes where line.localizedCaseInsensitiveContains(prefix) {
            if let range = line.range(of: prefix, options: .caseInsensitive) {
                return String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        if line.hasPrefix("Path = ") {
            return String(line.dropFirst("Path = ".count))
        }

        if !line.hasPrefix("7-Zip"), !line.hasPrefix("Scanning"), !line.hasPrefix("Creating archive"), !line.hasPrefix("Everything is Ok") {
            return line
        }
        return nil
    }
}

private final class LockedStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    nonisolated init() {}

    nonisolated var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    nonisolated func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }
}

private struct ResolvedSevenZipTool {
    let path: String
    let source: SevenZipToolSource
}

private enum SevenZipToolSource {
    case bundled
    case system

    var title: String {
        switch self {
        case .bundled:
            return L10n.text("settings.7zip.source.bundled")
        case .system:
            return L10n.text("settings.7zip.source.system")
        }
    }
}
