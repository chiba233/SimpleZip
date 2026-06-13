//
//  SimpleZipAppIntents.swift
//  SimpleZip
//
//  Shortcuts / Siri 建议接入(App Intents)。第一批三个 intent:解压 / 创建 / 测试,
//  全部复用既有无窗口核心(ExternalExtractRunner / ArchiveService),不造平行流程;
//  每次执行过 TaskCenter 留痕,活动中心实时可见、历史可查。
//
//  本地化口径:静态元数据(标题 / 参数名 / 描述)是字面 LocalizedStringResource ——
//  英文字面量即键,zh-Hans 在 Localizable.strings 里补对应条目,由系统按 Shortcuts
//  进程语言解析;运行期 dialog / 错误消息走 app 自己的 L10n(intent.* 键)。
//

import AppIntents
import Foundation

/// Intent 执行错误:消息原样展示给 Shortcuts 用户(已本地化)。
struct SimpleZipIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// IntentFile → 磁盘 URL。Shortcuts 传内存数据(无落盘位置)时明确拒绝 ——
/// 归档操作全部按路径工作,不接受把未知数据悄悄写进临时目录再处理。
private func intentFileURL(_ file: IntentFile) throws -> URL {
    guard let url = file.fileURL else {
        throw SimpleZipIntentError(message: L10n.format("intent.error.noFileURL", file.filename))
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", url.path))
    }
    return url
}

// MARK: - 解压

struct ExtractArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Archive"
    static let description = IntentDescription(
        "Extracts archives the way SimpleZip's Finder auto-extract does: each archive unpacks into a uniquely named folder next to itself (or inside the chosen destination). Existing files are never overwritten."
    )

    // supportedContentTypes 形参要 macOS 15(目标 13)—— 不筛类型,无效输入由执行期校验报错。
    @Parameter(title: "Archives")
    var archives: [IntentFile]

    @Parameter(title: "Destination Folder")
    var destination: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Extract \(\.$archives) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard !archives.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.error.noInput"))
        }
        let destinationDir = try destination.map { try intentFileURL($0) }
        let coordinator = ArchiveExtractionCoordinator(fileManager: .default)
        var produced: [IntentFile] = []
        for file in archives {
            let url = try intentFileURL(file)
            let operationID = UUID()
            let task = TaskCenter.shared.begin(
                category: .archive,
                kind: .extract,
                source: .intent,
                title: L10n.format("intent.task.extract", url.lastPathComponent),
                cancellable: false,
                operationID: operationID
            )
            do {
                let target = try await ExternalExtractRunner.extract(
                    archiveURL: url,
                    destinationDirectoryOverride: destinationDir,
                    outputBaseNameOverride: nil,
                    operationID: operationID,
                    coordinator: coordinator,
                    onStatus: { [weak task] text in task?.progress.statusText = text },
                    onProgress: { [weak task] fraction, currentFile in
                        task?.progress.fraction = fraction
                        task?.progress.currentFile = currentFile
                    }
                )
                TaskCenter.shared.finish(task, outcome: .succeeded(target))
                produced.append(IntentFile(fileURL: target))
            } catch {
                TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
                throw SimpleZipIntentError(
                    message: L10n.format("intent.error.itemFailed", url.lastPathComponent, error.localizedDescription)
                )
            }
        }
        return .result(value: produced)
    }
}

// MARK: - 创建

/// Shortcuts 暴露的创建格式(创建路径的常用子集;DMG/RAR 依赖外部条件,首批不进)。
enum IntentArchiveFormat: String, AppEnum {
    case zip
    case sevenZip
    case tar
    case tarGzip

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Archive Format")
    static let caseDisplayRepresentations: [IntentArchiveFormat: DisplayRepresentation] = [
        .zip: "ZIP",
        .sevenZip: "7-Zip",
        .tar: "tar",
        .tarGzip: "tar.gz"
    ]

    var createFormat: ArchiveCreateFormat {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tarGzip: return .tarGzip
        }
    }
}

