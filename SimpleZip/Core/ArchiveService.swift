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

    static func canUseSevenZip() -> Bool {
        SevenZipBackend.isAvailable()
    }

    static func rarInstallResourcesURL() -> URL? {
        Bundle.main.resourceURL
    }

    static func rarInstallReadmeURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-rar-install-readme", withExtension: "txt")
    }

    static func rarInstallLicenseURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-rar-license-notice", withExtension: "txt")
    }

    static func rarInstallerScriptURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-install-rar-backend", withExtension: "sh")
    }

    static func localRarBackendURL() -> URL? {
        applicationSupportDirectory()?.appendingPathComponent("Tools/rar")
    }

    static func hasLocalRarBackend() -> Bool {
        guard let url = localRarBackendURL() else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func deleteLocalRarBackend() throws {
        guard let toolsDirectory = applicationSupportDirectory()?.appendingPathComponent("Tools", isDirectory: true) else {
            return
        }
        let fileManager = FileManager.default
        for name in ["rar", "rar-license.txt", "rar-readme.txt"] {
            let url = toolsDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    static func cancelRunningCommand(operationID: UUID? = nil) {
        BackendProcessRunner.cancelRunningCommand(operationID: operationID)
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
            try await NativeZipBackend.createZipFallback(
                destination: destination,
                relativeNames: relativeNames,
                options: options,
                excludePatterns: zipExcludePatterns(from: options),
                currentDirectory: parent,
                progressParser: parser,
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
            try await NativeZipBackend.createTar(
                destination: destination,
                relativeNames: relativeNames,
                excludeArguments: tarExcludeArguments(from: options),
                currentDirectory: parent,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .tarGzip:
            try await NativeZipBackend.createTarGzip(
                destination: destination,
                relativeNames: relativeNames,
                excludeArguments: tarExcludeArguments(from: options),
                currentDirectory: parent,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .dmg:
            try await DiskImageBackend.create(
                from: sourceURLs,
                destination: destination,
                volumeName: destination.deletingPathExtension().lastPathComponent,
                progress: progress,
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
        outputObserver: (@Sendable (String) -> Void)? = nil,
        force: Bool = false
    ) async throws {
        let resolved = try resolvedInput(for: archive, force: force)
        let listedItems = try await list(resolved.url, password: password, force: force)
        if safetyPolicy == .validate {
            try ArchiveSafety.validateForExtraction(listedItems)
        }
        let totalFiles = max(1, listedItems.filter { !$0.isDirectory }.count)
        let parser = ProgressOutputParser(totalFiles: totalFiles, progress: progress)
        switch resolved.backend {
        case .zipNative:
            try await NativeZipBackend.extract(
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
            try await SevenZipBackend.extract(
                resolved.url,
                entries: [],
                to: destination,
                overwriteBehavior: overwriteBehavior,
                pathMode: .preserve,
                password: password,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .diskImage:
            try await DiskImageBackend.extract(resolved.url, to: destination, progress: progress)
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
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
        outputObserver: (@Sendable (String) -> Void)? = nil,
        force: Bool = false
    ) async throws {
        let resolved = try resolvedInput(for: archive, force: force)
        if safetyPolicy == .validate {
            try ArchiveSafety.validateForExtraction(entries)
        }
        let entryNames = expandedEntryNames(for: entries)
        guard !entryNames.isEmpty else { return }
        let parser = ProgressOutputParser(totalFiles: max(1, entryNames.count), progress: progress)

        switch resolved.backend {
        case .zipNative:
            try await NativeZipBackend.extract(
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
            try await SevenZipBackend.extract(
                resolved.url,
                entries: entryNames,
                to: destination,
                overwriteBehavior: overwriteBehavior,
                pathMode: pathMode,
                password: password,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .diskImage:
            throw ArchiveError.unsupportedFormat
        }
    }


    static func test(_ archive: URL, operationID: UUID? = nil, force: Bool = false) async throws {
        let resolved = try resolvedInput(for: archive, force: force)
        switch resolved.backend {
        case .zipNative:
            try await NativeZipBackend.test(resolved.url, operationID: operationID)
        case .sevenZip:
            try await SevenZipBackend.test(resolved.url, operationID: operationID)
        case .diskImage:
            try await DiskImageBackend.test(resolved.url)
        }
    }

    static func benchmark(
        options: SevenZipBenchmarkOptions,
        operationID: UUID? = nil,
        update: @escaping @Sendable (SevenZipBenchmarkReport, String) -> Void = { _, _ in }
    ) async throws -> SevenZipBenchmarkReport {
        try await SevenZipBackend.benchmark(options: options, operationID: operationID, update: update)
    }

    static func list(_ archive: URL, password: String = "", force: Bool = false) async throws -> [ArchiveItem] {
        let resolved = try resolvedInput(for: archive, force: force)
        switch resolved.backend {
        case .zipNative:
            return try await NativeZipBackend.list(resolved.url)
        case .sevenZip:
            return try await SevenZipBackend.list(resolved.url, password: password)
        case .diskImage:
            return try await DiskImageBackend.list(resolved.url)
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

    /// 给上层入口统一选 backend。
    /// - `force = false`：走原来的扩展名 → backend 路由（支持的扩展名才能用）。
    /// - `force = true`：跳过扩展名校验，强制按 7-Zip 后端处理。
    ///   用例：用户在 Finder 右键「以压缩包打开」一个 .exe / .apk / .ipa 之类的文件 ——
    ///   这些本质上是 ZIP / NSIS / CAB，但扩展名不在白名单里，
    ///   通过用户明确意图（右键菜单项）跳过检查，让 7zz 自己按文件头探测。
    private static func resolvedInput(for url: URL, force: Bool) throws -> ResolvedArchiveInput {
        if force {
            return ResolvedArchiveInput(url: url, backend: .sevenZip)
        }
        return try resolvedArchiveInputOrThrow(for: url)
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
        SevenZipBackend.backendDescription()
    }

    static func sevenZipVersion() async -> String {
        await SevenZipBackend.version()
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

    /// 转发到 `SevenZipBackend.toolPath()`。
    /// 留在 ArchiveService 里是因为下面 list / extract / test / 创建归档等 case 分支
    /// 用了大量 `try sevenZipTool()` 调用 —— 等 step 3b 把那些动作也搬到 SevenZipBackend
    /// 里之后，这个 thin wrapper 也可以一起删掉。
    private static func sevenZipTool() throws -> String {
        try SevenZipBackend.toolPath()
    }

    private static func resolvedSevenZipTool() throws -> ResolvedSevenZipTool {
        try SevenZipBackend.resolve()
    }

    private static func rarTool() throws -> String {
        try resolvedRarTool().path
    }

    private static func resolvedRarTool() throws -> ResolvedRarTool {
        let candidates: [ResolvedRarTool]
        switch AppPreferences.rarBackend {
        case .automatic:
            candidates = localRarCandidates + systemRarCandidates
        case .bundled:
            candidates = localRarCandidates + systemRarCandidates
        case .system:
            candidates = systemRarCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingRarTool
    }

    /// 「打开 DMG 为文件夹」流程用 —— ArchiveBrowserModel 在 mode = .archive(dmg) 时调一次。
    /// 实际工作转给 `DiskImageBackend.mount`；这里保留是为了不破坏外部 API。
    static func mountDiskImage(_ url: URL) async throws -> URL {
        try await DiskImageBackend.mount(url)
    }

    static func detachDiskImage(at mountPoint: URL) async throws {
        try await DiskImageBackend.detach(at: mountPoint)
    }

    // 7zz 候选路径列表（bundled / system）已搬到 `SevenZipBackend`。

    private static var localRarCandidates: [ResolvedRarTool] {
        uniqueExistingCandidatePaths(
            [
                applicationSupportDirectory()?.appendingPathComponent("Tools/rar").path
            ].compactMap { $0 }
        ).map { ResolvedRarTool(path: $0, source: .local) }
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

    // 下面 4 个 path-discovery helper 原本 `private`；step 3 抽 backend 时改成 `internal`
    // 让 `SevenZipBackend` / 未来的 `RarBackend` 能直接调。后续 step 把它们彻底搬到
    // 一个独立的 BackendToolDiscovery 文件里再清。

    static func applicationSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimpleZip", isDirectory: true)
    }

    static func uniqueExistingCandidatePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    static func envPath(for executable: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathValue
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cellarCandidates(formula: String, tools: [String]) -> [String] {
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

    /// 进程基础设施已搬到 `BackendProcessRunner` —— 这里给一个 type-aliased 转调入口，
    /// ArchiveService 内大量 `runAndCapture(...)` 调用就不用一个一个改前缀。
    private static func runAndCapture(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        progressParser: ProgressOutputParser? = nil,
        inputStrategy: ProcessInputStrategy = .none,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        operationID: UUID? = nil
    ) async throws -> String {
        try await BackendProcessRunner.runAndCapture(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
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


}

// 注：
// - ProgressOutputParser / ProcessInputStrategy / InteractivePasswordResponder /
//   ActiveProcessRegistry → `BackendProcessRunner.swift`
// - DMG 的 mount / detach / list / extract / DateFormatter → `Backends/DiskImageBackend.swift`
// - ResolvedSevenZipTool / SevenZipToolSource / 7zz 路径发现 / 版本探测 → `Backends/SevenZipBackend.swift`
// 这里还留着的是 RAR 后端相关 —— 等 Phase 4 step 3c 抽 RarBackend 时再一并搬走。

private struct ResolvedRarTool {
    let path: String
    let source: RarToolSource
}

private enum RarToolSource {
    case local
    case system

    var title: String {
        switch self {
        case .local:
            return L10n.text("settings.rar.source.local")
        case .system:
            return L10n.text("settings.rar.source.system")
        }
    }
}
