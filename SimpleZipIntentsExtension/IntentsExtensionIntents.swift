//
//  IntentsExtensionIntents.swift
//  SimpleZipIntentsExtension
//
//  在 App Intents 扩展进程里声明的全部「干活」intent —— 跑在轻量沙箱扩展里,**不拉起完整 app**(根治
//  Shortcuts「Couldn't communicate with a helper application」超时:macOS 26 要求 App Intents 扩展沙箱化才注册,
//  注册后系统在扩展进程跑 perform,不再启动完整 UI app)。
//
//  与 app target 版的差异(都是「沙箱无人值守扩展」的必然取舍,不是分叉):
//  · 不记 TaskCenter / 活动中心、不用 ProgressCoalescer —— Shortcuts 自己有运行反馈;
//  · `.siz` / `.szs` 签名容器不支持(需 GPG 验签 + 交互同意 UI)—— 明确报错引导去 app 打开;
//  · 加密归档不读 app 预设密码(沙箱读不到),改由 intent 的**可选 `password` 参数** + 需要时
//    `$password.needsValueError()` 弹窗补口令(Shortcuts 常是有人运行的脚本)。
//  复用 SimpleZip/Core(ArchiveService / HashService / 各分析器),不造平行引擎。
//
//  代码形:`withIntent*Access` 闭包只算并返回**数据**,`.result(...)` 在 perform 末尾(闭包外)构造 ——
//  opaque 返回类型不能穿过泛型闭包推导。
//

import AppIntents
import Foundation

// MARK: - 解压

struct ExtractArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Archive"
    static let description = IntentDescription(
        "Extracts archives the way SimpleZip's Finder auto-extract does: each archive unpacks into a uniquely named folder next to itself (or inside the chosen destination). Existing files are never overwritten."
    )

    @Parameter(title: "Archives")
    var archives: [IntentFile]

    @Parameter(title: "Destination Folder")
    var destination: IntentFile?

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Extract \(\.$archives) to \(\.$destination)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard !archives.isEmpty else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput"))
        }
        let pw = password ?? ""
        let produced = try await withIntentFilesAccess(archives) { urls -> [IntentFile] in
            // 目标文件夹(可选):同样开安全作用域;若指向普通文件提前报错。
            let destinationDir = try destination.map { try extensionIntentFileURL($0) }
            var destScoped = false
            if let destinationDir {
                destScoped = destinationDir.startAccessingSecurityScopedResource()
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: destinationDir.path, isDirectory: &isDir), !isDir.boolValue {
                    if destScoped { destinationDir.stopAccessingSecurityScopedResource() }
                    throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.destinationNotFolder"))
                }
            }
            defer { if destScoped, let d = destinationDir { d.stopAccessingSecurityScopedResource() } }
            var out: [IntentFile] = []
            for url in urls {
                do {
                    try await withToolAdaptedArchiveExtension(url) { _ in }  // .siz/.szs 早拒
                    let target = try await extractArchiveInExtension(archiveURL: url, destinationDir: destinationDir, password: pw)
                    out.append(IntentFile(fileURL: target))
                } catch {
                    if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                    throw SimpleZipExtensionIntentError(
                        message: L10n.format("intent.error.itemFailed", url.lastPathComponent, error.localizedDescription))
                }
            }
            return out
        }
        return .result(value: produced)
    }
}

// MARK: - 创建

