//
//  ArchiveService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Darwin
import Foundation
import UniformTypeIdentifiers

private enum ArchiveServiceProcessRegistry {
    nonisolated static let shared = ActiveProcessRegistry()
}

/// 归档命令服务：封装 zip/unzip/7zz 调用，让界面层不直接接触命令行细节。
enum ArchiveService {
    static let supportedExtensions = ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz", "rar", "dmg"]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    private enum ArchiveBackendKind {
        case zipNative
        case sevenZip
        case diskImage
    }

    private struct ResolvedArchiveInput {
        let url: URL
        let backend: ArchiveBackendKind
    }

    enum ExtractionSafetyPolicy {
        case validate
        case skipValidation
    }
    
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
        resolvedArchiveInput(for: url) != nil
    }

    static func supportedArchiveURL(_ url: URL) -> URL? {
        resolvedArchiveInput(for: url)?.url
    }

    static func canCreateRAR() -> Bool {
        (try? rarTool()) != nil
    }

    static func createZipArchive(from sourceURLs: [URL], destination: URL) async throws {
        try await createArchive(from: sourceURLs, destination: destination, options: ArchiveCreationOptions())
    }

    static func cancelRunningCommand(operationID: UUID? = nil) {
        ArchiveServiceProcessRegistry.shared.cancelProcess(operationID: operationID)
    }

    static func createArchive(
        from sourceURLs: [URL],
        destination: URL,
        options: ArchiveCreationOptions,
        operationID: UUID? = nil,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in },
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard let first = sourceURLs.first else { return }
        if !options.password.isEmpty, options.password != options.passwordConfirmation {
            throw ArchiveError.passwordsDoNotMatch
        }
        let parent = first.deletingLastPathComponent()
        let relativeNames = sourceURLs.map { $0.lastPathComponent }
        progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.countingFiles")))
        let totalFiles = max(1, try await fileCount(in: sourceURLs))
        try Task.checkCancellation()
        let parser = ProgressOutputParser(totalFiles: totalFiles, progress: progress)

        switch options.format {
        case .zip:
            if let tool = try? sevenZipTool() {
                let arguments = try sevenZipZipCreateArguments(
                    destination: destination,
                    relativeNames: relativeNames,
                    options: options
                )
                let inputStrategy: ProcessInputStrategy = options.password.isEmpty ? .none : .passwordPrompts(passwordResponses(for: options))
                try await run(
                    tool,
                    arguments: arguments,
                    currentDirectory: parent,
                    progressParser: parser,
                    inputStrategy: inputStrategy,
                    outputObserver: outputObserver,
                    operationID: operationID
                )
                return
            }
            guard nativeZipFallbackSupported(for: options) else {
                throw ArchiveError.missingSevenZip
            }
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
            try await run(
                "/usr/bin/zip",
                arguments: arguments,
                currentDirectory: parent,
                progressParser: parser,
                inputStrategy: inputStrategy,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .sevenZip:
            let tool = try sevenZipTool()
            let arguments = try sevenZipCreateArguments(destination: destination, relativeNames: relativeNames, options: options)
            let inputStrategy: ProcessInputStrategy = options.password.isEmpty ? .none : .passwordPrompts(passwordResponses(for: options))
            try await run(
                tool,
                arguments: arguments,
                currentDirectory: parent,
                progressParser: parser,
                inputStrategy: inputStrategy,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .rar:
            let tool = try rarTool()
            let arguments = try rarCreateArguments(destination: destination, relativeNames: relativeNames, options: options)
            let inputStrategy: ProcessInputStrategy = options.password.isEmpty ? .none : .passwordPrompts(passwordResponses(for: options))
            try await run(
                tool,
                arguments: arguments,
                currentDirectory: parent,
                progressParser: parser,
                inputStrategy: inputStrategy,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .tar:
            try await run(
                "/usr/bin/tar",
                arguments: ["-cvf", destination.path] + tarExcludeArguments(from: options) + relativeNames,
                currentDirectory: parent,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .tarGzip:
            try await run(
                "/usr/bin/tar",
                arguments: ["-czvf", destination.path] + tarExcludeArguments(from: options) + relativeNames,
                currentDirectory: parent,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .gzip:
            let sourceURL = try validateSingleRegularFileSource(sourceURLs, format: options.format)
            let tool = try sevenZipTool()
            try await run(
                tool,
                arguments: ["a", "-tgzip", "-mx=\(options.compressionLevel.rawValue)", destination.path, sourceURL.lastPathComponent, "-bb1", "-bsp1", "-y"],
                currentDirectory: sourceURL.deletingLastPathComponent(),
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .bzip2:
            let sourceURL = try validateSingleRegularFileSource(sourceURLs, format: options.format)
            let tool = try sevenZipTool()
            try await run(
                tool,
                arguments: ["a", "-tbzip2", "-mx=\(options.compressionLevel.rawValue)", destination.path, sourceURL.lastPathComponent, "-bb1", "-bsp1", "-y"],
                currentDirectory: sourceURL.deletingLastPathComponent(),
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .xz:
            let sourceURL = try validateSingleRegularFileSource(sourceURLs, format: options.format)
            let tool = try sevenZipTool()
            try await run(
                tool,
                arguments: ["a", "-txz", "-mx=\(options.compressionLevel.rawValue)", destination.path, sourceURL.lastPathComponent, "-bb1", "-bsp1", "-y"],
                currentDirectory: sourceURL.deletingLastPathComponent(),
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        }
    }

    static func extract(
        _ archive: URL,
        to destination: URL,
        overwriteBehavior: OverwriteBehavior = .overwrite,
        password: String = "",
        zipDecryptionMethod: ArchiveDecryptionMethod = .automatic,
        safetyPolicy: ExtractionSafetyPolicy = .validate,
        operationID: UUID? = nil,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in },
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let resolved = try resolvedArchiveInputOrThrow(for: archive)
        if safetyPolicy == .validate {
            try ArchiveSafety.validateForExtraction(try await list(resolved.url))
        }
        let parser = ProgressOutputParser(totalFiles: nil, progress: progress)
        switch resolved.backend {
        case .zipNative:
            try await extractZipArchive(
                resolved.url,
                entries: [],
                to: destination,
                overwriteBehavior: overwriteBehavior,
                pathMode: .preserve,
                password: password,
                zipDecryptionMethod: zipDecryptionMethod,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .sevenZip:
            let tool = try sevenZipTool()
            let arguments = sevenZipExtractArguments(
                command: "x",
                archive: resolved.url,
                entries: [],
                destination: destination,
                overwriteBehavior: overwriteBehavior,
                password: password
            )
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run(tool, arguments: arguments, progressParser: parser, inputStrategy: inputStrategy, outputObserver: outputObserver, operationID: operationID)
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .diskImage:
            let mountPoint = try await mountDiskImage(resolved.url)
            do {
                try copyDiskImageContents(from: mountPoint, to: destination, progress: progress)
                if safetyPolicy == .validate {
                    try ArchiveSafety.validateExtractedTree(at: destination)
                }
                try await detachDiskImage(at: mountPoint)
            } catch {
                try? await detachDiskImage(at: mountPoint)
                throw error
            }
        }
    }

    static func extract(
        _ archive: URL,
        entries: [ArchiveItem],
        to destination: URL,
        overwriteBehavior: OverwriteBehavior = .overwrite,
        pathMode: ExtractPathMode = .preserve,
        password: String = "",
        zipDecryptionMethod: ArchiveDecryptionMethod = .automatic,
        safetyPolicy: ExtractionSafetyPolicy = .validate,
        operationID: UUID? = nil,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in },
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let resolved = try resolvedArchiveInputOrThrow(for: archive)
        if safetyPolicy == .validate {
            try ArchiveSafety.validateForExtraction(entries)
        }
        let entryNames = expandedEntryNames(for: entries)
        guard !entryNames.isEmpty else { return }
        let parser = ProgressOutputParser(totalFiles: max(1, entryNames.count), progress: progress)

        switch resolved.backend {
        case .zipNative:
            try await extractZipArchive(
                resolved.url,
                entries: entryNames,
                to: destination,
                overwriteBehavior: overwriteBehavior,
                pathMode: pathMode,
                password: password,
                zipDecryptionMethod: zipDecryptionMethod,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
            if pathMode == .flatten {
                try flattenExtractedItems(entryNames: entryNames, in: destination)
            }
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .sevenZip:
            let tool = try sevenZipTool()
            let arguments = sevenZipExtractArguments(
                command: pathMode == .flatten ? "e" : "x",
                archive: resolved.url,
                entries: entryNames,
                destination: destination,
                overwriteBehavior: overwriteBehavior,
                password: password
            )
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run(tool, arguments: arguments, progressParser: parser, inputStrategy: inputStrategy, outputObserver: outputObserver, operationID: operationID)
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .diskImage:
            throw ArchiveError.unsupportedFormat
        }
    }


    static func test(_ archive: URL, operationID: UUID? = nil) async throws {
        let resolved = try resolvedArchiveInputOrThrow(for: archive)
        switch resolved.backend {
        case .zipNative:
            try await run("/usr/bin/unzip", arguments: ["-t", resolved.url.path], operationID: operationID)
        case .sevenZip:
            let tool = try sevenZipTool()
            try await run(tool, arguments: ["t", resolved.url.path], operationID: operationID)
        case .diskImage:
            let mountPoint = try await mountDiskImage(resolved.url)
            try await detachDiskImage(at: mountPoint)
        }
    }

    static func benchmark(
        options: SevenZipBenchmarkOptions,
        operationID: UUID? = nil,
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
        }, operationID: operationID)
        return parseSevenZipBenchmark(
            output,
            backendDescription: L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path),
            options: options
        )
    }

    static func list(_ archive: URL) async throws -> [ArchiveItem] {
        let resolved = try resolvedArchiveInputOrThrow(for: archive)
        switch resolved.backend {
        case .zipNative:
            let unzipOutput = try await runAndCapture("/usr/bin/unzip", arguments: ["-l", resolved.url.path])
            let tarOutput = try await runAndCapture("/usr/bin/tar", arguments: ["-tf", resolved.url.path])
            return parseZipList(tarOutput: tarOutput, unzipOutput: unzipOutput)
        case .sevenZip:
            let tool = try sevenZipTool()
            let output = try await runAndCapture(tool, arguments: ["l", "-slt", resolved.url.path])
            return parseSevenZipList(output)
        case .diskImage:
            let mountPoint = try await mountDiskImage(resolved.url)
            do {
                let items = try diskImageArchiveItems(at: mountPoint)
                try await detachDiskImage(at: mountPoint)
                return items
            } catch {
                try? await detachDiskImage(at: mountPoint)
                throw error
            }
        }
    }

    private static func validateSingleRegularFileSource(_ sourceURLs: [URL], format: ArchiveCreateFormat) throws -> URL {
        guard format.requiresSingleRegularFile, sourceURLs.count == 1 else {
            throw ArchiveError.singleFileCompressionRequiresSingleFile
        }
        let sourceURL = sourceURLs[0]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ArchiveError.singleFileCompressionRequiresSingleFile
        }
        return sourceURL
    }

    private static func resolvedArchiveInputOrThrow(for url: URL) throws -> ResolvedArchiveInput {
        guard let resolved = resolvedArchiveInput(for: url) else {
            throw ArchiveError.unsupportedFormat
        }
        return resolved
    }

    private static func resolvedArchiveInput(for url: URL) -> ResolvedArchiveInput? {
        let ext = url.pathExtension.lowercased()
        if isNumericSplitExtension(ext) {
            let firstPart = url.deletingPathExtension().appendingPathExtension("001")
            if FileManager.default.fileExists(atPath: firstPart.path) {
                return ResolvedArchiveInput(url: firstPart, backend: .sevenZip)
            }
        }
        if isZipVolumeExtension(ext), let master = splitZipMasterURL(for: url) {
            return ResolvedArchiveInput(url: master, backend: .sevenZip)
        }
        if isRarVolumeExtension(ext) {
            let firstPart = url.deletingPathExtension().appendingPathExtension("rar")
            if FileManager.default.fileExists(atPath: firstPart.path) {
                return ResolvedArchiveInput(url: firstPart, backend: .sevenZip)
            }
        }
        if ext == "rar", let firstPart = multipartRarMasterURL(for: url) {
            return ResolvedArchiveInput(url: firstPart, backend: .sevenZip)
        }
        if ext == "dmg" {
            return ResolvedArchiveInput(url: url, backend: .diskImage)
        }
        if supportedExtensions.contains(ext) {
            if ext == "zip", hasSplitZipSidecar(for: url) {
                return ResolvedArchiveInput(url: url, backend: .sevenZip)
            }
            return ResolvedArchiveInput(url: url, backend: ext == "zip" ? .zipNative : .sevenZip)
        }
        return nil
    }

    private static func splitZipMasterURL(for url: URL) -> URL? {
        let master = url.deletingPathExtension().appendingPathExtension("zip")
        return FileManager.default.fileExists(atPath: master.path) ? master : nil
    }

    private static func hasSplitZipSidecar(for url: URL) -> Bool {
        let sidecar = url.deletingPathExtension().appendingPathExtension("z01")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    private static func multipartRarMasterURL(for url: URL) -> URL? {
        let name = url.lastPathComponent
        let range = NSRange(location: 0, length: name.utf16.count)
        guard
            let expression = try? NSRegularExpression(pattern: #"(?i)^(.*?\.part)(\d+)\.rar$"#),
            let match = expression.firstMatch(in: name, options: [], range: range),
            match.numberOfRanges == 3,
            let prefixRange = Range(match.range(at: 1), in: name),
            let digitsRange = Range(match.range(at: 2), in: name)
        else {
            return nil
        }
        let digits = String(name[digitsRange])
        guard let partNumber = Int(digits), partNumber > 1 else { return nil }
        let masterDigits = String(format: "%0*d", digits.count, 1)
        let masterName = "\(name[prefixRange])\(masterDigits).rar"
        let masterURL = url.deletingLastPathComponent().appendingPathComponent(masterName)
        return FileManager.default.fileExists(atPath: masterURL.path) ? masterURL : nil
    }

    private static func isNumericSplitExtension(_ ext: String) -> Bool {
        ext.count == 3 && Int(ext) != nil
    }

    private static func isRarVolumeExtension(_ ext: String) -> Bool {
        ext.range(of: #"^r\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isZipVolumeExtension(_ ext: String) -> Bool {
        ext.range(of: #"^z\d{2}$"#, options: .regularExpression) != nil
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

    static func rarBackendDescription() -> String {
        do {
            let tool = try resolvedRarTool()
            return L10n.format("settings.rar.resolvedPath", tool.source.title, tool.path)
        } catch {
            return L10n.text("settings.rar.notFound")
        }
    }

    static func rarVersion() async -> String {
        do {
            let tool = try resolvedRarTool()
            do {
                let output = try await runAndCapture(tool.path, arguments: [])
                let firstLine = output
                    .split(separator: "\n")
                    .map(String.init)
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    ?? tool.path
                return L10n.format("settings.rar.resolvedVersion", tool.source.title, firstLine)
            } catch {
                return L10n.format("settings.rar.resolvedVersion", tool.source.title, tool.path)
            }
        } catch {
            return L10n.text("settings.rar.notFound")
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

    private static func rarTool() throws -> String {
        try resolvedRarTool().path
    }

    private static func resolvedRarTool() throws -> ResolvedRarTool {
        let candidates: [ResolvedRarTool]
        switch AppPreferences.rarBackend {
        case .automatic:
            candidates = bundledRarCandidates + systemRarCandidates
        case .bundled:
            candidates = bundledRarCandidates
        case .system:
            candidates = systemRarCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingRarTool
    }

    static func mountDiskImage(_ url: URL) async throws -> URL {
        let output = try await runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-plist", "-readonly", "-nobrowse", "-noverify", "-noautoopen", url.path],
            currentDirectory: nil,
            progressParser: nil,
            inputStrategy: .none,
            outputObserver: nil
        )
        guard
            let data = output.data(using: .utf8),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw ArchiveError.commandFailed(output)
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw ArchiveError.commandFailed(output)
    }

    static func detachDiskImage(at mountPoint: URL) async throws {
        _ = try await runAndCapture(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint.path, "-force"],
            currentDirectory: nil,
            progressParser: nil,
            inputStrategy: .none,
            outputObserver: nil
        )
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

    private static var bundledRarCandidates: [ResolvedRarTool] {
        uniqueExistingCandidatePaths(
            [
                Bundle.main.resourceURL?.appendingPathComponent("Tools/rar").path,
                Bundle.main.resourceURL?.appendingPathComponent("rar").path,
                FileManager.default.currentDirectoryPath + "/SimpleZip/Tools/rar"
            ].compactMap { $0 }
        ).map { ResolvedRarTool(path: $0, source: .bundled) }
    }

    private static var systemRarCandidates: [ResolvedRarTool] {
        uniqueExistingCandidatePaths(
            [
                "/Applications/RAR.app/Contents/MacOS/RAR",
                "/Applications/RAR.app/Contents/MacOS/rar",
                "/Applications/WinRAR.app/Contents/MacOS/RAR",
                "/Applications/WinRAR.app/Contents/MacOS/rar",
                "/opt/homebrew/bin/rar",
                "/usr/local/bin/rar",
                envPath(for: "rar")
            ].compactMap { $0 }
        ).map { ResolvedRarTool(path: $0, source: .system) }
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
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathValue
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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
        inputStrategy: ProcessInputStrategy = .none,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        operationID: UUID? = nil
    ) async throws {
        _ = try await runAndCapture(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    nonisolated static func zipExcludePatterns(from options: ArchiveCreationOptions) -> [String] {
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

    private enum ZipExtractionTool {
        case sevenZip
        case macOS
    }

    private static func zipExtractionTools(
        for method: ArchiveDecryptionMethod,
        detectedEncryption: ZipEncryptionDetection,
        password: String
    ) -> [ZipExtractionTool] {
        switch method {
        case .automatic:
            guard !password.isEmpty else {
                return [.macOS, .sevenZip]
            }
            switch detectedEncryption {
            case .aes128, .aes192, .aes256:
                return [.sevenZip]
            case .zipCrypto:
                return [.macOS, .sevenZip]
            case .none:
                return [.macOS, .sevenZip]
            case .mixed, .unknown:
                return [.sevenZip, .macOS]
            }
        case .aes128, .aes192, .aes256:
            return [.sevenZip]
        case .zipCrypto:
            return [.macOS, .sevenZip]
        }
    }

    private static func extractZipArchive(
        _ archive: URL,
        entries: [String],
        to destination: URL,
        overwriteBehavior: OverwriteBehavior,
        pathMode: ExtractPathMode,
        password: String,
        zipDecryptionMethod: ArchiveDecryptionMethod,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        var firstError: Error?
        let detectedEncryption = detectZipEncryption(in: archive)
        let tools = zipExtractionTools(
            for: zipDecryptionMethod,
            detectedEncryption: detectedEncryption,
            password: password
        )

        for (index, tool) in tools.enumerated() {
            do {
                switch tool {
                case .sevenZip:
                    try await extractZipArchiveWithSevenZip(
                        archive,
                        entries: entries,
                        to: destination,
                        overwriteBehavior: overwriteBehavior,
                        pathMode: pathMode,
                        password: password,
                        progressParser: progressParser,
                        outputObserver: outputObserver,
                        operationID: operationID
                    )
                case .macOS:
                    try await extractZipArchiveWithMacOS(
                        archive,
                        entries: entries,
                        to: destination,
                        overwriteBehavior: overwriteBehavior,
                        pathMode: pathMode,
                        password: password,
                        progressParser: progressParser,
                        outputObserver: outputObserver,
                        operationID: operationID
                    )
                }
                return
            } catch {
                if firstError == nil {
                    firstError = error
                }
                guard zipDecryptionMethod == .automatic || zipDecryptionMethod == .zipCrypto, index < tools.count - 1 else {
                    throw error
                }
                outputObserver?("\nSimpleZip: \(zipExtractionToolName(tool)) failed; trying another ZIP decryption path.\n")
            }
        }

        throw firstError ?? ArchiveError.unsupportedFormat
    }

    private static func extractZipArchiveWithSevenZip(
        _ archive: URL,
        entries: [String],
        to destination: URL,
        overwriteBehavior: OverwriteBehavior,
        pathMode: ExtractPathMode,
        password: String,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let tool = try sevenZipTool()
        let arguments = sevenZipExtractArguments(
            command: pathMode == .flatten ? "e" : "x",
            archive: archive,
            entries: entries,
            destination: destination,
            overwriteBehavior: overwriteBehavior,
            password: password
        )
        let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
        try await run(
            tool,
            arguments: arguments,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    private static func extractZipArchiveWithMacOS(
        _ archive: URL,
        entries: [String],
        to destination: URL,
        overwriteBehavior: OverwriteBehavior,
        pathMode: ExtractPathMode,
        password: String,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        if entries.isEmpty {
            let arguments = [unzipOverwriteArgument(for: overwriteBehavior), archive.path, "-d", destination.path]
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            try await run(
                "/usr/bin/unzip",
                arguments: arguments,
                progressParser: progressParser,
                inputStrategy: inputStrategy,
                outputObserver: outputObserver,
                operationID: operationID
            )
            return
        }

        if password.isEmpty {
            var arguments = ["-xvf", archive.path, "-C", destination.path]
            if overwriteBehavior == .skipExisting {
                arguments.insert("-k", at: 0)
            }
            arguments.append(contentsOf: entries)
            try await run(
                "/usr/bin/tar",
                arguments: arguments,
                progressParser: progressParser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        } else {
            var arguments = [unzipOverwriteArgument(for: overwriteBehavior), archive.path]
            arguments.append(contentsOf: entries)
            arguments.append(contentsOf: ["-d", destination.path])
            try await run(
                "/usr/bin/unzip",
                arguments: arguments,
                progressParser: progressParser,
                inputStrategy: .passwordPrompts([password]),
                outputObserver: outputObserver,
                operationID: operationID
            )
        }
    }

    private static func zipExtractionToolName(_ tool: ZipExtractionTool) -> String {
        switch tool {
        case .sevenZip:
            return "7-Zip"
        case .macOS:
            return "macOS"
        }
    }

    private static func copyDiskImageContents(
        from mountPoint: URL,
        to destination: URL,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void
    ) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        let total = max(1, items.count)
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            progress(
                ArchiveProgressState(
                    fraction: Double(index) / Double(total),
                    currentFile: item.lastPathComponent,
                    statusText: nil
                )
            )
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: target)
        }
        progress(ArchiveProgressState(fraction: 1, currentFile: nil, statusText: nil))
    }

    private static func diskImageArchiveItems(at mountPoint: URL) throws -> [ArchiveItem] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: Array(resourceKeys))
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
                let isDirectory = values.isDirectory == true
                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate
                return ArchiveItem(
                    name: url.lastPathComponent + (isDirectory ? "/" : ""),
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : size,
                    modified: modified,
                    sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    modifiedText: modified.map(DiskImageDateFormatter.shared.string(from:)) ?? "",
                    method: ""
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
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
        outputObserver: (@Sendable (String) -> Void)? = nil,
        operationID: UUID? = nil
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try runAndCaptureSync(
                        executable,
                        arguments: arguments,
                        currentDirectory: currentDirectory,
                        progressParser: progressParser,
                        inputStrategy: inputStrategy,
                        outputObserver: outputObserver,
                        operationID: operationID
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func runAndCaptureSync(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        inputStrategy: ProcessInputStrategy,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) throws -> String {
        switch inputStrategy {
        case .none:
            return try runWithPipe(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .passwordPrompts(let responses):
            return try runWithPseudoTerminal(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                promptResponder: InteractivePasswordResponder(responses: responses),
                outputObserver: outputObserver,
                operationID: operationID
            )
        }
    }

    private nonisolated static func runWithPipe(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let ioPipe = Pipe()
        process.standardOutput = ioPipe
        process.standardError = ioPipe

        ArchiveServiceProcessRegistry.shared.register(process, operationID: operationID)
        defer { ArchiveServiceProcessRegistry.shared.clear(process) }
        try process.run()
        let output = try readOutput(from: ioPipe.fileHandleForReading, progressParser: progressParser, outputObserver: outputObserver)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if ArchiveServiceProcessRegistry.shared.wasCancelled(process) {
                throw CancellationError()
            }
            throw ArchiveError.commandFailed(output)
        }

        progressParser?.finish()
        return output
    }

    private nonisolated static func runWithPseudoTerminal(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        promptResponder: InteractivePasswordResponder,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
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

        ArchiveServiceProcessRegistry.shared.register(process, operationID: operationID)
        defer { ArchiveServiceProcessRegistry.shared.clear(process) }
        try process.run()
        try? slaveHandle.close()
        let output: String
        do {
            output = try readOutput(from: masterHandle, progressParser: progressParser, outputObserver: outputObserver) { text in
                try responder.consume(text, writer: masterHandle)
            }
        } catch {
            terminateAndWait(process)
            throw error
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if ArchiveServiceProcessRegistry.shared.wasCancelled(process) {
                throw CancellationError()
            }
            throw ArchiveError.commandFailed(output)
        }

        progressParser?.finish()
        return output
    }

    private nonisolated static func terminateAndWait(_ process: Process, timeout: TimeInterval = 2) {
        if process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
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

    private nonisolated static func readOutput(
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

private struct ResolvedRarTool {
    let path: String
    let source: RarToolSource
}

private enum ProcessInputStrategy {
    case none
    case passwordPrompts([String])
}

private struct InteractivePasswordResponder {
    nonisolated private static let promptMarkers = [
        "enter password",
        "verify password",
        "reenter password",
        "password:"
    ]

    private let responses: [String]
    private var responseIndex = 0
    private var buffer = ""

    nonisolated init(responses: [String]) {
        self.responses = responses
    }

    nonisolated mutating func consume(_ text: String, writer: FileHandle) throws {
        buffer += text.lowercased()
        guard Self.promptMarkers.contains(where: buffer.contains) else {
            if buffer.count > 512 {
                buffer = String(buffer.suffix(512))
            }
            return
        }

        guard responseIndex < responses.count else {
            throw ArchiveError.passwordPromptExhausted
        }

        if let data = (responses[responseIndex] + "\n").data(using: .utf8) {
            try writer.write(contentsOf: data)
        }
        responseIndex += 1
        buffer = ""
    }
}

private enum DiskImageDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private final class ActiveProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private weak var activeProcess: Process?
    nonisolated(unsafe) private var processesByOperationID: [UUID: Process] = [:]
    nonisolated(unsafe) private var operationIDsByProcess = [ObjectIdentifier: UUID]()
    nonisolated(unsafe) private var cancelledProcesses = Set<ObjectIdentifier>()

    nonisolated func register(_ process: Process, operationID: UUID?) {
        lock.lock()
        activeProcess = process
        let processID = ObjectIdentifier(process)
        cancelledProcesses.remove(processID)
        if let operationID {
            processesByOperationID[operationID] = process
            operationIDsByProcess[processID] = operationID
        }
        lock.unlock()
    }

    nonisolated func clear(_ process: Process) {
        lock.lock()
        let processID = ObjectIdentifier(process)
        if activeProcess === process {
            activeProcess = nil
        }
        if let operationID = operationIDsByProcess.removeValue(forKey: processID),
           processesByOperationID[operationID] === process {
            processesByOperationID.removeValue(forKey: operationID)
        }
        cancelledProcesses.remove(processID)
        lock.unlock()
    }

    nonisolated func wasCancelled(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProcesses.contains(ObjectIdentifier(process))
    }

    nonisolated func cancelProcess(operationID: UUID?) {
        lock.lock()
        let process: Process?
        if let operationID {
            process = processesByOperationID[operationID]
        } else {
            process = activeProcess
        }
        if let process {
            cancelledProcesses.insert(ObjectIdentifier(process))
        }
        lock.unlock()

        process.map(requestStop)
    }

    private nonisolated func requestStop(_ process: Process) {
        process.interrupt()
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
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

private enum RarToolSource {
    case bundled
    case system

    var title: String {
        switch self {
        case .bundled:
            return L10n.text("settings.rar.source.bundled")
        case .system:
            return L10n.text("settings.rar.source.system")
        }
    }
}
