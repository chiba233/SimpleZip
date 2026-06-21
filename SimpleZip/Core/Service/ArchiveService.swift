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
    /// 可打开(读取)的扩展名。后半段是**只读家族**(2026-06 实测内置 7zz 26.01):
    /// zst/tzst(zstd,7zz 只读——`a -tzstd` 实测 E_NOTIMPL;tar.zst 与 tar.gz 同款双层管道)、
    /// iso(Iso/Udf 自动识别)、cab、cpio、xar、pkg(xar 容器)。这些格式 7zz 不能写,
    /// 写门控(ArchiveWriteRestriction.readOnlyFormat)自动给出只读解释。
    // nonisolated:`resolvedArchiveInput` 等 nonisolated 路由路径要读它(后端选型);纯 String 字面量常量,无隔离需求。
    nonisolated static let supportedExtensions = [
        "zip", "7z", "tar", "gz", "tgz", "bz2", "xz", "rar", "dmg", "xip",
        "zst", "tzst", "iso", "cab", "cpio", "xar", "pkg"
    ]
    static let supportedArchiveTypes: [UTType] = supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    private enum ArchiveBackendKind {
        case zipNative
        case sevenZip
        case diskImage
        /// `.xip`：浏览 / 测试 / 选条目解压走 7zz（xar 容器），整包解压走 `/usr/bin/xip --expand`
        /// （拿真实载荷 + Apple 签名校验）。
        case xip
    }

    private struct ResolvedArchiveInput {
        let url: URL
        let backend: ArchiveBackendKind
    }

    /// 把 `ArchiveBackendKind` 映射到对应 backend 类型 —— 供 `list` / `test` 共用一个 router。
    /// `extract` / `create` 因为各 backend 参数太异质，不走这个路径，仍然用 case 分发。
    private nonisolated static func backendType(for kind: ArchiveBackendKind) -> ArchiveBackend.Type {
        switch kind {
        case .zipNative: return NativeZipBackend.self
        case .sevenZip: return SevenZipBackend.self
        case .diskImage: return DiskImageBackend.self
        // xip 的 list / test 用 7zz 的 xar 支持（秒列容器成员、校验 xar 校验和）。
        case .xip: return SevenZipBackend.self
        }
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
        RarBackend.isAvailable()
    }

    static func canUseSevenZip() -> Bool {
        SevenZipBackend.isAvailable()
    }

    // RAR 安装资源 + 本地后端管理：全部转发到 `RarBackend`。
    // 保留这层「Service 上的同名 facade」是为了不破坏调用方（Settings RAR pane / 欢迎助手 / 健康检查）API。

    static func rarInstallResourcesURL() -> URL? { RarBackend.installResourcesURL() }
    static func rarInstallReadmeURL() -> URL? { RarBackend.installReadmeURL() }
    static func rarInstallLicenseURL() -> URL? { RarBackend.installLicenseURL() }
    static func rarInstallerScriptURL() -> URL? { RarBackend.installerScriptURL() }
    static func localRarBackendURL() -> URL? { RarBackend.localBackendURL() }
    static func hasLocalRarBackend() -> Bool { RarBackend.hasLocalBackend() }
    static func deleteLocalRarBackend() throws { try RarBackend.deleteLocalBackend() }

    static func cancelRunningCommand(operationID: UUID? = nil) {
        BackendProcessRunner.cancelRunningCommand(operationID: operationID)
    }

    /// 暂停 / 继续任务的后端子进程(SIGSTOP / SIGCONT,详见 BackendProcessRunner)。
    static func suspendRunningCommand(operationID: UUID) {
        BackendProcessRunner.suspendRunningCommand(operationID: operationID)
    }

    static func resumeRunningCommand(operationID: UUID) {
        BackendProcessRunner.resumeRunningCommand(operationID: operationID)
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
            // 优先 7zz —— 压缩率 / 兼容性 / 进度都比 /usr/bin/zip 好。
            // 7zz 不可用且选项可被原生 zip 覆盖时回落 NativeZipBackend.createZipFallback。
            if SevenZipBackend.isAvailable() {
                try await SevenZipBackend.createZip(
                    destination: destination,
                    relativeNames: relativeNames,
                    options: options,
                    currentDirectory: parent,
                    progressParser: parser,
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
            try await SevenZipBackend.createSevenZip(
                destination: destination,
                relativeNames: relativeNames,
                options: options,
                currentDirectory: parent,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .rar:
            try await RarBackend.create(
                destination: destination,
                relativeNames: relativeNames,
                options: options,
                currentDirectory: parent,
                progressParser: parser,
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
            try await SevenZipBackend.createSingleFileCompressed(
                formatFlag: "gzip",
                source: try validateSingleRegularFileSource(sourceURLs, format: options.format),
                destination: destination,
                options: options,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .bzip2:
            try await SevenZipBackend.createSingleFileCompressed(
                formatFlag: "bzip2",
                source: try validateSingleRegularFileSource(sourceURLs, format: options.format),
                destination: destination,
                options: options,
                progressParser: parser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        case .xz:
            try await SevenZipBackend.createSingleFileCompressed(
                formatFlag: "xz",
                source: try validateSingleRegularFileSource(sourceURLs, format: options.format),
                destination: destination,
                options: options,
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
        knownFileCount: Int? = nil,
        operationID: UUID? = nil,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void = { _ in },
        outputObserver: (@Sendable (String) -> Void)? = nil,
        force: Bool = false
    ) async throws {
        let resolved = try resolvedInput(for: archive, force: force)
        // 进度需要「总文件数」。若调用方（已在解压前做过安全检查 = 已 list 过）传了 `knownFileCount`，
        // 就**不再重复 `7zz l -slt`** —— 大归档上这一遍 list 又慢又吐巨量输出，重复跑会让解压前 UX 像卡死。
        // 没传时才内部 list；list 现在带 operationID，能被「取消」杀掉子进程（之前传 nil 杀不掉）。
        let totalFiles: Int
        if let knownFileCount {
            totalFiles = max(1, knownFileCount)
        } else {
            let listedItems = try await list(resolved.url, password: password, operationID: operationID, force: force)
            if safetyPolicy == .validate {
                try ArchiveSafety.validateForExtraction(listedItems)
            }
            totalFiles = max(1, listedItems.filter { !$0.isDirectory }.count)
        }
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
            // #19 xattr 往返:纯 .tar 整包解压改走系统 tar(恢复 PAX xattr;7zz 会丢,自检样本实测)。
            // tar 没有密码概念;压缩 tar 壳(tgz/zst…)与选条目解压仍走 7zz。
            if resolved.url.pathExtension.lowercased() == "tar", password.isEmpty {
                try await NativeZipBackend.extractWholeTar(
                    resolved.url,
                    to: destination,
                    progressParser: parser,
                    outputObserver: outputObserver,
                    operationID: operationID
                )
            } else {
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
            }
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .diskImage:
            try await DiskImageBackend.extract(resolved.url, to: destination, progress: progress)
            if safetyPolicy == .validate {
                try ArchiveSafety.validateExtractedTree(at: destination)
            }
        case .xip:
            // 整包解压走系统 xip：拿到真实载荷（如 .app）并由系统校验 Apple 签名，
            // 不是 7zz 那两个 xar 成员（Content / Metadata）。
            try await XIPBackend.extract(
                resolved.url,
                to: destination,
                operationID: operationID,
                progress: progress,
                outputObserver: outputObserver
            )
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
        // xip 的「选条目解压」= 取出 xar 成员（Content / Metadata 原始 blob），跟浏览看到的一致；
        // 想要真实载荷（.app）请整包解压（上面的无 entries overload 走 xip --expand）。
        case .sevenZip, .xip:
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


    static func test(
        _ archive: URL,
        password: String = "",
        operationID: UUID? = nil,
        force: Bool = false,
        outputObserver: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let resolved = try resolvedInput(for: archive, force: force)
        // 0.4.3 #6:带口令的完整性测试只有 7zz 路径支持(`t` + PTY 应答,口令绝不进可见 argv)。
        // 有口令时强制走 7zz —— 调用方只在「错误表明需要口令」后才带口令重试,zip/7z 都可被 7zz 测。
        if !password.isEmpty {
            try await SevenZipBackend.test(resolved.url, password: password, operationID: operationID, outputObserver: outputObserver)
            return
        }
        try await backendType(for: resolved.backend).test(resolved.url, operationID: operationID, outputObserver: outputObserver)
    }

    /// 错误是否表明「归档需要口令 / 口令不对」(0.4.3 #6 统一密码中心的共用判定)。
    /// 模型层 shouldPromptForArchivePassword、批量测试与 Finder 批量解压的静默重试都走这一份。
    nonisolated static func errorSuggestsPasswordRequirement(_ error: Error) -> Bool {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .passwordPromptExhausted:
                return true
            case .commandFailed(let output):
                return commandOutputSuggestsPasswordRequirement(output)
            default:
                return false
            }
        }
        return commandOutputSuggestsPasswordRequirement(error.localizedDescription)
    }

    private nonisolated static func commandOutputSuggestsPasswordRequirement(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("enter password")
            || normalized.contains("wrong password")
            || normalized.contains("can not open encrypted archive")
            || normalized.contains("cannot open encrypted archive")
    }

    static func benchmark(
        options: SevenZipBenchmarkOptions,
        operationID: UUID? = nil,
        update: @escaping @Sendable (SevenZipBenchmarkReport, String) -> Void = { _, _ in }
    ) async throws -> SevenZipBenchmarkReport {
        try await SevenZipBackend.benchmark(options: options, operationID: operationID, update: update)
    }

    /// 整条 list = 子进程 `7zz l -slt` + 纯字符串解析(parseSevenZipList,大包上万条目纯 CPU 密集)。
    ///
    /// 取样实证(Swift 6 / macOS 26):光标 `nonisolated` **并不会**让函数真正 hop 到 cooperative pool ——
    /// `@MainActor` 调用方 `await` 一个 `nonisolated async` 函数时,runtime 直接在主线程跑其函数体,
    /// 子进程虽借 runAndCapture 的 continuation 在后台,但 await 返回后的解析仍回主线程,大包冻死 UI
    /// (实测 1437ms 全卡在 parseSevenZipList → DateFormatter)。**只有 `Task.detached` 才确定性保证
    /// 整段(子进程 + 解析)在后台执行**;backend metatype 与 url/password 都 Sendable,可安全捕获。
    nonisolated static func list(_ archive: URL, password: String = "", operationID: UUID? = nil, force: Bool = false) async throws -> [ArchiveItem] {
        let signpost = PerfSignpost.begin("archive.list")
        defer { PerfSignpost.end("archive.list", signpost) }
        let resolved = try resolvedInput(for: archive, force: force)
        let backend = backendType(for: resolved.backend)
        let url = resolved.url
        return try await Task.detached(priority: .userInitiated) {
            try await backend.list(url, password: password, operationID: operationID)
        }.value
    }

    // MARK: - 归档级注释（0.4.1 #114，只读旁路）

    /// 最近一次 list 解析出的「归档级注释」缓存（zip / rar 头部 Comment）。
    /// 旁路缓存而不是改 `list` 返回值：list 有 7 个调用点层层透传，为次要展示信息改签名不成比例。
    /// NSCache 线程安全；key = 归档绝对路径。后端在 list 解析时写入，UI 在 list 完成后取。
    // NSCache 本身线程安全（Apple 文档保证）；nonisolated(unsafe) 只是向严格并发检查明示这一点。
    private nonisolated(unsafe) static let headerCommentCache = NSCache<NSString, NSString>()

    nonisolated static func recordHeaderComment(_ comment: String, for url: URL) {
        if comment.isEmpty {
            headerCommentCache.removeObject(forKey: url.path as NSString)
        } else {
            headerCommentCache.setObject(comment as NSString, forKey: url.path as NSString)
        }
    }

    /// 0.4.4 #13:归档级属性(`l -slt` 头部块)。仅 7zz 可列的格式;失败抛给调用方
    /// (报告对头部块缺失宽容 —— 聚合部分照常显示)。
    static func archiveProperties(of archive: URL, password: String = "", operationID: UUID? = nil) async throws -> ArchiveProperties {
        let output = try await SevenZipBackend.rawListOutput(archive, password: password, operationID: operationID)
        return ArchiveProperties.parse(listOutput: output)
    }

    static func headerComment(for url: URL) -> String {
        (headerCommentCache.object(forKey: url.path as NSString) as String?) ?? ""
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
    private nonisolated static func resolvedInput(for url: URL, force: Bool) throws -> ResolvedArchiveInput {
        if force {
            return ResolvedArchiveInput(url: url, backend: .sevenZip)
        }
        return try resolvedArchiveInputOrThrow(for: url)
    }

    private nonisolated static func resolvedArchiveInputOrThrow(for url: URL) throws -> ResolvedArchiveInput {
        guard let resolved = resolvedArchiveInput(for: url) else {
            throw ArchiveError.unsupportedFormat
        }
        return resolved
    }

    private nonisolated static func resolvedArchiveInput(for url: URL) -> ResolvedArchiveInput? {
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
        if ext == "xip" {
            return ResolvedArchiveInput(url: url, backend: .xip)
        }
        if supportedExtensions.contains(ext) {
            if ext == "zip", hasSplitZipSidecar(for: url) {
                return ResolvedArchiveInput(url: url, backend: .sevenZip)
            }
            return ResolvedArchiveInput(url: url, backend: ext == "zip" ? .zipNative : .sevenZip)
        }
        return nil
    }

    private nonisolated static func splitZipMasterURL(for url: URL) -> URL? {
        let master = url.deletingPathExtension().appendingPathExtension("zip")
        return FileManager.default.fileExists(atPath: master.path) ? master : nil
    }

    private nonisolated static func hasSplitZipSidecar(for url: URL) -> Bool {
        let sidecar = url.deletingPathExtension().appendingPathExtension("z01")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    private nonisolated static func multipartRarMasterURL(for url: URL) -> URL? {
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

    private nonisolated static func isNumericSplitExtension(_ ext: String) -> Bool {
        ext.count == 3 && Int(ext) != nil
    }

    private nonisolated static func isRarVolumeExtension(_ ext: String) -> Bool {
        ext.range(of: #"^r\d{2}$"#, options: .regularExpression) != nil
    }

    private nonisolated static func isZipVolumeExtension(_ ext: String) -> Bool {
        ext.range(of: #"^z\d{2}$"#, options: .regularExpression) != nil
    }

    static func sevenZipBackendDescription() -> String {
        SevenZipBackend.backendDescription()
    }

    static func sevenZipVersion() async -> String {
        await SevenZipBackend.version()
    }

    static func rarBackendDescription() -> String { RarBackend.backendDescription() }
    static func rarVersion() async -> String { await RarBackend.version() }

    /// 「打开 DMG 为文件夹」流程用 —— ArchiveBrowserModel 在 mode = .archive(dmg) 时调一次。
    /// 实际工作转给 `DiskImageBackend.mount`；这里保留是为了不破坏外部 API。
    static func mountDiskImage(_ url: URL) async throws -> URL {
        try await DiskImageBackend.mount(url)
    }

    static func detachDiskImage(at mountPoint: URL) async throws {
        try await DiskImageBackend.detach(at: mountPoint)
    }

    // 7zz / RAR 候选路径列表 + 私有 resolve helper 已分别搬到 `SevenZipBackend` / `RarBackend`。

    // 下面 4 个 path-discovery helper 原本 `private`；step 3 抽 backend 时改成 `internal`
    // 让 `SevenZipBackend` / 未来的 `RarBackend` 能直接调。后续 step 把它们彻底搬到
    // 一个独立的 BackendToolDiscovery 文件里再清。

    static func applicationSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimpleZip", isDirectory: true)
    }

    nonisolated static func uniqueExistingCandidatePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    nonisolated static func envPath(for executable: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathValue
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func cellarCandidates(formula: String, tools: [String]) -> [String] {
        ["/opt/homebrew/Cellar/\(formula)", "/usr/local/Cellar/\(formula)"].flatMap { root -> [String] in
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
            return versions.flatMap { version in
                tools.map { "\(root)/\(version)/bin/\($0)" }
            }
        }
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

// 注：所有 backend 私有类型已经各自归位。
// - ProgressOutputParser / ProcessInputStrategy / InteractivePasswordResponder /
//   ActiveProcessRegistry → `BackendProcessRunner.swift`
// - DMG 的 mount / detach / list / extract / DateFormatter → `Backends/DiskImageBackend.swift`
// - ResolvedSevenZipTool / SevenZipToolSource / 7zz 路径发现 / 版本探测 → `Backends/SevenZipBackend.swift`
// - NativeZipBackend 多 backend 编排 / unzip + tar → `Backends/NativeZipBackend.swift`
// - ResolvedRarTool / RarToolSource / RAR 路径发现 / 安装资源 / 版本 / 创建 → `Backends/RarBackend.swift`
// 下一步 step 6 引入 `ArchiveBackend` 协议把 ArchiveService 转成纯路由。