struct CreateArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Archive"
    static let description = IntentDescription(
        "Creates an archive from files or folders that live in the same folder. The archive is written next to the inputs without overwriting any existing file."
    )

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.folder", "public.item"])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .zip)
    var format: IntentArchiveFormat

    @Parameter(title: "Archive Name")
    var archiveName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a \(\.$format) archive from \(\.$files)") {
            \.$archiveName
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard !files.isEmpty else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput"))
        }
        let destination = try await withIntentFilesAccess(files) { inputURLs -> URL in
            // ArchiveService.createArchive 以第一个输入的父目录为工作目录、按文件名相对引用 —— 所有输入必须同目录。
            let parent = inputURLs[0].deletingLastPathComponent().standardizedFileURL
            guard inputURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
                throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.mixedFolders"))
            }
            let createFormat = format.createFormat
            var options = ArchiveCreationOptions()
            options.format = createFormat
            // 沙箱扩展读不到 app 的压缩预设(不同 defaults 域)→ 用该格式的纯默认项。
            let stem = archiveName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = (stem?.isEmpty == false ? stem! : inputURLs[0].deletingPathExtension().lastPathComponent)
            // P1:名字必须是单段纯文件名 —— Shortcuts 是脚本入口,「../escape」会把产物拼到输入目录之外。
            guard !ArchiveSafety.isUnsafeOutputBaseName(baseName) else {
                throw SimpleZipExtensionIntentError(message: L10n.format("intent.error.badName", baseName))
            }
            let preferred = parent.appendingPathComponent("\(baseName).\(createFormat.pathExtension)")
            let dest = UniqueFileName.suffixed(for: preferred, suffix: "") {
                FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try await ArchiveService.createArchive(from: inputURLs, destination: dest, options: options)
            } catch {
                throw SimpleZipExtensionIntentError(
                    message: L10n.format("intent.error.itemFailed", dest.lastPathComponent, error.localizedDescription))
            }
            return dest
        }
        return .result(value: IntentFile(fileURL: destination))
    }
}

// MARK: - 完整性测试

struct TestArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Test Archive Integrity"
    static let description = IntentDescription(
        "Runs SimpleZip's integrity test on archives and reports which ones fail. Provide a password for encrypted archives, or you'll be prompted when one is needed."
    )

    @Parameter(title: "Archives")
    var archives: [IntentFile]

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Test \(\.$archives)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard !archives.isEmpty else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput"))
        }
        let pw = password ?? ""
        var failures: [String] = []
        var needsPassword = false
        try await withIntentFilesAccess(archives) { urls in
            for url in urls {
                do {
                    try await withToolAdaptedArchiveExtension(url) { target in
                        try await ArchiveService.test(target, password: pw)
                    }
                } catch {
                    if shouldPromptForPassword(error, providedPassword: password) { needsPassword = true; break }
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if needsPassword { throw $password.needsValueError() }
        if failures.isEmpty {
            return .result(value: true, dialog: IntentDialog("\(L10n.format("intent.test.allPassed", "\(archives.count)"))"))
        }
        return .result(value: false,
            dialog: IntentDialog("\(L10n.format("intent.test.failures", "\(failures.count)", failures.joined(separator: "\n")))"))
    }
}

// MARK: - 校验文件验证

struct VerifyChecksumsIntent: AppIntent {
    static let title: LocalizedStringResource = "Verify Checksums"
    static let description = IntentDescription(
        "Verifies the files listed in checksum files (SHA256SUMS, .sha256, .md5, .sfv). Paths resolve relative to each checksum file; unsafe entries are rejected. Returns true when everything matches."
    )

    @Parameter(title: "Checksum Files")
    var checksumFiles: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Verify \(\.$checksumFiles)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard !checksumFiles.isEmpty else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput"))
        }
        var totalPassed = 0
        var failures: [String] = []
        try await withIntentFilesAccess(checksumFiles) { urls in
            for checksumURL in urls {
                guard let text = try? String(contentsOf: checksumURL, encoding: .utf8) else {
                    failures.append(checksumURL.lastPathComponent); continue
                }
                let entries = ChecksumFile.parse(text, fileName: checksumURL.lastPathComponent)
                let baseDir = checksumURL.deletingLastPathComponent()
                for entry in entries {
                    // 校验文件是不可信输入:`..` / 绝对路径 / 反斜杠逃逸不碰文件系统。
                    let normalized = entry.name.replacingOccurrences(of: "\\", with: "/")
                    if entry.name.hasPrefix("/") || normalized.split(separator: "/").contains("..") {
                        failures.append(entry.name); continue
                    }
                    let target = baseDir.appendingPathComponent(entry.name)
                    guard FileManager.default.fileExists(atPath: target.path),
                          let algorithm = HashAlgorithm(rawValue: entry.algorithm.rawValue),
                          let report = try? await HashService.calculate(for: [target], includeHiddenFiles: true, algorithms: [algorithm]),
                          report.results.first?.hashes[algorithm]?.lowercased() == entry.digestHex.lowercased() else {
                        failures.append(entry.name); continue
                    }
                    totalPassed += 1
                }
                if entries.isEmpty { failures.append(checksumURL.lastPathComponent) }
            }
        }
        if failures.isEmpty {
            return .result(value: true, dialog: IntentDialog("\(L10n.format("intent.verify.allPassed", "\(totalPassed)"))"))
        }
        return .result(value: false,
            dialog: IntentDialog("\(L10n.format("intent.verify.failures", "\(failures.count)", failures.prefix(8).joined(separator: ", ")))"))
    }
}

