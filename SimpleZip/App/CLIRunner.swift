//
//  CLIRunner.swift
//  SimpleZip
//
//  `simplezip` CLI companion 的执行器。进程以 PATH 符号链接名(或 `--cli` 前缀)启动时由
//  main.swift 调用:不起 NSApplication、不建窗口,跑完返回退出码直接结束进程。
//  真后端、真退出码、可进脚本/CI;每条完成的命令同步记录进活动中心(见 TaskCenter.recordExternalCLITask)。
//
//  CLI 输出固定英文:经符号链接运行时 Bundle.main 不指向 app bundle(实测 bundlePath 落在
//  链接所在目录、resource 全 nil),L10n 解析不到;脚本解析也需要稳定输出。
//

import AppKit
import Foundation

enum CLIRunner {
    /// 解析到的运行环境 —— 全部从真实可执行文件路径上溯得到,不依赖 Bundle.main。
    private struct Environment {
        let appBundleURL: URL
        let appBundleID: String
        let versionText: String
    }

    /// 退出码约定(与 usage 同步):0 成功;1 操作失败/有差异;2 用法或环境错误。
    /// async + 主 actor:ArchiveService 的入口在 app target 默认隔离下是 MainActor 函数,
    /// 同步阻塞主线程等它必死锁(首版冒烟实测)。main.swift 用 `Task { @MainActor in … }` + `RunLoop.main.run()`
    /// 驱动(**不是** `dispatchMain()` —— 它会停车真主线程,口令小窗弹不出;见 main.swift 注释,A18)。
    static func run(arguments: [String]) async -> Int32 {
        var commandArguments = Array(arguments.dropFirst())
        if commandArguments.first == "--cli" { commandArguments.removeFirst() }
        // 0.4.4 A:全局旗标(--json/--quiet/--verbose)先剥离,再解析子命令。
        let (rest, output) = CLIInvocation.extractOutputOptions(from: commandArguments)

        let invocation: CLIInvocation
        do {
            invocation = try CLIInvocation.parse(rest)
        } catch let error as CLIInvocation.ParseError {
            printError("simplezip: \(error.message)")
            print(CLIInvocation.usage)
            return 2
        } catch {
            printError("simplezip: \(error.localizedDescription)")
            return 2
        }

        switch invocation {
        case .help:
            print(CLIInvocation.usage)
            return 0
        case .helpCommand(let topic):
            print(CLIInvocation.usage(for: topic))
            return 0
        case .completions(let shell):
            // #48:纯打印补全脚本,不需要后端环境。
            print(CLICompletions.script(for: shell))
            return 0
        case .version, .doctor, .open, .list, .check, .inspect, .compare, .create, .extract, .verify, .hash,
             .space, .rescue, .checkup, .duplicates, .reproduce, .auditDirectory, .verifyGroup:
            break
        }

        guard let environment = resolveEnvironment() else {
            printError("simplezip: cannot locate the SimpleZip.app bundle this command belongs to.")
            printError("Reinstall the command from SimpleZip → Settings → General → Command-Line Tool.")
            return 2
        }

        switch invocation {
        case .help, .helpCommand, .completions:
            return 0   // 已在上面的 switch 处理并返回,这里仅为穷尽性。
        case .version:
            if output.json {
                printJSON(["command": "version", "version": environment.versionText])
            } else if !output.quiet {
                print("SimpleZip \(environment.versionText) — simplezip CLI")
            }
            return 0
        case .doctor:
            return await runDoctor(environment: environment, output: output)
        case .open(let paths):
            return runOpen(paths: paths, environment: environment)
        case .check(let paths):
            return await runCheck(paths: paths, environment: environment, output: output)
        case .compare(let left, let right):
            return await runCompare(left: left, right: right, environment: environment, output: output)
        case .create(let outputPath, let inputs, let createOptions):
            return await runCreate(output: outputPath, inputs: inputs, options: createOptions, environment: environment, outputOptions: output)
        case .verify(let paths):
            return await runVerify(paths: paths, environment: environment, output: output)
        case .hash(let paths, let algorithms):
            return await runHash(paths: paths, algorithms: algorithms, environment: environment, output: output)
        case .list(let path):
            return await runList(path: path, environment: environment, output: output)
        case .inspect(let path):
            return await runInspect(path: path, environment: environment, output: output)
        case .extract(let paths, let destination):
            return await runExtract(paths: paths, destination: destination, environment: environment, output: output)
        case .space(let path):
            return await runSpace(path: path, environment: environment, output: output)
        case .rescue(let path, let destination):
            return await runRescue(path: path, destination: destination, environment: environment, output: output)
        case .checkup(let paths):
            return await runCheckup(paths: paths, environment: environment, output: output)
        case .duplicates(let paths):
            return await runDuplicates(paths: paths, environment: environment, output: output)
        case .reproduce(let path, let format):
            return await runReproduce(path: path, format: format, environment: environment, output: output)
        case .auditDirectory(let path):
            return await runAudit(path: path, environment: environment, output: output)
        case .verifyGroup(let path):
            return await runVerifyGroup(path: path, environment: environment, output: output)
        }
    }

    // MARK: - 环境

    private nonisolated static func resolveEnvironment() -> Environment? {
        // argv0 经 PATH 调用时只是 "simplezip",不能拿来定位 —— 用 _NSGetExecutablePath 拿
        // exec 实际用的路径,再解析符号链接回到 .app 内的真实二进制。
        var capacity = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        if _NSGetExecutablePath(&buffer, &capacity) != 0 {
            buffer = [CChar](repeating: 0, count: Int(capacity))
            guard _NSGetExecutablePath(&buffer, &capacity) == 0 else { return nil }
        }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let bundleURL = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SimpleZip.app
        guard bundleURL.pathExtension == "app",
              let bundle = Bundle(url: bundleURL),
              let bundleID = bundle.bundleIdentifier else { return nil }

        // 7zz 解析走现成的 SIMPLEZIP_7ZZ_PATH 钩子 —— CLI 进程的 Bundle.main 找不到资源。
        // 实测内置 7zz 在 Contents/Resources/7zz;Tools/ 子目录是历史备选,一并兜底。
        let sevenZipCandidates = [
            bundleURL.appendingPathComponent("Contents/Resources/7zz"),
            bundleURL.appendingPathComponent("Contents/Resources/Tools/7zz")
        ]
        if let sevenZip = sevenZipCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            setenv("SIMPLEZIP_7ZZ_PATH", sevenZip.path, 1)
        }

