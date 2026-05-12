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

    static func createArchive(from sourceURLs: [URL], destination: URL, options: ArchiveCreationOptions) async throws {
        guard let first = sourceURLs.first else { return }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }

        switch options.format {
        case .zip:
            var arguments = ["-r", "-q", "-\(options.compressionLevel.rawValue)"]
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
            try await run("/usr/bin/zip", arguments: arguments, currentDirectory: parent)
        case .sevenZip:
            let tool = try sevenZipTool()
            var arguments = ["a", "-t7z", "-mx=\(options.compressionLevel.rawValue)", "-y"]
            if !options.password.isEmpty {
                arguments.append("-p\(options.password)")
                arguments.append("-mhe=on")
            }
            arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
            arguments.append(destination.path)
            arguments.append(contentsOf: relativeNames)
            try await run(tool, arguments: arguments, currentDirectory: parent)
        }
    }

    static func extract(_ archive: URL, to destination: URL, overwriteBehavior: OverwriteBehavior = .overwrite) async throws {
        switch archive.pathExtension.lowercased() {
        case "zip":
            let overwriteArgument = overwriteBehavior == .overwrite ? "-o" : "-n"
            try await run("/usr/bin/unzip", arguments: [overwriteArgument, archive.path, "-d", destination.path])
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let overwriteArgument = overwriteBehavior == .overwrite ? "-aoa" : "-aos"
            try await run(tool, arguments: ["x", archive.path, "-o\(destination.path)", overwriteArgument, "-y"])
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    static func extract(_ archive: URL, entries: [ArchiveItem], to destination: URL, overwriteBehavior: OverwriteBehavior = .overwrite, pathMode: ExtractPathMode = .preserve) async throws {
        let entryNames = expandedEntryNames(for: entries)
        guard !entryNames.isEmpty else { return }

        switch archive.pathExtension.lowercased() {
        case "zip":
            var arguments = ["-xf", archive.path, "-C", destination.path]
            if overwriteBehavior != .overwrite {
                arguments.insert("-k", at: 0)
            }
            arguments.append(contentsOf: entryNames)
            try await run("/usr/bin/tar", arguments: arguments)
            if pathMode == .flatten {
                try flattenExtractedItems(entryNames: entryNames, in: destination)
            }
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let overwriteArgument = overwriteBehavior == .overwrite ? "-aoa" : "-aos"
            var arguments = [pathMode == .flatten ? "e" : "x", archive.path]
            arguments.append(contentsOf: entryNames)
            arguments.append(contentsOf: ["-o\(destination.path)", overwriteArgument, "-y"])
            try await run(tool, arguments: arguments)
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

    /// 查找常见 Homebrew 路径下的 7zz/7z，可覆盖 Apple Silicon 和 Intel Mac。
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
}