struct CreateArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Archive"
    static let description = IntentDescription(
        "Compresses files into a new archive next to them, applying the same per-format defaults as SimpleZip's one-click Finder compression. All inputs must live in the same folder; an existing archive is never overwritten — the new one gets a numbered name instead."
    )

    @Parameter(title: "Files")
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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard !files.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.error.noInput"))
        }
        let inputURLs = try files.map(intentFileURL)
        // ArchiveService.createArchive 以第一个输入的父目录为工作目录、按文件名相对引用 ——
        // 与 GUI 多选 / CLI 同一约束:所有输入必须在同一目录。
        let parent = inputURLs[0].deletingLastPathComponent().standardizedFileURL
        guard inputURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw SimpleZipIntentError(message: L10n.text("intent.error.mixedFolders"))
        }

        let createFormat = format.createFormat
        var options = ArchiveCreationOptions()
        options.format = createFormat
        // 与 Finder 一键压缩 / CLI 同口径:套用该格式在 app 里保存且启用的默认值(密码 / GPG 永不入库)。
        if let preset = CompressionDefaultsStore().preset(for: createFormat), preset.enabled {
            preset.apply(to: &options)
        }

        let stem = archiveName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (stem?.isEmpty == false ? stem! : inputURLs[0].deletingPathExtension().lastPathComponent)
        // P1:名字必须是单段纯文件名 —— Shortcuts 是无人值守入口,「../escape」会把产物
        // 拼到输入目录之外(实测复现)。分隔符 / 上跳 / 盘符 / `~` 一律明确拒绝。
        guard !ArchiveSafety.isUnsafeOutputBaseName(baseName) else {
            throw SimpleZipIntentError(message: L10n.format("intent.error.badName", baseName))
        }
        let preferred = parent.appendingPathComponent("\(baseName).\(createFormat.pathExtension)")
        // 绝不覆盖既有文件:重名走「名 2」「名 3」…(UniqueFileName 同款语义)。
        let destination = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }

        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .create,
            source: .intent,
            title: L10n.format("intent.task.create", destination.lastPathComponent),
            cancellable: false,
            operationID: operationID
        )
        // 进度从后端线程来 —— 借现成 ProgressCoalescer 合帧并跳回主 actor(同 startManagedArchiveTask)。
        let progressCoalescer = ProgressCoalescer { [weak task] state in
            task?.progress = state
        }
        do {
            try await ArchiveService.createArchive(
                from: inputURLs,
                destination: destination,
                options: options,
                operationID: operationID,
                progress: { state in progressCoalescer.submit(state) }
            )
            TaskCenter.shared.finish(task, outcome: .succeeded(destination))
            return .result(value: IntentFile(fileURL: destination))
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(
                message: L10n.format("intent.error.itemFailed", destination.lastPathComponent, error.localizedDescription)
            )
        }
    }
}

// MARK: - 完整性测试

struct TestArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Test Archive Integrity"
    static let description = IntentDescription(
        "Runs SimpleZip's integrity test on archives and reports which ones fail. Encrypted archives are tested with the preset password when one is configured; this intent never prompts."
    )

    @Parameter(title: "Archives")
    var archives: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Test \(\.$archives)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard !archives.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.error.noInput"))
        }
        var failures: [String] = []
        for file in archives {
            let url = try intentFileURL(file)
            let operationID = UUID()
            let task = TaskCenter.shared.begin(
                category: .archive,
                kind: .test,
                source: .intent,
                title: L10n.format("intent.task.test", url.lastPathComponent),
                cancellable: false,
                operationID: operationID
            )
            do {
                try await testHonoringPresetPassword(url, operationID: operationID)
                TaskCenter.shared.finish(task, outcome: .succeeded(nil))
            } catch {
                TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            return .result(
                value: true,
                dialog: IntentDialog("\(L10n.format("intent.test.allPassed", "\(archives.count)"))")
            )
        }
        return .result(
            value: false,
            dialog: IntentDialog("\(L10n.format("intent.test.failures", "\(failures.count)", failures.joined(separator: "\n")))")
        )
    }

    /// 空口令先测;「错误表明需要口令」且配置了预设密码时换预设静默重试一次(Finder 自动解压同口径)。
    /// Shortcuts 是无人值守上下文,绝不弹密码窗。
    @MainActor
    private func testHonoringPresetPassword(_ url: URL, operationID: UUID) async throws {
        do {
            try await ArchiveService.test(url, operationID: operationID)
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error),
                  AppPreferences.hasUsablePresetPassword,
                  // #1:自动化中心可关掉「自动化通道用预设密码」—— 关了就只试空密码。
                  AppPreferences.automationAllowPresetPassword else { throw error }
            try await ArchiveService.test(url, password: AppPreferences.presetPassword, operationID: operationID)
        }
    }
}

