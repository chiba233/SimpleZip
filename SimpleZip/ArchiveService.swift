//
//  ArchiveService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Darwin
import Foundation
import UniformTypeIdentifiers

/// 归档命令服务：封装 zip/unzip/7zz 调用，让界面层不直接接触命令行细节。
enum ArchiveService {
    static let supportedExtensions = ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    private static let activeProcessRegistry = ActiveProcessRegistry()
    
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        
        func append(_ chunk: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            value += chunk
            return value
        }
    }

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

    static func cancelRunningCommand() {
        activeProcessRegistry.cancelActiveProcess()
    }

    static func createArchive(from sourceURLs: [URL], destination: URL, options: ArchiveCreationOptions, progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in }) async throws {
        guard let first = sourceURLs.first else { return }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }
        progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.countingFiles")))
        let totalFiles = max(1, try await fileCount(in: sourceURLs))
        try Task.checkCancellation()
        let parser = ProgressOutputParser(totalFiles: totalFiles, progress: progress)

        switch options.format {
        case .zip:
            var arguments = ["-r", "-\(options.compressionLevel.rawValue)"]
            if !options.password.isEmpty {
                arguments.append("-e")
            }
            arguments.append(destination.path)
            arguments.append(contentsOf: relativeNames)
            let excludes = zipExcludePatterns(from: options)
            if !excludes.isEmpty {
                arguments.append("-x")
                arguments.append(contentsOf: excludes)
            }
            let inputStrategy: ProcessInputStrategy = options.password.isEmpty ? .none : .passwordPrompts([options.password, options.password])
            try await run("/usr/bin/zip", arguments: arguments, currentDirectory: parent, progressParser: parser, inputStrategy: inputStrategy)
        case .sevenZip:
            let tool = try sevenZipTool()
            let arguments = try sevenZipCreateArguments(destination: destination, relativeNames: relativeNames, options: options)
            let inputStrategy: ProcessInputStrategy = options.password.isEmpty ? .none : .passwordPrompts([options.password, options.password])
            try await run(tool, arguments: arguments, currentDirectory: parent, progressParser: parser, inputStrategy: inputStrategy)
        }
    }

    static func extract(_ archive: URL, to destination: URL, overwriteBehavior: OverwriteBehavior = .overwrite, password: String = "", progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in }) async throws {
        let parser = ProgressOutputParser(totalFiles: nil, progress: progress)
        switch archive.pathExtension.lowercased() {
        case "zip":
            let overwriteArgument = overwriteBehavior == .overwrite ? "-o" : "-n"
            let arguments = [overwriteArgument, archive.path, "-d", destination.path]
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run("/usr/bin/unzip", arguments: arguments, progressParser: parser, inputStrategy: inputStrategy)
        case "7z", "tar", "gz", "tgz", "bz2", "xz":
            let tool = try sevenZipTool()
            let overwriteArgument = overwriteBehavior == .overwrite ? "-aoa" : "-aos"
            var arguments = ["x", archive.path, "-o\(destination.path)", overwriteArgument, "-bb1", "-bsp1", "-y"]
            if !password.isEmpty {
                arguments.append("-p")
            }
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run(tool, arguments: arguments, progressParser: parser, inputStrategy: inputStrategy)
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
                var arguments = [overwriteBehavior == .overwrite ? "-o" : "-n", archive.path]
                arguments.append(contentsOf: entryNames)
                arguments.append(contentsOf: ["-d", destination.path])
                try await run("/usr/bin/unzip", arguments: arguments, progressParser: parser, inputStrategy: .passwordPrompts([password]))
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
                arguments.append("-p")
            }
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run(tool, arguments: arguments, progressParser: parser, inputStrategy: inputStrategy)
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

    static func benchmark(
        options: SevenZipBenchmarkOptions,
        update: @escaping @Sendable (SevenZipBenchmarkReport, String) -> Void = { _, _ in }
    ) async throws -> SevenZipBenchmarkReport {
        let tool = try resolvedSevenZipTool()
        var arguments = ["b", "-bt", "-md=\(options.dictionarySizeMB)m"]
        if options.threadCount > 0 {
            arguments.append("-mmt=\(options.threadCount)")
        }
        let outputBuffer = OutputAccumulator()
        let output = try await runAndCapture(tool.path, arguments: arguments, outputObserver: { chunk in
            let currentOutput = outputBuffer.append(chunk)
            update(
                parseSevenZipBenchmark(
                    currentOutput,
                    backendDescription: L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path),
                    options: options
                ),
                currentOutput
            )
        })
        return parseSevenZipBenchmark(
            output,
            backendDescription: L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path),
            options: options
        )
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

    private static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        progressParser: ProgressOutputParser? = nil,
        inputStrategy: ProcessInputStrategy = .none
    ) async throws {
        _ = try await runAndCapture(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy
        )
    }

    static func zipExcludePatterns(from options: ArchiveCreationOptions) -> [String] {
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

    static func sevenZipExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-xr!\($0)" }
    }

    static func sevenZipCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        var arguments = ["a", "-t7z", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
        if !options.password.isEmpty {
            arguments.append("-p")
            arguments.append(options.sevenZipEncryptFileNames ? "-mhe=on" : "-mhe=off")
        }
        arguments.append("-ms=\(options.sevenZipSolidArchive ? "on" : "off")")
        if let method = options.sevenZipMethod.argumentValue {
            arguments.append("-m0=\(method)")
        }
        if options.sevenZipThreadCount > 0 {
            arguments.append("-mmt=\(options.sevenZipThreadCount)")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func normalizedSevenZipVolumeSize(from text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: #"(?i)^\d+[bkmg]?$"#, options: .regularExpression) != nil else {
            throw ArchiveError.invalidSevenZipVolumeSize
        }
        return trimmed.lowercased()
    }

    static func customExcludePatterns(from text: String) -> [String] {
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
    private static func runAndCapture(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        progressParser: ProgressOutputParser? = nil,
        inputStrategy: ProcessInputStrategy = .none,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try runAndCaptureSync(
                        executable,
                        arguments: arguments,
                        currentDirectory: currentDirectory,
                        progressParser: progressParser,
                        inputStrategy: inputStrategy,
                        outputObserver: outputObserver
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runAndCaptureSync(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        inputStrategy: ProcessInputStrategy,
        outputObserver: (@Sendable (String) -> Void)?
    ) throws -> String {
        switch inputStrategy {
        case .none:
            return try runWithPipe(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                outputObserver: outputObserver
            )
        case .passwordPrompts(let responses):
            return try runWithPseudoTerminal(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                promptResponder: InteractivePasswordResponder(responses: responses),
                outputObserver: outputObserver
            )
        }
    }

    private static func runWithPipe(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let ioPipe = Pipe()
        process.standardOutput = ioPipe
        process.standardError = ioPipe

        activeProcessRegistry.register(process)
        defer { activeProcessRegistry.clear(process) }
        try process.run()
        let output = try readOutput(from: ioPipe.fileHandleForReading, progressParser: progressParser, outputObserver: outputObserver)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if activeProcessRegistry.wasCancelled(process) {
                throw CancellationError()
            }
            throw ArchiveError.commandFailed(output)
        }

        progressParser?.finish()
        return output
    }

    private static func runWithPseudoTerminal(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        promptResponder: InteractivePasswordResponder,
        outputObserver: (@Sendable (String) -> Void)?
    ) throws -> String {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw ArchiveError.commandFailed(String(cString: strerror(errno)))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        var responder = promptResponder

        activeProcessRegistry.register(process)
        defer { activeProcessRegistry.clear(process) }
        try process.run()
        try? slaveHandle.close()
        let output = try readOutput(from: masterHandle, progressParser: progressParser, outputObserver: outputObserver) { text in
            try responder.consume(text, writer: masterHandle)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if activeProcessRegistry.wasCancelled(process) {
                throw CancellationError()
            }
            throw ArchiveError.commandFailed(output)
        }

        progressParser?.finish()
        return output
    }

    /// zip 的条目路径以 bsdtar 为准，unzip 输出只用来补充大小和时间，避免列表路径和解压路径不一致。
    static func parseZipList(tarOutput: String, unzipOutput: String) -> [ArchiveItem] {
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
                    size: isDirectory ? nil : metadata?.size,
                    modified: metadata?.modified,
                    sizeText: isDirectory ? "" : (metadata?.sizeText ?? ""),
                    modifiedText: metadata?.modifiedText ?? "",
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    /// 解析 macOS 自带 unzip -l 的列表输出。
    static func parseUnzipList(_ output: String) -> [ArchiveItem] {
        output
            .split(separator: "\n")
            .compactMap { line -> ArchiveItem? in
                let text = String(line)
                guard text.range(of: #"^\s*\d+\s+\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}\s+.+$"#, options: .regularExpression) != nil else {
                    return nil
                }

                let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4 else { return nil }

                let name = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                let size = Int64(parts[0]) ?? 0
                let isDirectory = name.hasSuffix("/")
                let modifiedText = "\(parts[1]) \(parts[2])"
                return ArchiveItem(
                    name: name,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: parseUnzipModified(modifiedText),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
                    method: isDirectory ? "" : "Deflate"
                )
            }
    }

    /// 解析 7zz -slt 的 key/value 输出，兼容 7z/tar/gz 等格式。
    static func parseSevenZipList(_ output: String) -> [ArchiveItem] {
        var rows: [ArchiveItem] = []
        var values: [String: String] = [:]

        func flush() {
            guard let path = values["Path"], path != "." else {
                values.removeAll()
                return
            }

            let size = Int64(values["Size"] ?? "") ?? 0
            let isDirectory = values["Folder"] == "+"
            let modifiedText = values["Modified"] ?? ""
            rows.append(
                ArchiveItem(
                    name: path,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: parseSevenZipModified(modifiedText),
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modifiedText,
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

    nonisolated static func parseSevenZipBenchmark(_ output: String, backendDescription: String, options: SevenZipBenchmarkOptions) -> SevenZipBenchmarkReport {
        let lines = output.split(separator: "\n").map(String.init)
        let compilerLine = lines.first { $0.hasPrefix("Compiler:") }
        let systemLine = lines.first { $0.contains("Darwin :") || $0.contains("Windows ") || $0.contains("Linux ") }
        let pageSizeLine = lines.first { $0.hasPrefix("PageSize:") }
        let ramSizeLine = lines.first { $0.hasPrefix("RAM size:") }
        let ramUsageLine = lines.first { $0.hasPrefix("RAM usage:") }
        let averageLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Avr:") }
        let totalLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Tot:") }
        let threadsLine = lines.first { $0.contains("# Benchmark threads:") }
        let cpuLine = cpuDescriptionLine(in: lines, after: pageSizeLine)
        let frequencySamples = lines.compactMap(parseFrequencySample)
        let dictionaryRows = lines.compactMap(parseBenchmarkDictionaryRow)
        let kernelTime = timeValue(in: lines, prefix: "Kernel  Time =")
        let userTime = timeValue(in: lines, prefix: "User    Time =")
        let processTime = timeValue(in: lines, prefix: "Process Time =")
        let globalTime = timeValue(in: lines, prefix: "Global  Time =")

        let averageValues = averageLine.map(integers(in:)) ?? []
        let totalValues = totalLine.map(integers(in:)) ?? []
        let threadValues = threadsLine.map(integers(in:)) ?? []
        let ramSizeValues = ramSizeLine.map(integers(in:)) ?? []
        let ramUsageValues = ramUsageLine.map(integers(in:)) ?? []

        let compressionAverage: SevenZipBenchmarkMetrics? = averageValues.count >= 8 ? SevenZipBenchmarkMetrics(
            speedKiBPerSecond: averageValues[0],
            usagePercent: averageValues[1],
            ratingMips: averageValues[2],
            usageRatingMips: averageValues[3]
        ) : nil

        let decompressionAverage: SevenZipBenchmarkMetrics? = averageValues.count >= 8 ? SevenZipBenchmarkMetrics(
            speedKiBPerSecond: averageValues[4],
            usagePercent: averageValues[5],
            ratingMips: averageValues[6],
            usageRatingMips: averageValues[7]
        ) : nil

        return SevenZipBenchmarkReport(
            backendDescription: backendDescription,
            options: options,
            compilerDescription: compilerLine,
            systemDescription: systemLine,
            cpuDescription: cpuLine,
            pageSizeText: pageSizeLine,
            ramUsageMB: ramUsageValues.first,
            ramSizeMB: ramSizeValues.first,
            hardwareThreads: ramSizeValues.count > 1 ? ramSizeValues[1] : nil,
            benchmarkThreads: threadValues.last,
            frequencySamples: frequencySamples,
            dictionaryRows: dictionaryRows,
            compressionAverage: compressionAverage,
            decompressionAverage: decompressionAverage,
            totalRatingMips: totalValues.last,
            totalUsagePercent: totalValues.first,
            kernelTimeSeconds: kernelTime,
            userTimeSeconds: userTime,
            processTimeSeconds: processTime,
            globalTimeSeconds: globalTime,
            output: output
        )
    }

    /// 选中目录时展开为其所有子项目，避免 unzip 对目录项本身报 filename not matched。
    static func expandedEntryNames(for entries: [ArchiveItem]) -> [String] {
        let normalizedNames = Dictionary(uniqueKeysWithValues: entries.map { item in
            (item.name, normalizedEntryName(item.name))
        })

        func isLeafDirectory(_ directory: ArchiveItem) -> Bool {
            let prefix = normalizedDirectoryPrefix(directory.name)
            return !entries.contains { child in
                guard child.name != directory.name else { return false }
                let normalizedName = normalizedNames[child.name] ?? normalizedEntryName(child.name)
                return normalizedName.hasPrefix(prefix)
            }
        }

        let names = entries.flatMap { item -> [String] in
            if item.isDirectory {
                let prefix = normalizedDirectoryPrefix(item.name)
                let descendants = entries.filter { child in
                    guard child.name != item.name else { return false }
                    let normalizedName = normalizedNames[child.name] ?? normalizedEntryName(child.name)
                    return normalizedName.hasPrefix(prefix)
                }

                let descendantFiles = descendants.filter { !$0.isDirectory }.map(\.name)
                let leafDirectories = descendants.filter { $0.isDirectory && isLeafDirectory($0) }.map(\.name)
                return descendantFiles + leafDirectories
            }
            return [item.name]
        }

        return Array(Set(names)).sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    static func normalizedDirectoryPrefix(_ name: String) -> String {
        let normalized = normalizedEntryName(name)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    static func normalizedEntryName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (name.hasSuffix("/") ? "/" : "")
    }

    private nonisolated static func fileCount(in urls: [URL]) async throws -> Int {
        try await Task.detached(priority: .utility) {
            try countRegularFiles(in: urls)
        }.value
    }

    private nonisolated static func countRegularFiles(in urls: [URL]) throws -> Int {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        return try urls.reduce(0) { count, url in
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return count + 1 }
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) else {
                    return count + 1
                }
                var fileCount = 0
                for case let fileURL as URL in enumerator {
                    try Task.checkCancellation()
                    if (try? fileURL.resourceValues(forKeys: resourceKeys).isRegularFile) == true {
                        fileCount += 1
                    }
                }
                return count + fileCount
            }
            return count + 1
        }
    }

    private static func readOutput(
        from handle: FileHandle,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        chunkHandler: ((String) throws -> Void)? = nil
    ) throws -> String {
        var output = ""
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            let text = String(decoding: data, as: UTF8.self)
            output += text
            progressParser?.consume(text)
            outputObserver?(text)
            try chunkHandler?(text)
        }
        return output
    }

    private static func parseUnzipModified(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        return formatter.date(from: text)
    }

    private static func parseSevenZipModified(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSSSSSS"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private nonisolated static func integers(in line: String) -> [Int] {
        let pattern = #"\d+"#
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: line, range: range).compactMap { match in
            guard let numberRange = Range(match.range, in: line) else { return nil }
            return Int(String(line[numberRange]))
        }
    }

    private nonisolated static func parseBenchmarkDictionaryRow(_ line: String) -> SevenZipBenchmarkDictionaryRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^\d+:"# , options: .regularExpression) != nil else { return nil }
        let values = integers(in: trimmed)
        guard values.count >= 9 else { return nil }
        let compression = SevenZipBenchmarkMetrics(
            speedKiBPerSecond: values[1],
            usagePercent: values[2],
            ratingMips: values[3],
            usageRatingMips: values[4]
        )
        let decompression = SevenZipBenchmarkMetrics(
            speedKiBPerSecond: values[5],
            usagePercent: values[6],
            ratingMips: values[7],
            usageRatingMips: values[8]
        )
        return SevenZipBenchmarkDictionaryRow(dictionaryBits: values[0], compression: compression, decompression: decompression)
    }

    private nonisolated static func parseFrequencySample(_ line: String) -> SevenZipCPUFrequencySample? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("CPU Freq (MHz):"), let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[..<colonIndex])
        let values = String(trimmed[trimmed.index(after: colonIndex)...])
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !values.isEmpty else { return nil }
        return SevenZipCPUFrequencySample(threadLabel: label, readings: values)
    }

    private nonisolated static func cpuDescriptionLine(in lines: [String], after pageSizeLine: String?) -> String? {
        guard let pageSizeLine, let pageIndex = lines.firstIndex(of: pageSizeLine) else { return nil }
        return lines
            .dropFirst(pageIndex + 1)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private nonisolated static func timeValue(in lines: [String], prefix: String) -> Double? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let pattern = #"=\s*([0-9]+(?:\.[0-9]+)?)"#
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: line, range: range),
            let valueRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return Double(line[valueRange])
    }
}