// MARK: - 计算哈希

struct ComputeFileHashIntent: AppIntent {
    static let title: LocalizedStringResource = "Compute File Hash"
    static let description = IntentDescription(
        "Computes a checksum (CRC32, MD5, SHA-1, SHA-256 or SHA-512) for one or more files. Returns the hex digests in the same order as the input files."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Algorithm", default: .sha256)
    var algorithm: IntentHashAlgorithm

    static var parameterSummary: some ParameterSummary {
        Summary("Compute the \(\.$algorithm) of \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard !files.isEmpty else { throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput")) }
        let chosen = algorithm.hashAlgorithm
        let digests = try await withIntentFilesAccess(files) { urls -> [String] in
            var out: [String] = []
            for url in urls {
                let report = try await HashService.calculate(for: [url], includeHiddenFiles: true, algorithms: [chosen])
                guard let digest = report.results.first?.hashes[chosen] else {
                    throw SimpleZipExtensionIntentError(
                        message: L10n.format("intent.error.itemFailed", url.lastPathComponent, chosen.rawValue))
                }
                out.append(digest)
            }
            return out
        }
        return .result(value: digests)
    }
}

// MARK: - 数据救援

struct RescueArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Rescue Damaged Archive"
    static let description = IntentDescription(
        "Best-effort recovery from a damaged archive into a new \"(rescued)\" folder next to it. Rescued files may be incomplete and the archive is not repaired. Returns the rescue folder.")

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Rescue \(\.$archive)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let pw = password ?? ""
        let folder = try await withIntentFileAccess(archive) { url -> URL in
            do {
                let listed = try? await ArchiveService.list(url, password: pw)
                let outcome = try await ArchiveSalvage.run(
                    archive: url, listedItems: listed, password: pw, operationID: UUID(), outputObserver: nil)
                return outcome.destination
            } catch {
                if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                throw SimpleZipExtensionIntentError(message: error.localizedDescription)
            }
        }
        return .result(value: IntentFile(fileURL: folder))
    }
}

// MARK: - 批量体检

struct CheckupArchivesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Up Archives"
    static let description = IntentDescription(
        "Runs an integrity test across several archives and returns true only when every archive passes.")

    @Parameter(title: "Archives")
    var archives: [IntentFile]

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Check up \(\.$archives)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard !archives.isEmpty else { throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput")) }
        let pw = password ?? ""
        let allPassed = try await withIntentFilesAccess(archives) { urls -> Bool in
            var failures = 0
            for url in urls {
                do {
                    try await withToolAdaptedArchiveExtension(url) { target in
                        try await ArchiveService.test(target, password: pw)
                    }
                } catch { failures += 1 }
            }
            return failures == 0
        }
        return .result(value: allPassed)
    }
}

// MARK: - 查找重复归档

