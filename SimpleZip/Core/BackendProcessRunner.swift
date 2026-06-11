//
//  BackendProcessRunner.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Darwin
import Foundation

/// 后端调用 CLI 时的统一基础设施：进程启动 + IO 抓取 + 取消 + 密码 prompt PTY。
///
/// 设计动机：在 ArchiveService 拆 backend 协议（Phase 4）的过程中，这一套 ~400 行的
/// 「跑命令拿输出」基础设施是所有后端共用的，原本散在 ArchiveService 里 private static，
/// 抽出来后将来的 `SevenZipBackend` / `RarBackend` / `DiskImageBackend` 都能直接复用，
/// 不用每个都重写 PTY / 取消 / 输出 chunk 这套东西。
///
/// 取消语义：每个进程注册时绑定一个 operationID（可空），调用方用同一个 ID 调
/// `cancelRunningCommand` 就能精确停指定操作，不会误伤别的同时在跑的子进程。
enum BackendProcessRunner {

    /// 唯一活跃进程登记表，全 BackendProcessRunner 共享（注：跨多后端共用）。
    /// 设计成 internal 让 ArchiveService.cancelRunningCommand 这种「API facade」可直接转发。
    nonisolated static let activeProcessRegistry = ActiveProcessRegistry()

    /// 「输出只为诊断、调用方不解析完整 stdout」的命令（解压 / 压缩 / 测试，带 `-bb1 -bsp1` 高频逐文件输出）
    /// 保留的输出上限（字符数）。后端逐文件吐几万行时，整串累积会让后台线程内存 + 字符串拼接失控，
    /// 进而拖慢甚至卡住 UI。失败诊断只需要尾部若干行，所以这些命令只保留最后这么多字符；
    /// **list / benchmark / 取版本号等需要解析完整输出的命令不传此值（保持无上限）**。
    nonisolated static let diagnosticsOutputRetentionLimit = 200_000

    // MARK: - 异步入口