// MARK: - 校验文件验证(0.4.4 B)

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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard !checksumFiles.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.error.noInput"))
        }
        var totalPassed = 0
        var failures: [String] = []
        for file in checksumFiles {
            let checksumURL = try intentFileURL(file)
            let task = TaskCenter.shared.begin(
                category: .fileOperation,
                kind: .hash,
                source: .intent,
                title: L10n.format("intent.task.verify", checksumURL.lastPathComponent),
                cancellable: false
            )
            guard let text = try? String(contentsOf: checksumURL, encoding: .utf8) else {
                TaskCenter.shared.finish(task, outcome: .failed(L10n.format("intent.error.missingFile", checksumURL.path)))
                failures.append(checksumURL.lastPathComponent)
                continue
            }
            let entries = ChecksumFile.parse(text, fileName: checksumURL.lastPathComponent)
            let baseDir = checksumURL.deletingLastPathComponent()
            var fileFailures = 0
            for entry in entries {
                // 校验文件是不可信输入(与 app / CLI 同一规则):`..` / 绝对路径 / 反斜杠逃逸不碰文件系统。
                let normalized = entry.name.replacingOccurrences(of: "\\", with: "/")
                if entry.name.hasPrefix("/") || normalized.split(separator: "/").contains("..") {
                    fileFailures += 1
                    continue
                }
                let target = baseDir.appendingPathComponent(entry.name)
                guard FileManager.default.fileExists(atPath: target.path),
                      let algorithm = HashAlgorithm(rawValue: entry.algorithm.rawValue),
                      let report = try? await HashService.calculate(for: [target], includeHiddenFiles: true, algorithms: [algorithm]),
                      report.results.first?.hashes[algorithm]?.lowercased() == entry.digestHex.lowercased() else {
                    fileFailures += 1
                    failures.append(entry.name)
                    continue
                }
                totalPassed += 1
            }
            if entries.isEmpty { fileFailures += 1; failures.append(checksumURL.lastPathComponent) }
            TaskCenter.shared.finish(task, outcome: fileFailures == 0
                ? .succeeded(nil)
                : .failed(L10n.format("intent.verify.fileFailures", "\(fileFailures)")))
        }
        if failures.isEmpty {
            return .result(value: true, dialog: IntentDialog("\(L10n.format("intent.verify.allPassed", "\(totalPassed)"))"))
        }
        return .result(
            value: false,
            dialog: IntentDialog("\(L10n.format("intent.verify.failures", "\(failures.count)", failures.prefix(8).joined(separator: ", ")))")
        )
    }
}

// MARK: - 归档比较(0.4.4 B)