struct FindDuplicateArchivesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Duplicate Archives"
    static let description = IntentDescription(
        "Finds duplicate archives among the given archives by structural fingerprint. Returns one line per duplicate group.")

    @Parameter(title: "Archives")
    var archives: [IntentFile]

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find duplicates among \(\.$archives)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard archives.count >= 2 else { throw SimpleZipExtensionIntentError(message: L10n.text("intent.error.noInput")) }
        let pw = password ?? ""
        let lines = try await withIntentFilesAccess(archives) { urls -> [String] in
            var sources: [ArchiveDuplicateScan.Source] = []
            for url in urls {
                guard let items = try? await withToolAdaptedArchiveExtension(url, { target in
                    try await ArchiveService.list(target, password: pw)
                }) else { continue }
                let files = items.filter { !$0.isDirectory }
                sources.append(ArchiveDuplicateScan.Source(
                    url: url, fingerprint: ArchiveStructuralFingerprint.compute(for: items),
                    entryCount: files.count, totalBytes: files.reduce(0) { $0 + ($1.size ?? 0) }))
            }
            return ArchiveDuplicateScan.groups(from: sources).map { $0.urls.map(\.lastPathComponent).joined(separator: ", ") }
        }
        return .result(value: lines)
    }
}

// MARK: - 可复现报告

struct CheckReproducibilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Reproducible Packing"
    static let description = IntentDescription(
        "Packs a folder twice with reproducible settings and returns true when the two archives are byte-for-byte identical. Only zip and 7z are supported.")

    @Parameter(title: "Folder")
    var folder: IntentFile

    @Parameter(title: "Format", default: .zip)
    var format: IntentArchiveFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$folder) packs reproducibly as \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let createFmt = format.createFormat
        guard createFmt == .zip || createFmt == .sevenZip else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.reproduce.formatUnsupported"))
        }
        let identical = try await withIntentFileAccess(folder) { folderURL -> Bool in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimpleZip-Reproduce-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            var options = ArchiveCreationOptions()
            options.format = createFmt
            options.reproducibleArchive = true
            let first = temp.appendingPathComponent("first.\(createFmt.pathExtension)")
            let second = temp.appendingPathComponent("second.\(createFmt.pathExtension)")
            do {
                try await ArchiveService.createArchive(from: [folderURL], destination: first, options: options)
                try await ArchiveService.createArchive(from: [folderURL], destination: second, options: options)
                let firstHash = try HashService.sha256(for: first)
                let secondHash = try HashService.sha256(for: second)
                return firstHash == secondHash
            } catch {
                throw SimpleZipExtensionIntentError(message: error.localizedDescription)
            }
        }
        return .result(value: identical)
    }
}

// MARK: - 发布目录审计(纯文件名 + 校验文件,不解归档)

struct AuditReleaseDirectoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Audit Release Directory"
    static let description = IntentDescription(
        "Audits a release folder by name + checksum file (no hashing): checks SHA256SUMS coverage. Returns true when every artifact is covered by a checksum.")

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Audit release directory \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let covered = try await withIntentFileAccess(folder) { dir -> Bool in
            let names = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent)
            let inventory = ReleaseDirectoryAudit.classify(names: names) { ArchiveService.isSupportedArchive(URL(fileURLWithPath: $0)) }
            var checksumEntries: [String] = []
            for checksumFile in inventory.checksumFiles {
                if let text = try? String(contentsOf: dir.appendingPathComponent(checksumFile), encoding: .utf8) {
                    checksumEntries += ChecksumFile.parse(text, fileName: checksumFile).map(\.name)
                }
            }
            let coverage = ReleaseDirectoryAudit.checksumCoverage(entryNames: checksumEntries, artifacts: inventory.artifacts)
            return coverage.uncovered.isEmpty
        }
        return .result(value: covered)
    }
}

struct QuickVerifyReleaseGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Verify Release Group"
    static let description = IntentDescription(
        "A fast, name-only check of a release folder's composition. Returns true when a downloader could verify it (an artifact or container plus SHA256SUMS).")

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Quick-verify the release group in \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let verifiable = try await withIntentFileAccess(folder) { dir -> Bool in
            let names = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent)
            let inventory = ReleaseDirectoryAudit.classify(names: names) { ArchiveService.isSupportedArchive(URL(fileURLWithPath: $0)) }
            return ReleaseDirectoryAudit.quickVerify(inventory).isVerifiable
        }
        return .result(value: verifiable)
    }
}

// MARK: - 归档比较