private final class ProgressOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int?
    private let progress: @Sendable (ArchiveProgressState) -> Void
    nonisolated(unsafe) private var processedFiles = 0
    nonisolated(unsafe) private var remainder = ""

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

private struct ResolvedSevenZipTool {
    let path: String
    let source: SevenZipToolSource
}

private enum ProcessInputStrategy {
    case none
    case passwordPrompts([String])
}

private struct InteractivePasswordResponder {
    private static let promptMarkers = [
        "enter password",
        "verify password",
        "reenter password",
        "password:"
    ]

    private let responses: [String]
    private var responseIndex = 0
    private var buffer = ""

    init(responses: [String]) {
        self.responses = responses
    }

    mutating func consume(_ text: String, writer: FileHandle) throws {
        guard responseIndex < responses.count else { return }
        buffer += text.lowercased()
        guard Self.promptMarkers.contains(where: buffer.contains) else {
            if buffer.count > 512 {
                buffer = String(buffer.suffix(512))
            }
            return
        }

        if let data = (responses[responseIndex] + "\n").data(using: .utf8) {
            try writer.write(contentsOf: data)
        }
        responseIndex += 1
        buffer = ""
    }
}

private final class ActiveProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private weak var activeProcess: Process?
    private var cancelledProcesses = Set<ObjectIdentifier>()

    func register(_ process: Process) {
        lock.lock()
        activeProcess = process
        cancelledProcesses.remove(ObjectIdentifier(process))
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        cancelledProcesses.remove(ObjectIdentifier(process))
        lock.unlock()
    }

    func wasCancelled(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProcesses.contains(ObjectIdentifier(process))
    }

    func cancelActiveProcess() {
        lock.lock()
        let process = activeProcess
        if let process {
            cancelledProcesses.insert(ObjectIdentifier(process))
        }
        lock.unlock()

        process?.interrupt()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
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