struct CompareArchivesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compare Archives"
    static let description = IntentDescription(
        "Compares the entry lists of two archives (path, size, CRC, modified, encryption). Returns true when they are identical."
    )

    @Parameter(title: "First Archive")
    var left: IntentFile

    @Parameter(title: "Second Archive")
    var right: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Compare \(\.$left) with \(\.$right)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let leftURL = try intentFileURL(left)
        let rightURL = try intentFileURL(right)
        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .compare,
            source: .intent,
            title: L10n.format("status.comparing", leftURL.lastPathComponent, rightURL.lastPathComponent),
            cancellable: false,
            operationID: operationID
        )
        do {
            let leftItems = try await ArchiveService.list(leftURL, operationID: operationID)
            let rightItems = try await ArchiveService.list(rightURL, operationID: operationID)
            let result = ArchiveDiff.compare(left: leftItems, right: rightItems)
            TaskCenter.shared.finish(task, outcome: .succeeded(nil))
            if result.hasDifferences {
                return .result(
                    value: false,
                    dialog: IntentDialog("\(L10n.format("intent.compare.different", "\(result.added.count)", "\(result.removed.count)", "\(result.changed.count)"))")
                )
            }
            return .result(
                value: true,
                dialog: IntentDialog("\(L10n.format("intent.compare.identical", "\(result.unchanged.count)"))")
            )
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: - 归档内容搜索(0.4.4 macOS 26 AI)

struct SearchArchiveContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Archive Contents"
    static let description = IntentDescription(
        "Lists an archive and returns the entries whose path contains the search text (case-insensitive). Encrypted archives whose entry names need a password aren't listed."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$archive) for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let url = try intentFileURL(archive)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw SimpleZipIntentError(message: L10n.text("intent.search.emptyQuery"))
        }
        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .search,
            source: .intent,
            title: L10n.format("intent.task.search", url.lastPathComponent),
            cancellable: false,
            operationID: operationID
        )
        do {
            // 仅按完整路径做大小写不敏感子串匹配。加密名归档本就 list 不出名字 → 自然不暴露(隐私红线)。
            let items = try await ArchiveService.list(url, operationID: operationID)
            let matches = ArchiveSearch.filter(items, with: ArchiveSearchQuery(text: trimmed, scope: .fullPath)).map(\.name)
            TaskCenter.shared.finish(task, outcome: .succeeded(nil))
            if matches.isEmpty {
                return .result(
                    value: [],
                    dialog: IntentDialog("\(L10n.format("intent.search.none", url.lastPathComponent, trimmed))")
                )
            }
            return .result(
                value: matches,
                dialog: IntentDialog("\(L10n.format("intent.search.results", "\(matches.count)", url.lastPathComponent, trimmed))")
            )
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: - 归档检查(0.4.4 macOS 26 AI)

struct InspectArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Inspect Archive"
    static let description = IntentDescription(
        "Inspects an archive the way the Release Assistant does — file count, total size, macOS junk, empty directories and suspicious entry paths — without extracting. Returns true when nothing suspicious is found."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Inspect \(\.$archive)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let url = try intentFileURL(archive)
        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .inspect,
            source: .intent,
            title: L10n.format("intent.task.inspect", url.lastPathComponent),
            cancellable: false,
            operationID: operationID
        )
        do {
            let items = try await ArchiveService.list(url, operationID: operationID)
            let stats = ReleaseInspection.stats(for: items)
            let findings = ArchiveSecurityReport.analyze(items)
            let flaggedPaths = findings.reduce(0) { $0 + $1.entryPaths.count }
            TaskCenter.shared.finish(task, outcome: .succeeded(nil))
            let sizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
            if findings.isEmpty {
                return .result(
                    value: true,
                    dialog: IntentDialog("\(L10n.format("intent.inspect.clean", url.lastPathComponent, "\(stats.fileCount)", sizeText, "\(stats.junkCount)"))")
                )
            }
            return .result(
                value: false,
                dialog: IntentDialog("\(L10n.format("intent.inspect.flagged", url.lastPathComponent, "\(flaggedPaths)", "\(findings.count)", "\(stats.fileCount)", sizeText))")
            )
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: - 发布打包(0.4.4 B)

struct CreateReleasePackageIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Release Package"
    static let description = IntentDescription(
        "Runs SimpleZip's Release Assistant headlessly: pack a build folder (junk excluded, reproducible), inspect the archive and write SHA256SUMS — using a saved workspace preset when one is named. Signing as .szs is interactive-only and never runs unattended."
    )

    @Parameter(title: "Build Folder")
    var sourceFolder: IntentFile

    @Parameter(title: "Workspace Preset Name")
    var presetName: String?

    @Parameter(title: "Archive Name")
    var archiveName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a release package from \(\.$sourceFolder)") {
            \.$presetName
            \.$archiveName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let source = try intentFileURL(sourceFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", source.path))
        }

        // 组装请求:命名预设(找不到名字 = 明确报错,不静默回落)→ 否则全默认(排垃圾 + 可复现 + 检查 + 校验)。
        var request = ReleaseAssistantRequest()
        request.sourceFolder = source
        request.destinationFolder = source.deletingLastPathComponent()
        request.fileName = source.lastPathComponent
        if let presetName, !presetName.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let preset = ReleaseWorkspacePresetStore().loadAll()
                .first(where: { $0.name.localizedCaseInsensitiveCompare(presetName) == .orderedSame }) else {
                throw SimpleZipIntentError(message: L10n.format("intent.release.unknownPreset", presetName))
            }
            request.fileName = preset.fileName.isEmpty ? source.lastPathComponent : preset.fileName
            request.versionLabel = preset.versionLabel ?? ""
            if let format = ArchiveCreateFormat(rawValue: preset.formatRawValue), format == .zip || format == .sevenZip {
                request.format = format
            }
            request.excludeJunk = preset.excludeJunk
            request.reproducible = preset.reproducible
            request.runInspection = preset.runInspection
            request.writeChecksums = preset.writeChecksums
            request.writeManifest = preset.writeManifest ?? false
            request.gateRules = preset.gateRules ?? ReleaseGateRules()
        }
        if let archiveName, !archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.fileName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 无人值守红线:绝不进入交互式 .szs 签名(预设里勾了也压掉)。
        request.createSignedManifest = false
        // P1 同款:输出名必须是单段纯文件名(Shortcuts 是无人值守入口)。
        guard !ArchiveSafety.isUnsafeOutputBaseName(request.fileName) else {
            throw SimpleZipIntentError(message: L10n.format("intent.error.badName", request.fileName))
        }

        let destination = request.destinationFolder ?? source.deletingLastPathComponent()
        let preferred = destination
            .appendingPathComponent(request.fileName)
            .appendingPathExtension(request.format.pathExtension)
        let outputURL = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var options = ArchiveCreationOptions()
        options.format = request.format
        options.skipDSStore = request.excludeJunk
        if request.excludeJunk {
            options.customExcludes = "._*, Thumbs.db, desktop.ini"
        }
        if request.reproducible {
            options.reproducibleArchive = true
        }

        let operationID = UUID()
        let recorder = ReleaseStepRecorder()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .create,
            source: .intent,
            title: L10n.format("releaseAssistant.taskTitle", outputURL.lastPathComponent),
            detail: outputURL.path,
            cancellable: false,
            operationID: operationID
        )
        let progressCoalescer = ProgressCoalescer { [weak task] state in
            task?.progress = state
        }
        do {
            // F3 抽出的同一条流水线 —— 不造平行引擎。
            let report = try await ReleaseAssistantPipeline.run(
                request: request,
                source: source,
                destination: destination,
                outputURL: outputURL,
                options: options,
                skipCreate: false,
                recorder: recorder,
                operationID: operationID,
                progress: { state in progressCoalescer.submit(state) },
                outputObserver: nil
            )
            task.transferLog = recorder.steps.map { step in
                TransferLogEntry(
                    name: L10n.text("releaseAssistant.step.\(step.id.rawValue)"),
                    action: step.status == .skipped ? .skipped : .passed,
                    isDirectory: false,
                    detail: step.status == .skipped ? "" : step.formattedDuration
                )
            }
            TaskCenter.shared.finish(task, outcome: .succeeded(outputURL))
            // 与 GUI 同口径:成功跑进发布账本。
            let steps = recorder.steps
            let trimmedLabel = request.versionLabel.trimmingCharacters(in: .whitespaces)
            let fileName = request.fileName
            Task { @MainActor in
                let metadata = await ReportMetadataBuilder.make(targetPath: nil)
                ReleaseLedgerStore().append(ReleaseLedgerEntry(
                    date: Date(),
                    artifactPath: outputURL.path,
                    versionLabel: trimmedLabel.isEmpty ? fileName : trimmedLabel,
                    formatRawValue: request.format.rawValue,
                    sha256: report.sha256,
                    structuralFingerprint: report.structuralFingerprint,
                    reproducible: request.reproducible,
                    excludeJunk: request.excludeJunk,
                    inspectionRan: request.runInspection,
                    testPassed: report.testPassed,
                    suspiciousPathCount: request.runInspection
                        ? report.securityFindings.reduce(0) { $0 + $1.entryPaths.count } : nil,
                    junkCount: report.stats?.junkCount,
                    emptyDirectoryCount: report.stats?.emptyDirectoryCount,
                    fileCount: report.stats?.fileCount,
                    totalBytes: report.stats?.totalBytes,
                    wroteChecksums: request.writeChecksums,
                    signRequested: false,
                    appVersion: metadata.appVersion,
                    backendVersion: metadata.backendVersion,
                    steps: steps
                ))
                // 0.4.4 macOS 26 AI:Shortcuts 跑出的发布包也同步进 Spotlight 索引(macOS 15+,后台、失败静默)。
                ReleasePackageSpotlightIndexer.reindex()
            }
            return .result(
                value: IntentFile(fileURL: outputURL),
                dialog: IntentDialog("\(L10n.format("intent.release.done", outputURL.lastPathComponent))")
            )
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: - Siri / Spotlight 建议

/// App Shortcuts:让三个 intent 不用用户手动建快捷指令就出现在 Shortcuts app /
/// Spotlight / Siri 建议里。`shortTitle` / `systemImageName` 形态的初始化器要 macOS 14;
/// macOS 13 上 intent 本身照常可用,只是不预注册建议。
@available(macOS 14.0, *)
struct SimpleZipAppShortcuts: AppShortcutsProvider {
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
            intent: CreateReleasePackageIntent(),
            phrases: ["Create a release package with \(.applicationName)", "Package a release with \(.applicationName)"],
            shortTitle: "Create Release Package",
            systemImageName: "shippingbox"
        )
    }
}