struct CompareArchivesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compare Archives"
    static let description = IntentDescription(
        "Compares the entry lists of two archives (path, size, CRC, modified, encryption). Returns true when they are identical."
    )

    @Parameter(title: "First Archive")
    var left: IntentFile

    @Parameter(title: "Second Archive")
    var right: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Compare \(\.$left) with \(\.$right)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let pw = password ?? ""
        let outcome: (identical: Bool, dialog: String) = try await withIntentFileAccess(left) { leftURL in
            try await withIntentFileAccess(right) { rightURL -> (Bool, String) in
                do {
                    let leftItems = try await withToolAdaptedArchiveExtension(leftURL) { try await ArchiveService.list($0, password: pw) }
                    let rightItems = try await withToolAdaptedArchiveExtension(rightURL) { try await ArchiveService.list($0, password: pw) }
                    let result = ArchiveDiff.compare(left: leftItems, right: rightItems)
                    if result.hasDifferences {
                        return (false, L10n.format("intent.compare.different", "\(result.added.count)", "\(result.removed.count)", "\(result.changed.count)"))
                    }
                    return (true, L10n.format("intent.compare.identical", "\(result.unchanged.count)"))
                } catch {
                    if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                    throw SimpleZipExtensionIntentError(message: error.localizedDescription)
                }
            }
        }
        return .result(value: outcome.identical, dialog: IntentDialog("\(outcome.dialog)"))
    }
}

// MARK: - 归档内容搜索

struct SearchArchiveContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Archive Contents"
    static let description = IntentDescription(
        "Lists an archive and returns the entries whose path contains the search text (case-insensitive). Encrypted archives whose entry names need a password aren't listed."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$archive) for \(\.$query)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw SimpleZipExtensionIntentError(message: L10n.text("intent.search.emptyQuery"))
        }
        let pw = password ?? ""
        let outcome: (matches: [String], dialog: String) = try await withIntentFileAccess(archive) { url -> ([String], String) in
            do {
                let items = try await withToolAdaptedArchiveExtension(url) { try await ArchiveService.list($0, password: pw) }
                let matches = ArchiveSearch.filter(items, with: ArchiveSearchQuery(text: trimmed, scope: .fullPath)).map(\.name)
                if matches.isEmpty {
                    return ([], L10n.format("intent.search.none", url.lastPathComponent, trimmed))
                }
                return (matches, L10n.format("intent.search.results", "\(matches.count)", url.lastPathComponent, trimmed))
            } catch {
                if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                throw SimpleZipExtensionIntentError(message: error.localizedDescription)
            }
        }
        return .result(value: outcome.matches, dialog: IntentDialog("\(outcome.dialog)"))
    }
}

// MARK: - 归档检查

struct InspectArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Inspect Archive"
    static let description = IntentDescription(
        "Inspects an archive the way the Release Assistant does — file count, total size, macOS junk, empty directories and suspicious entry paths — without extracting. Returns true when nothing suspicious is found."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Inspect \(\.$archive)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let pw = password ?? ""
        let outcome: (clean: Bool, dialog: String) = try await withIntentFileAccess(archive) { url -> (Bool, String) in
            do {
                let items = try await withToolAdaptedArchiveExtension(url) { try await ArchiveService.list($0, password: pw) }
                let stats = ReleaseInspection.stats(for: items)
                let findings = ArchiveSecurityReport.analyze(items)
                let flaggedPaths = findings.reduce(0) { $0 + $1.entryPaths.count }
                let sizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
                if findings.isEmpty {
                    return (true, L10n.format("intent.inspect.clean", url.lastPathComponent, "\(stats.fileCount)", sizeText, "\(stats.junkCount)"))
                }
                return (false, L10n.format("intent.inspect.flagged", url.lastPathComponent, "\(flaggedPaths)", "\(findings.count)", "\(stats.fileCount)", sizeText))
            } catch {
                if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                throw SimpleZipExtensionIntentError(message: error.localizedDescription)
            }
        }
        return .result(value: outcome.clean, dialog: IntentDialog("\(outcome.dialog)"))
    }
}

// MARK: - 分析归档空间