    /// 在后台 queue 上跑一个命令，捕获 stdout/stderr 合并字符串。
    /// 主调用方：ArchiveService 的 list / extract / test 等所有动作 + 取版本号等小操作。
    static func runAndCapture(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        progressParser: ProgressOutputParser? = nil,
        inputStrategy: ProcessInputStrategy = .none,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        operationID: UUID? = nil,
        outputRetentionLimit: Int? = nil
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
                        operationID: operationID,
                        outputRetentionLimit: outputRetentionLimit
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 取消正在跑的命令。`operationID` 为 nil 时取消当前活跃的；非 nil 时按 ID 精确取消。
    static func cancelRunningCommand(operationID: UUID?) {
        activeProcessRegistry.cancelProcess(operationID: operationID)
    }

    // MARK: - 等价命令行（0.4.2 #20）

    /// 本次调用的**等价命令行**（shell 可粘贴）。安全口径：口令从不进 argv（裸 `-p` 走 PTY），
    /// 所以这里没有任何需要打码的内容；含空白 / 特殊字符的参数加单引号。
    /// 行首 `$ ` 前缀是任务详情里「复制命令」按钮的提取标记 —— 改动要两头同步。
    nonisolated static func commandLineDescription(executable: String, arguments: [String]) -> String {
        let parts = ([executable] + arguments).map(shellQuoted)
        return "$ " + parts.joined(separator: " ")
    }

    nonisolated private static func shellQuoted(_ argument: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=+:!,@%"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 同步内部实现

    private nonisolated static func runAndCaptureSync(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        inputStrategy: ProcessInputStrategy,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?,
        outputRetentionLimit: Int?
    ) throws -> String {
        // 0.4.2 #20：每次后端调用先把等价命令打进任务详情日志（口令本就不进 argv，无脱敏负担）。
        outputObserver?(commandLineDescription(executable: executable, arguments: arguments) + "\n")
        switch inputStrategy {
        case .none:
            return try runWithPipe(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                outputObserver: outputObserver,
                operationID: operationID,
                outputRetentionLimit: outputRetentionLimit,
                staticStdin: nil
            )
        case .staticInput(let text):
            // GPG menu (`--edit-key` / `--card-edit`) 等需要喂一段固定命令序列到 stdin 然后让子进程自然退出。
            // 走 runWithPipe 复用所有 IO / 取消机制，差别仅在进程启动后把字符串写进 stdin 并关闭。
            return try runWithPipe(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                outputObserver: outputObserver,
                operationID: operationID,
                outputRetentionLimit: outputRetentionLimit,
                staticStdin: text
            )
        case .passwordPrompts(let responses):
            return try runWithPseudoTerminal(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                promptResponder: InteractivePasswordResponder(responses: responses),
                outputObserver: outputObserver,
                operationID: operationID,
                outputRetentionLimit: outputRetentionLimit
            )
        }
    }

    private nonisolated static func runWithPipe(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?,
        outputRetentionLimit: Int?,
        staticStdin: String?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let ioPipe = Pipe()
        process.standardOutput = ioPipe
        process.standardError = ioPipe

        // 默认丢 /dev/null 让 stdin 不挂；有 staticStdin 时换成 Pipe 写完即关。
        let stdinPipe: Pipe?
        if staticStdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        activeProcessRegistry.register(process, operationID: operationID)
        defer { activeProcessRegistry.clear(process) }
        try process.run()
        if let stdinPipe, let staticStdin {
            // 进程启动后立刻喂 stdin 然后关掉 —— 大多数 interactive CLI 看到 EOF 就会按序处理已喂的命令。
            if let data = staticStdin.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }
        let output = try readOutput(
            from: ioPipe.fileHandleForReading,
            progressParser: progressParser,
            outputObserver: outputObserver,
            retentionLimit: outputRetentionLimit
        )
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

    private nonisolated static func runWithPseudoTerminal(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        promptResponder: InteractivePasswordResponder,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?,
        outputRetentionLimit: Int?
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

        activeProcessRegistry.register(process, operationID: operationID)
        defer { activeProcessRegistry.clear(process) }
        try process.run()
        try? slaveHandle.close()
        let output: String
        do {
            output = try readOutput(
                from: masterHandle,
                progressParser: progressParser,
                outputObserver: outputObserver,
                retentionLimit: outputRetentionLimit
            ) { text in
                try responder.consume(text, writer: masterHandle)
            }
        } catch {
            terminateAndWait(process)
            throw error
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

    private nonisolated static func readOutput(
        from handle: FileHandle,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)? = nil,
        retentionLimit: Int? = nil,
        chunkHandler: ((String) throws -> Void)? = nil
    ) throws -> String {
        var output = ""
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            let text = String(decoding: data, as: UTF8.self)
            // progressParser / outputObserver / chunkHandler 永远拿到**完整**这一块（进度、活动中心日志、
            // 密码 prompt 都靠它们逐块处理，不受保留上限影响）。
            progressParser?.consume(text)
            outputObserver?(text)
            try chunkHandler?(text)
            // 累积的返回值是给「失败时报错 / list 解析」用的。设了上限的命令（解压 / 压缩 / 测试）只留尾部，
            // 避免几万行逐文件输出把整串拼到几十 MB、拖慢后台线程乃至 UI。带 2× 滞回，避免每块都做 suffix。
            output += text
            if let retentionLimit, output.count > retentionLimit * 2 {
                output = String(output.suffix(retentionLimit))
            }
        }
        if let retentionLimit, output.count > retentionLimit {
            output = String(output.suffix(retentionLimit))
        }
        return output
    }
}

// MARK: - 共享辅助类型

/// 子进程 stdin 投喂策略：
/// - `.none`：stdin 接 /dev/null。
/// - `.staticInput`：进程启动后立刻把字符串写进 stdin 然后关流（gpg `--edit-key` / `--card-edit` 这种 interactive menu）。
/// - `.passwordPrompts`：跑 PTY，从 stdout 截获「请输入密码」提示再按 prompt 顺序灌密码。
enum ProcessInputStrategy {
    case none
    case staticInput(String)
    case passwordPrompts([String])
}

/// 把后端命令输出（unzip / 7zz / rar）解析成进度状态。
/// 设计成 final class @unchecked Sendable 是因为 runWithPipe / PTY 跑在后台线程，
/// 内部用 NSLock 保护可变状态，外部当不可变值传递。
final class ProgressOutputParser: @unchecked Sendable {
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
        progress(ArchiveProgressState(fraction: 1, currentFile: nil, completedUnitCount: totalFiles, totalUnitCount: totalFiles))
    }

    private nonisolated func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let percent = parsePercent(from: trimmed) {
            progress(ArchiveProgressState(fraction: percent, currentFile: currentFile(from: trimmed), completedUnitCount: processedFiles, totalUnitCount: totalFiles))
            return
        }

        guard let file = currentFile(from: trimmed), !file.isEmpty else { return }
        processedFiles += 1
        let fraction = totalFiles.map { min(0.99, Double(processedFiles) / Double(max(1, $0))) }
        progress(ArchiveProgressState(fraction: fraction, currentFile: file, completedUnitCount: processedFiles, totalUnitCount: totalFiles))
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

/// 在 PTY 下截获 7zz / rar 等工具的「请输入密码」提示并自动回填配置好的密码序列。
struct InteractivePasswordResponder {
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

/// 活跃子进程登记表，配合 operationID 做精确取消。
/// 注意状态访问全部走内部 NSLock，调用方不需要再加锁。
final class ActiveProcessRegistry: @unchecked Sendable {
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