        let info = bundle.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return Environment(appBundleURL: bundleURL, appBundleID: bundleID, versionText: "\(short) (\(build))")
    }

    // MARK: - open

    private nonisolated static func runOpen(paths: [String], environment: Environment) -> Int32 {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // 安全:`--` 终止选项,以 - 开头的路径不被 open 当 flag(已实测 open 支持 `--`)。
        process.arguments = ["-a", environment.appBundleURL.path, "--"] + urls.map(\.path)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            printError("simplezip: failed to open: \(error.localizedDescription)")
            return 2
        }
        return process.terminationStatus == 0 ? 0 : 2
    }

    // MARK: - check

    private static func runCheck(paths: [String], environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        var failures = 0
        var results: [[String: Any]] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("simplezip: no such file: \(url.path)")
                failures += 1
                results.append(["path": url.path, "ok": false, "error": "no such file"])
                continue
            }
            let startedAt = Date()
            let output = OutputBuffer()
            // --verbose:后端原始输出直通 stdout(排查 CRC 报错落在哪个条目)。
            let observer: @Sendable (String) -> Void
            if options.verbose {
                observer = { chunk in
                    output.append(chunk)
                    FileHandle.standardOutput.write(Data(chunk.utf8))
                }
            } else {
                observer = { output.append($0) }
            }
            if !options.quiet, !options.json {
                print("Testing \(url.lastPathComponent) ...", terminator: options.verbose ? "\n" : " ")
            }
            do {
                try await testWithPasswordPrompts(url, observer: observer)
                if !options.quiet, !options.json { print("OK") }
                results.append(["path": url.path, "ok": true])
                recordTask(environment: environment, kind: .test,
                           title: "simplezip check \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: output.text)
            } catch is CancellationError {
                failures += 1
                if !options.quiet, !options.json { print("SKIPPED (no password provided)") }
                results.append(["path": url.path, "ok": false, "error": "skipped — no password provided"])
                recordTask(environment: environment, kind: .test,
                           title: "simplezip check \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: false,
                           failureMessage: "skipped — no password provided", rawOutput: output.text)
            } catch {
                failures += 1
                if !options.quiet, !options.json { print("FAILED") }
                printError(indent(describe(error)))
                results.append(["path": url.path, "ok": false, "error": describe(error)])
                recordTask(environment: environment, kind: .test,
                           title: "simplezip check \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: false,
                           failureMessage: describe(error), rawOutput: output.text)
            }
        }
        // 0.4.4 A:批量汇总行(≥2 个才有意义;脚本人读两便)。
        if options.json {
            printJSON([
                "command": "check",
                "results": results,
                "passed": paths.count - failures,
                "failed": failures
            ])
        } else if !options.quiet, paths.count >= 2 {
            print("\(paths.count - failures) passed, \(failures) failed")
        }
        return failures == 0 ? 0 : 1
    }

    /// 加密归档的口令流程(用户拍板:CLI 也弹小窗,不拉起主窗口、绝不走命令行参数/终端回显):
    /// 先空口令试,后端报「需要口令」→ 弹 NSAlert + SecureField,最多三次;取消 → CancellationError。
    private static func testWithPasswordPrompts(_ url: URL, observer: @escaping @Sendable (String) -> Void) async throws {
        try await SignedContainerService.withToolAdaptedArchive(url) { target in
            try await testArchiveWithPasswordPrompts(target, promptName: url.lastPathComponent, observer: observer)
        }
    }

    private static func testArchiveWithPasswordPrompts(_ url: URL, promptName: String, observer: @escaping @Sendable (String) -> Void) async throws {
        do {
            try await ArchiveService.test(url, outputObserver: observer)
            return
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
            var lastError = error
            for _ in 0..<3 {
                guard let password = promptPassword(for: promptName) else {
                    throw CancellationError()
                }
                do {
                    try await ArchiveService.test(url, password: password, outputObserver: observer)
                    return
                } catch {
                    lastError = error
                    guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
                }
            }
            throw lastError
        }
    }

    /// CLI 进程里的口令小窗。进程没有完整 app 生命周期 —— 初始化 NSApplication、以 accessory
    /// 策略置前(无 Dock 图标),runModal 在主线程(CLI 流程本就跑在主 actor)。英文同 CLI 输出。
    private static func promptPassword(for archiveName: String) -> String? {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(archiveName) is password-protected"
        alert.informativeText = "Enter the password to continue. SimpleZip feeds it to the engine directly — it never appears on the command line."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// 只读 list 的口令流程(list / inspect 共用):先空口令,需要口令时先试 `SIMPLEZIP_PASSWORD`(脚本场景免弹窗),
    /// 再弹小窗(最多 3 次)。取消 → CancellationError。口令绝不走 argv / 不回显(同 `create` / `check`)。
    private static func listWithPasswordPrompts(_ url: URL, operationID: UUID? = nil) async throws -> [ArchiveItem] {
        try await SignedContainerService.withToolAdaptedArchive(url) { target in
            try await listArchiveWithPasswordPrompts(target, promptName: url.lastPathComponent, operationID: operationID)
        }
    }

    private static func listArchiveWithPasswordPrompts(_ url: URL, promptName: String, operationID: UUID? = nil) async throws -> [ArchiveItem] {
        do {
            return try await ArchiveService.list(url, operationID: operationID)
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
            var lastError = error
            if let env = ProcessInfo.processInfo.environment["SIMPLEZIP_PASSWORD"], !env.isEmpty {
                do { return try await ArchiveService.list(url, password: env, operationID: operationID) }
                catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
            }
            for _ in 0..<3 {
                guard let password = promptPassword(for: promptName) else { throw CancellationError() }
                do { return try await ArchiveService.list(url, password: password, operationID: operationID) }
                catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
            }
            throw lastError
        }
    }

    /// 解压的口令流程:走 `ExternalExtractRunner`(安全路径),需要口令时先试 `SIMPLEZIP_PASSWORD`、再弹小窗(最多 3 次)。
    /// 候选经 `SessionPasswordCache` 喂给 runner(它内部按 preset + 会话候选逐个试,成功的会记下供同批后续包静默复用)。
    private static func extractWithPasswordPrompts(_ url: URL, destinationDir: URL?, coordinator: ArchiveExtractionCoordinator) async throws -> URL {
        let supportedURL = ArchiveService.supportedArchiveURL(url) ?? url
        func attempt() async throws -> URL {
            try await ExternalExtractRunner.extract(
                archiveURL: url, destinationDirectoryOverride: destinationDir, outputBaseNameOverride: nil,
                operationID: UUID(), coordinator: coordinator, onStatus: { _ in }, onProgress: { _, _ in })
        }
        do {
            return try await attempt()
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
            var lastError = error
            if let env = ProcessInfo.processInfo.environment["SIMPLEZIP_PASSWORD"], !env.isEmpty {
                SessionPasswordCache.shared.record(env, for: supportedURL)
                do { return try await attempt() }
                catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
            }
            for _ in 0..<3 {
                guard let password = promptPassword(for: url.lastPathComponent) else { throw CancellationError() }
                SessionPasswordCache.shared.record(password, for: supportedURL)
                do { return try await attempt() }
                catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
            }
            throw lastError
        }
    }

    // MARK: - compare

    private static func runCompare(left: String, right: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let leftURL = URL(fileURLWithPath: left)
        let rightURL = URL(fileURLWithPath: right)
        for url in [leftURL, rightURL] where !FileManager.default.fileExists(atPath: url.path) {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        let startedAt = Date()
        let title = "simplezip compare \(leftURL.lastPathComponent) \(rightURL.lastPathComponent)"
        do {
            let leftItems = try await SignedContainerService.withToolAdaptedArchive(leftURL) { target in
                try await ArchiveService.list(target)
            }
            let rightItems = try await SignedContainerService.withToolAdaptedArchive(rightURL) { target in
                try await ArchiveService.list(target)
            }
            let result = ArchiveDiff.compare(left: leftItems, right: rightItems)
            var lines: [String] = []
            for item in result.added { lines.append("+ \(item.name)") }
            for item in result.removed { lines.append("- \(item.name)") }
            for change in result.changed {
                let fields = ArchiveDiffField.allCases.filter { change.fields.contains($0) }.map(\.rawValue)
                lines.append("~ \(change.path) (\(fields.joined(separator: ", ")))")
            }
            if options.json {
                printJSON([
                    "command": "compare",
                    "identical": !result.hasDifferences,
                    "added": result.added.count,
                    "removed": result.removed.count,
                    "changed": result.changed.count,
                    "unchanged": result.unchanged.count
                ])
            } else if !options.quiet {
                lines.forEach { print($0) }
            }
            let summary = "added \(result.added.count) · removed \(result.removed.count) · " +
                "changed \(result.changed.count) · unchanged \(result.unchanged.count)"
            if !options.json, !options.quiet {
                print(result.hasDifferences ? summary : "Archives are identical (\(result.unchanged.count) entries).")
            }
            recordTask(environment: environment, kind: .compare, title: title,
                       detail: "\(leftURL.path) ↔ \(rightURL.path)", startedAt: startedAt,
                       succeeded: true, failureMessage: nil,
                       rawOutput: (lines + [summary]).joined(separator: "\n"))
            return result.hasDifferences ? 1 : 0
        } catch {
            printError("simplezip: compare failed: \(describe(error))")
            recordTask(environment: environment, kind: .compare, title: title,
                       detail: "\(leftURL.path) ↔ \(rightURL.path)", startedAt: startedAt,
                       succeeded: false, failureMessage: describe(error), rawOutput: "")
            return 2
        }
    }

    // MARK: - create

    private static func runCreate(output: String, inputs: [String], options createOptions: CLICreateOptions, environment: Environment, outputOptions: CLIOutputOptions) async -> Int32 {
        let templateSlug = createOptions.template
        let outputURL = URL(fileURLWithPath: output)
        let inputURLs = inputs.map { URL(fileURLWithPath: $0) }

        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            printError("simplezip: refusing to overwrite existing file: \(outputURL.path)")
            return 2
        }
        for url in inputURLs where !FileManager.default.fileExists(atPath: url.path) {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        // ArchiveService.createArchive 以**第一个输入的父目录**为工作目录、按文件名相对引用 ——
        // 与 GUI 多选同一约束:所有输入必须在同一目录。
        let parent = inputURLs[0].deletingLastPathComponent().standardizedFileURL
        guard inputURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            printError("simplezip: all inputs must live in the same directory.")
            return 2
        }
        guard let format = createFormat(forOutputName: outputURL.lastPathComponent) else {
            let known = ArchiveCreateFormat.allCases.map(\.pathExtension).joined(separator: ", ")
            printError("simplezip: cannot infer the archive format from \"\(outputURL.lastPathComponent)\" (known: \(known)).")
            return 2
        }

        var options = ArchiveCreationOptions()
        if let templateSlug {
            // 内置任务模板(与创建对话框「套用模板」同一目录;slug 稳定不随语言变)。
            // 模板自带格式 —— 输出扩展名必须对得上,对不上是用户笔误,明确报错而不是悄悄改产物格式。
            guard let template = CompressionPreset.builtInTemplate(slug: templateSlug) else {
                let known = CompressionPreset.builtInTemplateSlugs.joined(separator: ", ")
                printError("simplezip: unknown template \"\(templateSlug)\" (available: \(known)).")
                return 2
            }
            guard template.options.format == format else {
                printError("simplezip: template \"\(templateSlug)\" produces .\(template.options.format.pathExtension) — name the output accordingly.")
                return 2
            }
            options = template.options
        } else {
            options.format = format
            // 与 Finder 一键压缩同口径:套用该格式在 app 里保存且启用的默认值(密码/GPG 永不入库)。
            if let preset = CompressionDefaultsStore(defaults: appDefaults(environment)).preset(for: format),
               preset.enabled {
                preset.apply(to: &options)
            }
        }

        // 0.4.4 A:CLI 旗标在默认值/模板之上覆盖。
        if let level = createOptions.level,
           let compressionLevel = CompressionLevel.closest(toNumeric: level) {
            options.compressionLevel = compressionLevel
        }
        if createOptions.excludeJunk {
            options.skipDSStore = true
            options.customExcludes = "._*, Thumbs.db, desktop.ini"
        }
        if createOptions.reproducible {
            guard options.format == .zip || options.format == .sevenZip else {
                printError("simplezip: --reproducible only applies to zip and 7z outputs.")
                return 2
            }
            options.reproducibleArchive = true
        }
        if createOptions.encrypt {
            guard options.format.supportsPassword else {
                printError("simplezip: .\(options.format.pathExtension) does not support encryption.")
                return 2
            }
            // 口令来源(用户拍板,绝不走 argv):① SIMPLEZIP_PASSWORD 环境变量;② tty 交互(无回显)。
            guard let password = encryptionPassword() else {
                printError("simplezip: --encrypt needs a password — set SIMPLEZIP_PASSWORD or run on an interactive terminal.")
                return 2
            }
            options.password = password
            // 创建校验要求两次密码一致(GUI 是两个输入框);CLI 单一来源,确认字段同值。
            options.passwordConfirmation = password
        }

        let startedAt = Date()
        let title = "simplezip create \(outputURL.lastPathComponent)"
        let progressPrinter = ProgressPrinter()
        let observer: (@Sendable (String) -> Void)?
        if outputOptions.verbose {
            observer = { chunk in
                FileHandle.standardOutput.write(Data(chunk.utf8))
            }
        } else {
            observer = nil
        }
        do {
            try await ArchiveService.createArchive(
                from: inputURLs,
                destination: outputURL,
                options: options,
                progress: { state in
                    if !outputOptions.quiet, !outputOptions.json, !outputOptions.verbose {
                        progressPrinter.update(state)
                    }
                },
                outputObserver: observer
            )
            progressPrinter.finishLine()
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if outputOptions.json {
                var object: [String: Any] = ["command": "create", "ok": true, "output": outputURL.path]
                if let size { object["sizeBytes"] = size }
                printJSON(object)
            } else if !outputOptions.quiet {
                let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
                print("Created \(outputURL.path) (\(sizeText))")
            }
            recordTask(environment: environment, kind: .create, title: title, detail: outputURL.path,
                       startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: "")
            return 0
        } catch {
            progressPrinter.finishLine()
            printError("simplezip: create failed: \(describe(error))")
            recordTask(environment: environment, kind: .create, title: title, detail: outputURL.path,
                       startedAt: startedAt, succeeded: false, failureMessage: describe(error), rawOutput: "")
            return 1
        }
    }

    /// `--encrypt` 的口令来源:SIMPLEZIP_PASSWORD 环境变量优先;否则 tty 无回显交互(getpass)。
    /// 非交互且无环境变量 → nil(调用方报错退出)。**永不**从 argv 读。
    private nonisolated static func encryptionPassword() -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["SIMPLEZIP_PASSWORD"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        guard let raw = getpass("Archive password (not echoed): ") else { return nil }
        let password = String(cString: raw)
        return password.isEmpty ? nil : password
    }

    /// 输出文件名 → 创建格式。`.tar.gz` 先于裸 `gz` 判,其余按最后一个扩展名对 rawValue。
    private nonisolated static func createFormat(forOutputName name: String) -> ArchiveCreateFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return .tarGzip }
        let ext = (lower as NSString).pathExtension
        return ArchiveCreateFormat(rawValue: ext)
    }

    // MARK: - verify

    private static func runVerify(paths: [String], environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        var totalPassed = 0
        var totalFailed = 0
        var fileObjects: [[String: Any]] = []
        for path in paths {
            let (passed, failed) = await verifySingle(path: path, environment: environment, output: options)
            totalPassed += passed
            totalFailed += failed
            fileObjects.append(["file": path, "passed": passed, "failed": failed])
        }
        if options.json {
            printJSON([
                "command": "verify",
                "files": fileObjects,
                "passed": totalPassed,
                "failed": totalFailed,
                "ok": totalFailed == 0
            ])
        } else if !options.quiet, paths.count >= 2 {
            print("TOTAL: \(totalPassed) passed, \(totalFailed) failed")
        }
        return totalFailed == 0 ? 0 : 1
    }

    /// 单个校验文件:返回 (通过条目数, 失败条目数)。读不了 / 没条目按 1 个失败计(汇总口径)。
    private static func verifySingle(path: String, environment: Environment, output options: CLIOutputOptions) async -> (Int, Int) {
        let checksumURL = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            printError("simplezip: cannot read checksum file: \(checksumURL.path)")
            return (0, 1)
        }
        let entries = ChecksumFile.parse(text, fileName: checksumURL.lastPathComponent)
        guard !entries.isEmpty else {
            printError("simplezip: no checksum entries recognized in \(checksumURL.lastPathComponent).")
            return (0, 1)
        }
        let baseDir = checksumURL.deletingLastPathComponent()
        let startedAt = Date()
        var lines: [String] = []
        var failureCount = 0
        for entry in entries {
            // 校验文件是不可信输入(与 app 内同一规则):`..` / 绝对路径 / 反斜杠逃逸 → 不碰文件系统。
            let separatorNormalized = entry.name.replacingOccurrences(of: "\\", with: "/")
            if entry.name.hasPrefix("/") || separatorNormalized.split(separator: "/").contains("..") {
                lines.append("FAIL \(entry.name) (unsafe path, skipped)")
                failureCount += 1
                continue
            }
            let target = baseDir.appendingPathComponent(entry.name)
            guard FileManager.default.fileExists(atPath: target.path) else {
                lines.append("FAIL \(entry.name) (missing)")
                failureCount += 1
                continue
            }
            guard let algorithm = HashAlgorithm(rawValue: entry.algorithm.rawValue) else { continue }
            do {
                let report = try await HashService.calculate(for: [target], includeHiddenFiles: true, algorithms: [algorithm])
                let actual = report.results.first?.hashes[algorithm]?.lowercased() ?? ""
                if actual == entry.digestHex {
                    lines.append("PASS \(entry.name) (\(entry.algorithm.rawValue))")
                } else {
                    lines.append("FAIL \(entry.name) (\(entry.algorithm.rawValue) mismatch)")
                    failureCount += 1
                }
            } catch {
                lines.append("FAIL \(entry.name) (\(describe(error)))")
                failureCount += 1
            }
        }
        let summary = failureCount == 0
            ? "All \(entries.count) entries passed."
            : "\(failureCount) of \(entries.count) entries failed."
        if !options.quiet, !options.json {
            lines.forEach { print($0) }
            print(summary)
        }
        recordTask(environment: environment, kind: .hash, category: .fileOperation,
                   title: "simplezip verify \(checksumURL.lastPathComponent)", detail: checksumURL.path,
                   startedAt: startedAt, succeeded: failureCount == 0,
                   failureMessage: failureCount == 0 ? nil : summary,
                   rawOutput: (lines + [summary]).joined(separator: "\n"))
        return (entries.count - failureCount, failureCount)
    }

    // MARK: - hash(0.4.5)

    /// 计算文件 / 文件夹的校验和。输出 BSD-tag 风格 `ALGO (path) = hex`(`simplezip verify` 能读回)。
    /// 任一路径不存在 / 读不出 → exit 1;每个输入路径记一条活动中心任务。
    private static func runHash(paths: [String], algorithms: [HashAlgorithm], environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        var failures = 0
        var resultObjects: [[String: Any]] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("simplezip: no such file: \(url.path)")
                failures += 1
                continue
            }
            let startedAt = Date()
            do {
                let report = try await HashService.calculate(for: [url], includeHiddenFiles: true, algorithms: algorithms)
                var lines: [String] = []
                for result in report.results where !isCurrentChecksumRedirectCandidate(result, sourceURL: url) {
                    // 算法按用户传入顺序输出(report.algorithms 即此顺序)。
                    for algorithm in report.algorithms {
                        guard let hex = result.hashes[algorithm] else { continue }
                        let checksumName = checksumEntryName(for: result.url, sourceURL: url)
                        lines.append("\(algorithm.rawValue) (\(checksumName)) = \(hex)")
                        resultObjects.append(["file": result.url.path, "algorithm": algorithm.rawValue, "hash": hex, "size": result.size])
                    }
                }
                if !options.quiet, !options.json { lines.forEach { print($0) } }
                recordTask(environment: environment, kind: .hash, category: .fileOperation,
                           title: "simplezip hash \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: true, failureMessage: nil,
                           rawOutput: lines.joined(separator: "\n"))
            } catch {
                printError("simplezip: hash failed for \(url.path): \(describe(error))")
                failures += 1
                recordTask(environment: environment, kind: .hash, category: .fileOperation,
                           title: "simplezip hash \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: false, failureMessage: describe(error),
                           rawOutput: describe(error))
            }
        }
        if options.json {
            printJSON(["command": "hash", "results": resultObjects, "ok": failures == 0])
        }
        return failures == 0 ? 0 : 1
    }

    /// `simplezip hash . > SHA256SUMS` creates an empty checksum file before the
    /// process starts; hashing that file makes the generated manifest fail itself.
    private nonisolated static func isCurrentChecksumRedirectCandidate(_ result: FileHashResult, sourceURL: URL) -> Bool {
        guard result.size == 0,
              ChecksumFile.isChecksumFileName(result.url.lastPathComponent) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        return result.url.deletingLastPathComponent().standardizedFileURL.path == currentDirectory.path
    }

    /// `verify` intentionally rejects absolute paths and `..`; make `hash > SHA256SUMS`
    /// produce entries that remain inside the checksum file's directory.
    private nonisolated static func checksumEntryName(for resultURL: URL, sourceURL: URL) -> String {
        let targetURL = resultURL.standardizedFileURL
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if let relative = relativePath(from: currentDirectoryURL, to: targetURL),
           isSafeChecksumEntryName(relative) {
            return relative
        }
        let baseURL = sourceURL.deletingLastPathComponent().standardizedFileURL
        if let relative = relativePath(from: baseURL, to: targetURL),
           isSafeChecksumEntryName(relative) {
            return relative
        }
        return resultURL.lastPathComponent
    }

    private nonisolated static func relativePath(from baseURL: URL, to targetURL: URL) -> String? {
        let baseComponents = baseURL.pathComponents
        let targetComponents = targetURL.pathComponents
        guard targetComponents.count > baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }
        let relative = targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
        return relative.isEmpty ? nil : relative
    }

    private nonisolated static func isSafeChecksumEntryName(_ name: String) -> Bool {
        guard !name.hasPrefix("/") else { return false }
        let separatorNormalized = name.replacingOccurrences(of: "\\", with: "/")
        return !separatorNormalized.split(separator: "/").contains("..")
    }

    // MARK: - list(0.4.5)

    /// 列出归档条目(只读)。人读:每行 `d|-  <size>  <name>`;`--json` 出条目数组。
    /// 加密名归档需要口令 → 弹小窗(或 `SIMPLEZIP_PASSWORD`);取消 / 仍失败 → exit 1。
    private static func runList(path: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        do {
            let items = try await listWithPasswordPrompts(url)
            if options.json {
                let entries = items.map { ["name": $0.name, "size": $0.size ?? 0, "directory": $0.isDirectory] as [String: Any] }
                printJSON(["command": "list", "archive": url.path, "count": items.count, "entries": entries])
            } else if !options.quiet {
                for item in items {
                    print("\(item.isDirectory ? "d" : "-")\t\(item.size ?? 0)\t\(item.name)")
                }
            }
            return 0
        } catch {
            printError("simplezip: cannot list \(url.path): \(describe(error))")
            return 1
        }
    }

    // MARK: - inspect(0.4.5,发布包检测)

    /// 不解压地体检归档(发布包检测):统计 + 可疑条目路径。exit 1 当发现可疑路径,0 当干净;列不出 → exit 1。
    private static func runInspect(path: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        let startedAt = Date()
        do {
            let items = try await listWithPasswordPrompts(url)
            let stats = ReleaseInspection.stats(for: items)
            let findings = ArchiveSecurityReport.analyze(items)
            let flaggedPaths = findings.reduce(0) { $0 + $1.entryPaths.count }
            let sizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
            var lines: [String] = [
                "Files: \(stats.fileCount)",
                "Folders: \(stats.folderCount)",
                "Total size: \(sizeText)",
                "macOS junk entries: \(stats.junkCount)",
                "Empty directories: \(stats.emptyDirectoryCount)",
                "Executables: \(stats.executableCount)",
                "Symlinks: \(stats.symlinkCount)"
            ]
            if findings.isEmpty {
                lines.append("Suspicious paths: none")
            } else {
                lines.append("Suspicious paths: \(flaggedPaths) across \(findings.count) categories")
                for finding in findings { lines.append("  \(finding.kind.rawValue): \(finding.entryPaths.count)") }
            }
            if options.json {
                let findingObjects = findings.map { ["kind": $0.kind.rawValue, "count": $0.entryPaths.count] as [String: Any] }
                printJSON([
                    "command": "inspect", "archive": url.path,
                    "fileCount": stats.fileCount, "folderCount": stats.folderCount, "totalBytes": stats.totalBytes,
                    "junkCount": stats.junkCount, "emptyDirectoryCount": stats.emptyDirectoryCount,
                    "executableCount": stats.executableCount, "symlinkCount": stats.symlinkCount,
                    "suspiciousFindings": findingObjects, "clean": findings.isEmpty
                ])
            } else if !options.quiet {
                lines.forEach { print($0) }
            }
            recordTask(environment: environment, kind: .inspect, category: .archive,
                       title: "simplezip inspect \(url.lastPathComponent)", detail: url.path,
                       startedAt: startedAt, succeeded: true, failureMessage: nil,
                       rawOutput: lines.joined(separator: "\n"))
            return findings.isEmpty ? 0 : 1
        } catch {
            printError("simplezip: cannot inspect \(url.path): \(describe(error))")
            recordTask(environment: environment, kind: .inspect, category: .archive,
                       title: "simplezip inspect \(url.lastPathComponent)", detail: url.path,
                       startedAt: startedAt, succeeded: false, failureMessage: describe(error), rawOutput: describe(error))
            return 1
        }
    }

    // MARK: - extract(0.4.5)

    /// 解压归档到唯一命名文件夹(走 `ExternalExtractRunner` —— 与 Finder 自动解压同一条安全路径:不可信条目校验、
    /// staging、冲突处理)。加密包弹口令小窗(或 `SIMPLEZIP_PASSWORD`,绝不走 argv);取消 / 任一失败 → exit 1。
    private static func runExtract(paths: [String], destination: String?, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        var destinationDir: URL?
        if let destination {
            let dir = URL(fileURLWithPath: destination)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                printError("simplezip: destination is not an existing folder: \(dir.path)")
                return 2
            }
            destinationDir = dir
        }
        let coordinator = ArchiveExtractionCoordinator(fileManager: .default)
        var failures = 0
        var resultObjects: [[String: Any]] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("simplezip: no such file: \(url.path)")
                failures += 1
                continue
            }
            let startedAt = Date()
            do {
                let target = try await extractWithPasswordPrompts(url, destinationDir: destinationDir, coordinator: coordinator)
                if !options.quiet, !options.json { print("Extracted \(url.lastPathComponent) → \(target.path)") }
                resultObjects.append(["archive": url.path, "output": target.path, "ok": true])
                recordTask(environment: environment, kind: .extract, category: .archive,
                           title: "simplezip extract \(url.lastPathComponent)", detail: target.path,
                           startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: "→ \(target.path)")
            } catch {
                printError("simplezip: extract failed for \(url.path): \(describe(error))")
                failures += 1
                resultObjects.append(["archive": url.path, "ok": false, "error": describe(error)])
                recordTask(environment: environment, kind: .extract, category: .archive,
                           title: "simplezip extract \(url.lastPathComponent)", detail: url.path,
                           startedAt: startedAt, succeeded: false, failureMessage: describe(error), rawOutput: describe(error))
            }
        }
        if options.json {
            printJSON(["command": "extract", "results": resultObjects, "ok": failures == 0])
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - 工具批输入归一(0.4.5)

    /// 单个目录 → 目录内顶层可用归档(含 `.siz`,名称自然排序);否则原样当成归档路径列表。供 checkup / duplicates 用。
    private static func resolveArchiveInputs(_ paths: [String]) -> [URL] {
        if paths.count == 1 {
            let url = URL(fileURLWithPath: paths[0])
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                return contents
                    .filter { SignedContainerService.isToolableArchive($0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - space(0.4.5,空间分析)

    private static func runSpace(path: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        let startedAt = Date()
        do {
            let items = try await listWithPasswordPrompts(url)
            let a = ArchiveSpaceAnalysis.analyze(items)
            func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
            var lines: [String] = [
                "Files: \(a.fileCount)",
                "Original size: \(bytes(a.totalBytes))",
                "Packed size: \(bytes(a.packedBytes))"
            ]
            if let ratio = a.compressionRatio { lines.append("Compression ratio: \(String(format: "%.0f%%", ratio * 100))") }
            if a.junkCount > 0 { lines.append("macOS junk: \(a.junkCount) entries, \(bytes(a.junkBytes))") }
            if a.encryptedCount > 0 { lines.append("Encrypted entries: \(a.encryptedCount), \(bytes(a.encryptedBytes))") }
            if !a.largestFiles.isEmpty {
                lines.append("Largest files:")
                a.largestFiles.forEach { lines.append("  \(bytes($0.bytes))\t\($0.name)") }
            }
            if !a.topLevelDirectories.isEmpty {
                lines.append("Top-level folders:")
                a.topLevelDirectories.prefix(10).forEach { lines.append("  \(bytes($0.bytes))\t\($0.name.isEmpty ? "(root)" : $0.name)") }
            }
            if !a.extensions.isEmpty {
                lines.append("Extensions:")
                a.extensions.forEach { lines.append("  \(bytes($0.bytes))\t\($0.name.isEmpty ? "(none)" : $0.name)") }
            }
            if options.json {
                printJSON([
                    "command": "space", "archive": url.path,
                    "fileCount": a.fileCount, "totalBytes": a.totalBytes, "packedBytes": a.packedBytes,
                    "junkCount": a.junkCount, "junkBytes": a.junkBytes,
                    "encryptedCount": a.encryptedCount, "encryptedBytes": a.encryptedBytes,
                    "largestFiles": a.largestFiles.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] },
                    "topLevelFolders": a.topLevelDirectories.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] },
                    "extensions": a.extensions.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] }
                ])
            } else if !options.quiet {
                lines.forEach { print($0) }
            }
            recordTask(environment: environment, kind: .inspect, category: .archive,
                       title: "simplezip space \(url.lastPathComponent)", detail: url.path,
                       startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: lines.joined(separator: "\n"))
            return 0
        } catch {
            printError("simplezip: cannot analyze \(url.path): \(describe(error))")
            return 1
        }
    }

    // MARK: - rescue(0.4.5,数据救援)

    private static func runRescue(path: String, destination: String?, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printError("simplezip: no such file: \(url.path)")
            return 2
        }
        var destinationParent: URL?
        if let destination {
            let dir = URL(fileURLWithPath: destination)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                printError("simplezip: destination is not an existing folder: \(dir.path)")
                return 2
            }
            destinationParent = dir
        }
        // 损坏包可能列不动 → best-effort;列得动则 run() 内部照常过 validateForExtraction。
        let listed = try? await ArchiveService.list(url)
        let startedAt = Date()
        func attempt(_ password: String) async throws -> ArchiveSalvage.Outcome {
            try await ArchiveSalvage.run(archive: url, listedItems: listed, password: password,
                                         destinationParent: destinationParent, operationID: UUID(), outputObserver: nil)
        }
        do {
            var outcome: ArchiveSalvage.Outcome
            do {
                outcome = try await attempt("")
            } catch {
                guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
                var resolved: ArchiveSalvage.Outcome?
                var lastError = error
                if let env = ProcessInfo.processInfo.environment["SIMPLEZIP_PASSWORD"], !env.isEmpty {
                    do { resolved = try await attempt(env) }
                    catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
                }
                if resolved == nil {
                    for _ in 0..<3 {
                        guard let password = promptPassword(for: url.lastPathComponent) else { throw CancellationError() }
                        do { resolved = try await attempt(password); break }
                        catch { lastError = error; guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error } }
                    }
                }
                guard let resolvedOutcome = resolved else { throw lastError }
                outcome = resolvedOutcome
            }
            var lines: [String] = [
                "Rescued \(outcome.rescuedFileCount) file(s) → \(outcome.destination.path)"
            ]
            if let reported = outcome.reportedErrorCount { lines.append("Backend reported \(reported) sub-item error(s).") }
            if !outcome.failedEntryPaths.isEmpty {
                lines.append("Could not read:")
                outcome.failedEntryPaths.prefix(20).forEach { lines.append("  \($0)") }
            }
            lines.append("Note: rescued files may be incomplete; the archive itself was NOT repaired.")
            if options.json {
                let reportedErrorJSON: Any
                if let count = outcome.reportedErrorCount { reportedErrorJSON = count } else { reportedErrorJSON = NSNull() }
                printJSON([
                    "command": "rescue", "archive": url.path, "destination": outcome.destination.path,
                    "rescuedFileCount": outcome.rescuedFileCount,
                    "reportedErrorCount": reportedErrorJSON,
                    "failedEntryPaths": outcome.failedEntryPaths
                ])
            } else if !options.quiet {
                lines.forEach { print($0) }
            }
            recordTask(environment: environment, kind: .extract, category: .archive,
                       title: "simplezip rescue \(url.lastPathComponent)", detail: outcome.destination.path,
                       startedAt: startedAt, succeeded: outcome.rescuedFileCount > 0,
                       failureMessage: outcome.rescuedFileCount > 0 ? nil : "nothing recovered",
                       rawOutput: lines.joined(separator: "\n"))
            // 一个文件都没救出来 = 失败(exit 1);救出 ≥1 即成功(部分救援是预期)。
            return outcome.rescuedFileCount > 0 ? 0 : 1
        } catch is CancellationError {
            printError("simplezip: rescue cancelled.")
            return 1
        } catch {
            printError("simplezip: rescue failed for \(url.path): \(describe(error))")
            return 1
        }
    }

    // MARK: - checkup(0.4.5,批量体检)

    private static func runCheckup(paths: [String], environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let urls = resolveArchiveInputs(paths)
        guard !urls.isEmpty else {
            printError("simplezip: no archives to check.")
            return 2
        }
        let startedAt = Date()
        var failures = 0
        var rowObjects: [[String: Any]] = []
        var lines: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                printError("simplezip: no such file: \(url.path)")
                lines.append("\(url.lastPathComponent): missing")
                failures += 1
                continue
            }
            // 批量场景不弹密码框:列不动/需口令的如实标注,不打断整批。
            let probe: (items: [ArchiveItem], testResult: String, testFailed: Bool)?
            do {
                probe = try await SignedContainerService.withToolAdaptedArchive(url, perform: { target in
                    let items = try await ArchiveService.list(target)
                    var testResult = "passed"
                    var testFailed = false
                    do {
                        try await ArchiveService.test(target, password: "")
                    } catch {
                        testFailed = true
                        testResult = ArchiveService.errorSuggestsPasswordRequirement(error) ? "needs password" : "FAILED"
                    }
                    return (items, testResult, testFailed)
                })
            } catch {
                probe = nil
            }
            guard let probe else {
                lines.append("\(url.lastPathComponent): not listable (encrypted name or damaged)")
                failures += 1
                rowObjects.append(["archive": url.path, "listable": false, "test": "not listable"])
                continue
            }
            let items = probe.items
            let facts = ArchiveCheckup.entryFacts(items: items)
            let stats = ReleaseInspection.stats(for: items)
            let testResult = probe.testResult
            if probe.testFailed { failures += 1 }
            let sizeText = ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
            lines.append("\(url.lastPathComponent): \(testResult) · \(stats.fileCount) files · \(sizeText) · suspicious \(facts.suspiciousPathCount) · junk \(facts.junkCount) · encrypted \(facts.encryptedCount)")
            rowObjects.append([
                "archive": url.path, "listable": true, "test": testResult,
                "fileCount": stats.fileCount, "totalBytes": stats.totalBytes,
                "suspiciousPathCount": facts.suspiciousPathCount, "junkCount": facts.junkCount,
                "encryptedCount": facts.encryptedCount
            ])
        }
        if options.json {
            printJSON(["command": "checkup", "rows": rowObjects, "archives": urls.count, "failed": failures, "ok": failures == 0])
        } else if !options.quiet {
            lines.forEach { print($0) }
            if urls.count >= 2 { print("\(urls.count) archives · \(failures) failed") }
        }
        recordTask(environment: environment, kind: .test, category: .archive,
                   title: "simplezip checkup (\(urls.count))", detail: nil,
                   startedAt: startedAt, succeeded: failures == 0,
                   failureMessage: failures == 0 ? nil : "\(failures) failed", rawOutput: lines.joined(separator: "\n"))
        return failures == 0 ? 0 : 1
    }

    // MARK: - duplicates(0.4.5,查找疑似重复归档)

    private static func runDuplicates(paths: [String], environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let urls = resolveArchiveInputs(paths)
        guard urls.count >= 2 else {
            printError("simplezip: need at least two archives to compare.")
            return 2
        }
        let startedAt = Date()
        var sources: [ArchiveDuplicateScan.Source] = []
        var skipped: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { skipped.append(url.lastPathComponent); continue }
            // `.siz` 按内层算指纹;列不动(加密名/损坏)→ 跳过(与 GUI 同口径,批量不弹框)。
            let items: [ArchiveItem]? = try? await SignedContainerService.withToolAdaptedArchive(url) { target in
                try await ArchiveService.list(target)
            }
            guard let items else { skipped.append(url.lastPathComponent); continue }
            let files = items.filter { !$0.isDirectory }
            sources.append(ArchiveDuplicateScan.Source(
                url: url,
                fingerprint: ArchiveStructuralFingerprint.compute(for: items),
                entryCount: files.count,
                totalBytes: files.reduce(0) { $0 + ($1.size ?? 0) }))
        }
        let groups = ArchiveDuplicateScan.groups(from: sources)
        var lines: [String] = []
        if groups.isEmpty {
            lines.append("No duplicate archives found among \(sources.count) scanned.")
        } else {
            for group in groups {
                let kind = group.confidence == .identicalStructure ? "identical structure" : "same count & size"
                lines.append("[\(kind)] \(group.urls.map(\.lastPathComponent).joined(separator: ", "))")
            }
        }
        if !skipped.isEmpty { lines.append("Skipped (not listable): \(skipped.joined(separator: ", "))") }
        if options.json {
            printJSON([
                "command": "duplicates", "scanned": sources.count, "skipped": skipped,
                "groups": groups.map { group -> [String: Any] in
                    ["confidence": group.confidence == .identicalStructure ? "identicalStructure" : "sameCountAndSize",
                     "archives": group.urls.map(\.path)]
                }
            ])
        } else if !options.quiet {
            lines.forEach { print($0) }
        }
        recordTask(environment: environment, kind: .test, category: .archive,
                   title: "simplezip duplicates (\(sources.count))", detail: nil,
                   startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: lines.joined(separator: "\n"))
        return 0
    }

    // MARK: - reproduce(0.4.5,可复现报告)

    private static func runReproduce(path: String, format: String?, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let folderURL = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            printError("simplezip: reproduce needs a folder: \(folderURL.path)")
            return 2
        }
        let token = format ?? "zip"
        guard let createFmt = createFormat(forOutputName: "x.\(token)") else {
            printError("simplezip: unknown format \"\(token)\" (use zip or 7z).")
            return 2
        }
        guard createFmt == .zip || createFmt == .sevenZip else {
            printError("simplezip: reproduce supports only zip and 7z (reproducible formats).")
            return 2
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-Reproduce-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            printError("simplezip: cannot create temp dir: \(describe(error))")
            return 2
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        var creationOptions = ArchiveCreationOptions()
        creationOptions.format = createFmt
        creationOptions.reproducibleArchive = true
        let ext = createFmt.pathExtension
        let first = temp.appendingPathComponent("first.\(ext)")
        let second = temp.appendingPathComponent("second.\(ext)")
        let startedAt = Date()
        do {
            try await ArchiveService.createArchive(from: [folderURL], destination: first, options: creationOptions)
            try await ArchiveService.createArchive(from: [folderURL], destination: second, options: creationOptions)
            let firstHash = try HashService.sha256(for: first)
            let secondHash = try HashService.sha256(for: second)
            var report = ReproducibilityReport.analyze(format: createFmt, reproducibleEnabled: true)
            report.firstSHA256 = firstHash
            report.secondSHA256 = secondHash
            let identical = report.identical ?? false
            var lines: [String] = [
                "Format: .\(ext)",
                "Byte-for-byte identical: \(identical ? "yes" : "no")",
                "First  SHA-256: \(firstHash)",
                "Second SHA-256: \(secondHash)",
                "Factors:"
            ]
            for factor in report.factors { lines.append("  \(factor.factor.rawValue): \(factor.status.rawValue)") }
            if !identical, !report.nonReproducibleFactors.isEmpty {
                lines.append("Likely culprits (stored as-is): \(report.nonReproducibleFactors.map(\.rawValue).joined(separator: ", "))")
            }
            if options.json {
                printJSON([
                    "command": "reproduce", "folder": folderURL.path, "format": ext,
                    "identical": identical, "firstSHA256": firstHash, "secondSHA256": secondHash,
                    "factors": report.factors.map { ["factor": $0.factor.rawValue, "status": $0.status.rawValue] as [String: Any] }
                ])
            } else if !options.quiet {
                lines.forEach { print($0) }
            }
            recordTask(environment: environment, kind: .inspect, category: .archive,
                       title: "simplezip reproduce \(folderURL.lastPathComponent)", detail: folderURL.path,
                       startedAt: startedAt, succeeded: true, failureMessage: nil, rawOutput: lines.joined(separator: "\n"))
            return identical ? 0 : 1
        } catch {
            printError("simplezip: reproduce failed: \(describe(error))")
            return 1
        }
    }

    // MARK: - audit(0.4.5,检查发布包目录)

    private static func runAudit(path: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let dir = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            printError("simplezip: audit needs a folder: \(dir.path)")
            return 2
        }
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
        var missingRefs: [String] = []
        for doc in inventory.verifyDocs {
            if let text = try? String(contentsOf: dir.appendingPathComponent(doc), encoding: .utf8) {
                missingRefs += ReleaseDirectoryAudit.missingDocumentReferences(documentText: text, directoryNames: names)
            }
        }
        let orphans = ReleaseDirectoryAudit.orphans(in: inventory)
        let startedAt = Date()
        var lines: [String] = [
            "Artifacts: \(inventory.artifacts.count) · checksum files: \(inventory.checksumFiles.count) · containers: \(inventory.containers.count) · public keys: \(inventory.publicKeys.count) · VERIFY docs: \(inventory.verifyDocs.count)"
        ]
        if !coverage.uncovered.isEmpty { lines.append("UNCOVERED by SHA256SUMS: \(coverage.uncovered.joined(separator: ", "))") }
        if !coverage.stale.isEmpty { lines.append("Stale checksum entries (no such file): \(coverage.stale.joined(separator: ", "))") }
        if !missingRefs.isEmpty { lines.append("VERIFY doc references missing on disk: \(missingRefs.joined(separator: ", "))") }
        if !orphans.isEmpty { lines.append("Orphan files (not a known release role): \(orphans.joined(separator: ", "))") }
        if coverage.uncovered.isEmpty, coverage.stale.isEmpty, missingRefs.isEmpty {
            lines.append("No coverage gaps, stale entries or broken references found.")
        }
        if options.json {
            printJSON([
                "command": "audit", "folder": dir.path,
                "artifacts": inventory.artifacts, "checksumFiles": inventory.checksumFiles,
                "containers": inventory.containers, "publicKeys": inventory.publicKeys, "verifyDocs": inventory.verifyDocs,
                "uncovered": coverage.uncovered, "staleChecksumEntries": coverage.stale,
                "missingDocReferences": missingRefs, "orphans": orphans,
                "ok": coverage.uncovered.isEmpty
            ])
        } else if !options.quiet {
            lines.forEach { print($0) }
        }
        recordTask(environment: environment, kind: .inspect, category: .archive,
                   title: "simplezip audit \(dir.lastPathComponent)", detail: dir.path,
                   startedAt: startedAt, succeeded: coverage.uncovered.isEmpty,
                   failureMessage: coverage.uncovered.isEmpty ? nil : "uncovered artifacts", rawOutput: lines.joined(separator: "\n"))
        // 有产物没被 SHA256SUMS 覆盖 = 下载者无从校验 → exit 1。
        return coverage.uncovered.isEmpty ? 0 : 1
    }

    // MARK: - verify-group(0.4.5,快速核对发布组)

    private static func runVerifyGroup(path: String, environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let dir = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            printError("simplezip: verify-group needs a folder: \(dir.path)")
            return 2
        }
        let names = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
        let inventory = ReleaseDirectoryAudit.classify(names: names) { ArchiveService.isSupportedArchive(URL(fileURLWithPath: $0)) }
        let summary = ReleaseDirectoryAudit.quickVerify(inventory)
        func mark(_ value: Bool) -> String { value ? "yes" : "no" }
        let lines = [
            "Downloadable artifact: \(mark(summary.hasArtifact))",
            "Signed container (.szs/.siz): \(mark(summary.hasContainer))",
            "SHA256SUMS: \(mark(summary.hasChecksums))",
            "Public key: \(mark(summary.hasPublicKey))",
            "VERIFY doc: \(mark(summary.hasVerifyDoc))",
            "Verifiable by a downloader: \(mark(summary.isVerifiable))"
        ]
        if options.json {
            printJSON([
                "command": "verify-group", "folder": dir.path,
                "hasArtifact": summary.hasArtifact, "hasContainer": summary.hasContainer,
                "hasChecksums": summary.hasChecksums, "hasPublicKey": summary.hasPublicKey,
                "hasVerifyDoc": summary.hasVerifyDoc, "verifiable": summary.isVerifiable
            ])
        } else if !options.quiet {
            lines.forEach { print($0) }
        }
        return summary.isVerifiable ? 0 : 1
    }

    // MARK: - doctor(0.4.4 A)

    /// 环境体检:app bundle / 版本 / 7zz / RAR / GPG / 符号链接指向。只读,逐行报告。
    private static func runDoctor(environment: Environment, output options: CLIOutputOptions) async -> Int32 {
        let sevenZipPath = ProcessInfo.processInfo.environment["SIMPLEZIP_7ZZ_PATH"] ?? "(not found)"
        let sevenZipVersion = await ArchiveService.sevenZipVersion()
        let rarVersion = await ArchiveService.rarVersion()
        let gpgAvailable = GPGBackend.isAvailable()

        // 符号链接:CLI 进程不能用 Bundle.main,对照 environment 的 app bundle 路径判断指向。
        let linkPath = "/usr/local/bin/simplezip"
        let linkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        let expectedPrefix = environment.appBundleURL.path
        let linkStatus: String
        if let linkDestination {
            linkStatus = linkDestination.hasPrefix(expectedPrefix)
                ? "ok → \(linkDestination)"
                : "points elsewhere → \(linkDestination)"
        } else {
            linkStatus = FileManager.default.fileExists(atPath: linkPath) ? "occupied by a non-symlink" : "not installed"
        }

        if options.json {
            printJSON([
                "command": "doctor",
                "app": environment.appBundleURL.path,
                "version": environment.versionText,
                "sevenZip": ["path": sevenZipPath, "version": sevenZipVersion],
                "rar": ["version": rarVersion],
                "gpg": ["available": gpgAvailable],
                "symlink": ["path": linkPath, "status": linkStatus]
            ])
        } else {
            print("SimpleZip.app : \(environment.appBundleURL.path)")
            print("Version       : \(environment.versionText)")
            print("7-Zip engine  : \(sevenZipPath)")
            print("                \(sevenZipVersion)")
            print("RAR backend   : \(rarVersion)")
            print("GPG backend   : \(gpgAvailable ? "available" : "not available")")
            print("CLI symlink   : \(linkStatus)")
        }
        // 7zz 找不到 = 环境坏(exit 2);其余都是可选件,如实报告即可。
        return sevenZipPath == "(not found)" ? 2 : 0
    }

    /// JSON 输出(sortedKeys,稳定可脚本解析)。
    private nonisolated static func printJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            printError("simplezip: internal error encoding JSON output")
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - 共用

    private nonisolated static func recordTask(
        environment: Environment,
        kind: OperationTask.Kind,
        category: OperationTask.Category = .archive,
        title: String,
        detail: String?,
        startedAt: Date,
        succeeded: Bool,
        failureMessage: String?,
        rawOutput: String
    ) {
        TaskCenter.recordExternalCLITask(
            appBundleID: environment.appBundleID,
            category: category,
            kind: kind,
            title: title,
            detail: detail,
            startedAt: startedAt,
            succeeded: succeeded,
            failureMessage: failureMessage,
            rawOutput: rawOutput
        )
    }

    private nonisolated static func appDefaults(_ environment: Environment) -> UserDefaults {
        // direct `--cli` 用 .standard;经 PATH symlink 运行时显式打开 app 偏好域(A19)。
        TaskCenter.defaultsForAppBundleID(environment.appBundleID) ?? .standard
    }

    /// 线程安全的输出收集器 —— outputObserver 从后台回调,主线程收尾时读。
    private nonisolated final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        // 上限:大归档(几万条目)的 7zz 逐条输出可达数 MB。rawOutput 会进 TaskCenter → UserDefaults 任务历史,
        // 超 ~4MB 会被 macOS **静默丢弃**(整条历史没了)。超阈值就从头截断、保留尾部(最新、对失败诊断最有用)。
        // 触发用 utf8.count(原生 String O(1))、截断 O(keep),摊销 O(1)/字符,不会变 O(n²)。
        private static let trimThresholdBytes = 1_048_576   // 1MB 触发
        private static let keepCharacters = 500_000         // 截后保留尾部(ASCII 输出 ≈ 0.5MB,远低于 4MB)

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
            if buffer.utf8.count > Self.trimThresholdBytes {
                buffer = "…(output truncated)…\n" + String(buffer.suffix(Self.keepCharacters))
            }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// 进度打印:同一行刷百分比(每 ≥1% 更新一次),结束补换行。无 fraction 的阶段不打。
    private nonisolated final class ProgressPrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1
        private var printedAnything = false

        func update(_ state: ArchiveProgressState) {
            guard let fraction = state.fraction else { return }
            let percent = min(100, max(0, Int(fraction * 100)))
            lock.lock()
            defer { lock.unlock() }
            guard percent != lastPercent else { return }
            lastPercent = percent
            printedAnything = true
            FileHandle.standardOutput.write(Data("\r\(percent)%".utf8))
        }

        func finishLine() {
            lock.lock()
            defer { lock.unlock() }
            if printedAnything {
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let archiveError = error as? ArchiveError {
            return archiveError.localizedDescription
        }
        return error.localizedDescription
    }

    private nonisolated static func indent(_ text: String) -> String {
        text.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
    }

    private nonisolated static func printError(_ message: String) {
        // 管道下 stdout 全缓冲、stderr 无缓冲,不先排空 stdout 会乱序(冒烟实测:
        // 错误详情跑到「Testing ... FAILED」前面)。
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// 设置 → 通用 → 命令行工具:把 `/usr/local/bin/simplezip` 符号链接到本 app 的主二进制。
/// 链接名是小写 `simplezip` —— main.swift 据此进 CLI 模式。只在 GUI 进程里用(依赖 Bundle.main)。
enum CommandLineToolInstaller {
    static let linkPath = "/usr/local/bin/simplezip"

    enum Status: Equatable {
        /// 链接存在且指向当前 app 的二进制。
        case installed
        /// 未安装。
        case missing
        /// 路径被占:符号链接指向别处(旧版本 app 残留 / 同名第三方工具),附实际目标。
        case foreign(String)
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? ""
    }

    /// app 是否在 Gatekeeper 转译位置运行(隔离属性未清的 DMG 直跑)——
    /// 此时装的链接指向一次性的临时挂载路径,重启就死;提示用户先把 app 挪进「应用程序」。
    static var isRunningTranslocated: Bool {
        Bundle.main.bundlePath.hasPrefix("/private/var/folders/")
    }

    static func status() -> Status {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else {
            return fileManager.fileExists(atPath: linkPath) ? .foreign(linkPath) : .missing
        }
        return destination == executablePath ? .installed : .foreign(destination)
    }

    enum InstallError: Error {
        /// 用户在系统授权弹窗里点了取消 —— 不算失败,UI 不弹手动命令。
        case cancelled
        case failed(String)
    }

    /// 安装(覆盖旧链接):先试直接写;/usr/local/bin 不可写(Apple Silicon 默认 root 属主)时
    /// 弹**系统管理员授权对话框**(`do shell script … with administrator privileges`,标准 macOS
    /// 凭据弹窗 —— 用户点名要这个)。授权被取消抛 `.cancelled`;脚本失败抛 `.failed`,
    /// UI 再给可复制的手动命令兜底。
    static func install() throws {
        let fileManager = FileManager.default
        do {
            if (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                try fileManager.removeItem(atPath: linkPath)
            }
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: executablePath)
        } catch {
            try runPrivileged("mkdir -p /usr/local/bin && ln -sf \(shellQuoted(executablePath)) \(linkPath)")
        }
    }

    /// 卸载:同样先直接删,不行再走管理员授权。
    static func uninstall() throws {
        do {
            try FileManager.default.removeItem(atPath: linkPath)
        } catch {
            try runPrivileged("rm -f \(linkPath)")
        }
    }

    /// AppleScript `with administrator privileges` = 系统标准管理员凭据弹窗(由 Security 框架托管,
    /// 密码不经过本 app)。同步阻塞主线程直到用户响应 —— 点击动作里可接受。
    private static func runPrivileged(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw InstallError.failed("cannot build privileged script")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128 = AppleScript 的「用户取消」。
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 {
                throw InstallError.cancelled
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "authorization failed"
            throw InstallError.failed(message)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var manualInstallCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \(shellQuoted(executablePath)) \(linkPath)"
    }

    static var manualUninstallCommand: String {
        "sudo rm \(linkPath)"
    }
}