struct AnalyzeArchiveSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze Archive Space"
    static let description = IntentDescription(
        "Returns a disk-usage summary for an archive: original vs packed size, compression ratio, macOS junk and the largest file.")

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Analyze the space used by \(\.$archive)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let pw = password ?? ""
        let summary = try await withIntentFileAccess(archive) { url -> String in
            do {
                let items = try await withToolAdaptedArchiveExtension(url) { try await ArchiveService.list($0, password: pw) }
                let a = ArchiveSpaceAnalysis.analyze(items)
                func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
                var parts = ["\(a.fileCount) files", "original \(bytes(a.totalBytes))", "packed \(bytes(a.packedBytes))"]
                if let ratio = a.compressionRatio { parts.append(String(format: "ratio %.0f%%", ratio * 100)) }
                if a.junkCount > 0 { parts.append("junk \(bytes(a.junkBytes))") }
                if let largest = a.largestFiles.first { parts.append("largest \(largest.name) (\(bytes(largest.bytes)))") }
                return parts.joined(separator: ", ")
            } catch {
                if shouldPromptForPassword(error, providedPassword: password) { throw $password.needsValueError() }
                throw SimpleZipExtensionIntentError(message: error.localizedDescription)
            }
        }
        return .result(value: summary)
    }
}

// MARK: - Siri / Spotlight 建议(扩展自己的 AppShortcutsProvider)

/// App Shortcuts(Apple 上限 10 条):让这些扩展 intent 不用用户手动建快捷指令就出现在 Shortcuts app /
/// Spotlight / Siri 建议里。`shortTitle` / `systemImageName` 初始化器要 macOS 14;扩展下限 13,低版本上 intent
/// 本身照常可用,只是不预注册建议。app 的 Tier-2 intent(改设置 / 查含某文件的归档 / 发布打包)由 app target
/// 自己的 provider 注册,各管各的。
@available(macOS 14.0, *)
struct SimpleZipExtensionAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExtractArchiveIntent(),
            phrases: ["Extract an archive with \(.applicationName)"],
            shortTitle: "Extract Archive",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: CreateArchiveIntent(),
            phrases: ["Create an archive with \(.applicationName)"],
            shortTitle: "Create Archive",
            systemImageName: "doc.zipper"
        )
        AppShortcut(
            intent: TestArchiveIntent(),
            phrases: ["Test an archive with \(.applicationName)", "Check an archive with \(.applicationName)"],
            shortTitle: "Test Archive Integrity",
            systemImageName: "checkmark.seal"
        )
        AppShortcut(
            intent: VerifyChecksumsIntent(),
            phrases: ["Verify checksums with \(.applicationName)", "Verify a SHA256SUMS file with \(.applicationName)"],
            shortTitle: "Verify Checksums",
            systemImageName: "number.square"
        )
        AppShortcut(
            intent: CompareArchivesIntent(),
            phrases: ["Compare archives with \(.applicationName)", "Compare two archives with \(.applicationName)"],
            shortTitle: "Compare Archives",
            systemImageName: "arrow.left.arrow.right.circle"
        )
        AppShortcut(
            intent: SearchArchiveContentsIntent(),
            phrases: ["Search an archive with \(.applicationName)", "Search archive contents with \(.applicationName)"],
            shortTitle: "Search Archive Contents",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: InspectArchiveIntent(),
            phrases: ["Inspect an archive with \(.applicationName)", "Inspect an archive for release with \(.applicationName)"],
            shortTitle: "Inspect Archive",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: AnalyzeArchiveSpaceIntent(),
            phrases: ["Analyze archive space with \(.applicationName)"],
            shortTitle: "Analyze Archive Space",
            systemImageName: "chart.pie"
        )
        AppShortcut(
            intent: CheckupArchivesIntent(),
            phrases: ["Check up archives with \(.applicationName)"],
            shortTitle: "Check Up Archives",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: RescueArchiveIntent(),
            phrases: ["Rescue a damaged archive with \(.applicationName)"],
            shortTitle: "Rescue Damaged Archive",
            systemImageName: "cross.case"
        )
    }
}
