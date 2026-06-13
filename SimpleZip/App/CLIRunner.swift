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
    /// 同步阻塞主线程等它必死锁(首版冒烟实测)。main.swift 用 Task + dispatchMain() 驱动。
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
        case .version, .doctor, .open, .check, .compare, .create, .verify:
            break
        }

        guard let environment = resolveEnvironment() else {
            printError("simplezip: cannot locate the SimpleZip.app bundle this command belongs to.")
            printError("Reinstall the command from SimpleZip → Settings → General → Command-Line Tool.")
            return 2
        }

        switch invocation {
        case .help, .helpCommand:
            return 0
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
        process.arguments = ["-a", environment.appBundleURL.path] + urls.map(\.path)
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
        do {
            try await ArchiveService.test(url, outputObserver: observer)
            return
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error) else { throw error }
            var lastError = error
            for _ in 0..<3 {
                guard let password = promptPassword(for: url.lastPathComponent) else {
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
            let leftItems = try await ArchiveService.list(leftURL)
            let rightItems = try await ArchiveService.list(rightURL)
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
        // CLI 进程的 .standard 指向错误的域(无 bundle ID)—— 显式打开 app 的偏好域。
        UserDefaults(suiteName: environment.appBundleID) ?? .standard
    }

    /// 线程安全的输出收集器 —— outputObserver 从后台回调,主线程收尾时读。
    private nonisolated final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
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
