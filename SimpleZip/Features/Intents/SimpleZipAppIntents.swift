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
        let preferred = parent.appendingPathComponent("\(baseName).\(createFormat.pathExtension)")
        // 绝不覆盖既有文件:重名走「名 2」「名 3」…(UniqueFileName 同款语义)。
        let destination = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }

        let operationID = UUID()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .create,
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
                  AppPreferences.hasUsablePresetPassword else { throw error }
            try await ArchiveService.test(url, password: AppPreferences.presetPassword, operationID: operationID)
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
            phrases: ["Test an archive with \(.applicationName)"],
            shortTitle: "Test Archive Integrity",
            systemImageName: "checkmark.seal"
        )
    }
}
