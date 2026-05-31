//
//  SevenZipBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 7-Zip CLI 后端的「设备发现 + 元信息查询」层。
///
/// 设计动机：ArchiveService 之前把「按用户偏好挑 bundled / system 7zz」「跑 `-version`」
/// 「拼成给用户看的描述串」这套逻辑跟具体的 list / extract / test / benchmark 实现搅在一起，
/// 加起来超过 100 行。把发现 + 元信息这一层先独立成 backend，让上层（设置面板的
/// SevenZipBackendSection、HealthChecker、DiagnosticsCopier）可以直接调，
/// 不再绕 ArchiveService。
///
/// 操作层（具体的 list / extract / test / benchmark / 创建参数构造）目前仍由 ArchiveService 持有 ——
/// 这是 Phase 4 step 3a。step 3b 会把那些动作也搬过来。
enum SevenZipBackend {

    // MARK: - 设备发现

    /// 解析当前应该用哪份 7zz —— 按用户偏好（automatic / bundled / system）依次找候选路径，
    /// 取第一个 `isExecutableFile` 的。全部失败 → 抛 `ArchiveError.missingSevenZip`。
    static func resolve() throws -> ResolvedSevenZipTool {
        let candidates: [ResolvedSevenZipTool]
        switch AppPreferences.sevenZipBackend {
        case .automatic:
            candidates = bundledCandidates + systemCandidates
        case .bundled:
            candidates = bundledCandidates
        case .system:
            candidates = systemCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingSevenZip
    }

    /// 拿单纯的可执行路径，给 `Process.executableURL` 用。
    static func toolPath() throws -> String {
        try resolve().path
    }

    /// 仅判定可用与否（不要错误信息）。给 Settings 灰按钮、HealthChecker 等用。
    static func isAvailable() -> Bool {
        (try? resolve()) != nil
    }

    // MARK: - 用户面元信息

    /// 「来源 + 路径」一行 —— 在 Settings → Archive → 7-Zip section 和 Health 面板里显示。
    static func backendDescription() -> String {
        do {
            let tool = try resolve()
            return L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    /// 跑 `7zz i` 取第一行版本字符串。找不到 7zz 直接返回 notFound。
    /// 异步 —— 实际启动子进程，等输出。
    static func version() async -> String {
        do {
            let tool = try resolve()
            let output = try await BackendProcessRunner.runAndCapture(tool.path, arguments: ["i"])
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
            return L10n.format("settings.7zip.resolvedVersion", tool.source.title, firstLine.isEmpty ? tool.path : firstLine)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    // MARK: - 操作（Phase 4 step 3b）

    /// 用 `7zz l -slt` 列出压缩包条目。
    /// `password` 非空时走密码 strategy 让 7zz 在交互提示时拿到密码；空时不喂任何输入。
    /// 解析交给 `ArchiveService.parseSevenZipList` —— 那一段已经被 fixture 测试覆盖。
    static func list(
        _ archive: URL,
        password: String = "",
        operationID: UUID? = nil
    ) async throws -> [ArchiveItem] {
        let tool = try toolPath()
        let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
        let output = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: ["l", "-slt", archive.path],
            inputStrategy: inputStrategy,
            operationID: operationID
        )
        return ArchiveService.parseSevenZipList(output)
    }

    /// 用 `7zz x` 整包解压 / `7zz e` 拍平解压。
    /// 空的 `entries` 表示「全包解压」（让 7zz 自己枚举所有条目）；非空时只解指定条目名。
    /// `pathMode == .flatten` 切换到 `e` 让所有条目落到目标目录而不保留路径前缀。
    static func extract(
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
        let tool = try toolPath()
        let arguments = ArchiveService.sevenZipExtractArguments(
            command: pathMode == .flatten ? "e" : "x",
            archive: archive,
            entries: entries,
            destination: destination,
            overwriteBehavior: overwriteBehavior,
            password: password
        )
        let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// 用 `7zz t` 跑完整性测试 —— 7zz 输出非零退出码 → BackendProcessRunner 转成抛错。
    static func test(_ archive: URL, operationID: UUID? = nil, outputObserver: (@Sendable (String) -> Void)? = nil) async throws {
        let tool = try toolPath()
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            // -mmt=on：完整性测试按核心数并行校验各文件 CRC，大归档更快。
            arguments: ["t", archive.path, "-mmt=on"],
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// 跑 `7zz b -bt -md=<dictMB>m [-mmt=<threads>]` 基准测试。
    /// 边跑边把当前累积输出交给 `update` 回调（让 BenchmarkRunView 实时刷分），跑完返回最终解析报告。
    /// 进程输出不能直接 update —— 解析需要看全量；用 `OutputAccumulator` 持有 String 缓冲。
    static func benchmark(
        options: SevenZipBenchmarkOptions,
        operationID: UUID? = nil,
        update: @escaping @Sendable (SevenZipBenchmarkReport, String) -> Void = { _, _ in }
    ) async throws -> SevenZipBenchmarkReport {
        let tool = try resolve()
        var arguments = ["b", "-bt", "-md=\(options.dictionarySizeMB)m"]
        if options.threadCount > 0 {
            arguments.append("-mmt=\(options.threadCount)")
        }
        let backendDescription = L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path)
        let outputBuffer = OutputAccumulator()
        let output = try await BackendProcessRunner.runAndCapture(
            tool.path,
            arguments: arguments,
            outputObserver: { chunk in
                let currentOutput = outputBuffer.append(chunk)
                update(
                    ArchiveService.parseSevenZipBenchmark(
                        currentOutput,
                        backendDescription: backendDescription,
                        options: options
                    ),
                    currentOutput
                )
            },
            operationID: operationID
        )
        return ArchiveService.parseSevenZipBenchmark(
            output,
            backendDescription: backendDescription,
            options: options
        )
    }

    // MARK: - 创建归档

    /// 用 7zz 创建 ZIP（最佳路径）—— 比系统 `/usr/bin/zip` 兼容性 / 压缩率 / 进度反馈都好。
    /// 7zz 不可用时调用方（ArchiveService）会回落到 `NativeZipBackend.createZipFallback`。
    static func createZip(
        destination: URL,
        relativeNames: [String],
        options: ArchiveCreationOptions,
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let tool = try toolPath()
        let arguments = try ArchiveService.sevenZipZipCreateArguments(
            destination: destination,
            relativeNames: relativeNames,
            options: options
        )
        let inputStrategy: ProcessInputStrategy = options.password.isEmpty
            ? .none
            : .passwordPrompts(ArchiveService.passwordResponses(for: options))
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// 用 7zz 创建 .7z。这是 7zz 的本职工作。
    static func createSevenZip(
        destination: URL,
        relativeNames: [String],
        options: ArchiveCreationOptions,
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let tool = try toolPath()
        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: destination,
            relativeNames: relativeNames,
            options: options
        )
        let inputStrategy: ProcessInputStrategy = options.password.isEmpty
            ? .none
            : .passwordPrompts(ArchiveService.passwordResponses(for: options))
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// 单文件流式压缩 —— `.gz` / `.bz2` / `.xz` 都是「就这一个 source 文件压成一个 archive」语义。
    /// `formatFlag` 是 7zz 的 `-t<type>` 后缀：`gzip` / `bzip2` / `xz`。
    static func createSingleFileCompressed(
        formatFlag: String,
        source: URL,
        destination: URL,
        options: ArchiveCreationOptions,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let tool = try toolPath()
        // -bb1 -bsp1 = 让 7zz 把进度往 stdout 喷得能被 ProgressOutputParser 解；-y = 不交互。
        // -mmt：xz / bzip2 这类块/流可并行的格式默认偏单线程，显式开多线程才能跑满 CPU（gzip 单 deflate 流无效但无害）。
        let arguments = [
            "a",
            "-t\(formatFlag)",
            "-mx=\(options.compressionLevel.rawValue)",
            ArchiveService.sevenZipMultithreadArgument(threadCount: options.sevenZipThreadCount),
            destination.path,
            source.lastPathComponent,
            "-bb1",
            "-bsp1",
            "-y"
        ]
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: source.deletingLastPathComponent(),
            progressParser: progressParser,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    // MARK: - 候选路径

    /// App bundle 自带的 7zz 路径 —— DMG 发布版会把 `Contents/Resources/Tools/7zz` 一起打包。
    /// 罗列多个备选名是为了兼容历史 build / 不同打包脚本的产物。
    private static var bundledCandidates: [ResolvedSevenZipTool] {
        guard let resourcePath = Bundle.main.resourceURL?.path else { return [] }
        return [
            "\(resourcePath)/Tools/7zz",
            "\(resourcePath)/Tools/7z",
            "\(resourcePath)/7zz",
            "\(resourcePath)/7z"
        ].map { ResolvedSevenZipTool(path: $0, source: .bundled) }
    }

    /// 系统级 7zz —— Homebrew、p7zip Cellar、$PATH 各种来源。
    /// `uniqueExistingCandidatePaths` 去重；不存在路径在 resolve() 里再过一次 `isExecutableFile`。
    private static var systemCandidates: [ResolvedSevenZipTool] {
        let candidates: [String?] = [
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
            ArchiveService.envPath(for: "7zz"),
            ArchiveService.envPath(for: "7z")
        ]
        let combined = candidates.compactMap { $0 }
            + ArchiveService.cellarCandidates(formula: "sevenzip", tools: ["7zz", "7z"])
            + ArchiveService.cellarCandidates(formula: "p7zip", tools: ["7z"])
        return ArchiveService.uniqueExistingCandidatePaths(combined)
            .map { ResolvedSevenZipTool(path: $0, source: .system) }
    }
}

/// 用户偏好挑出来的「这次该用这份 7zz」结果。path + source 一起放是为了 UI 能显示 "来自 SimpleZip 内置 / 系统"。
struct ResolvedSevenZipTool {
    let path: String
    let source: SevenZipToolSource
}

/// `benchmark` 跑进程时累积 stdout chunk 到完整 String，便于 update 回调实时 reparse。
/// NSLock 保护是因为 `outputObserver` 可能从后台 queue 调用。
private final class OutputAccumulator: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        return buffer
    }
}

/// 7zz 来源 —— 决定用户面板里那行说明文字。
enum SevenZipToolSource {
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
