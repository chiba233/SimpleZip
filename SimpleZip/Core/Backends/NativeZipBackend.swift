//
//  NativeZipBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// 系统自带「ZIP 家族」后端 —— `/usr/bin/unzip` / `/usr/bin/zip` / `/usr/bin/tar`。
///
/// 设计动机：
/// - macOS 自带的 unzip/tar 速度快、零依赖；对常规 ZIP（无加密 / ZipCrypto）足够好。
/// - 对 AES-* 加密的 ZIP，系统 unzip 不支持；这种场景下后端会内部委托给 `SevenZipBackend`。
/// - tar / tar.gz 创建完全是系统 tar 的事，不掺 7zz。
/// - 系统 zip 仅作为 7zz 缺失时的最简兜底（功能集不全）。
///
/// 跨后端编排：`extract(...)` 是 zip 文件的统一入口 —— 根据用户在「解压方式」偏好里的选择和
/// 头部检测出来的加密方式，按一个 ordered list 依次尝试 macOS / 7zz；前一个失败下一个接着上。
/// 这条编排逻辑跟在 `ArchiveService` 里时一样，只是搬到 backend 层让 ArchiveService 完全不知道
/// 「具体跑哪个工具」。
enum NativeZipBackend {

    // MARK: - 元信息

    /// `/usr/bin/unzip` 在所有 macOS 默认存在；这里仅做防御性可达性判断。
    nonisolated static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip")
    }

    // MARK: - list

    /// `unzip -l` 给可读条目列表，`tar -tf` 给完整路径（unzip 输出会被截断的）；二者合并解析。
    /// 解析交给 `ArchiveService.parseZipList` —— 那一段已经被 fixture 测试覆盖。
    static func list(_ archive: URL, operationID: UUID? = nil) async throws -> [ArchiveItem] {
        let unzipOutput = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/unzip",
            arguments: ["-l", archive.path],
            operationID: operationID
        )
        let tarOutput = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-tf", archive.path],
            operationID: operationID
        )
        return ArchiveService.parseZipList(tarOutput: tarOutput, unzipOutput: unzipOutput)
    }

    // MARK: - test

    /// `unzip -t` —— 退出码非零会被 BackendProcessRunner 转成抛错。
    static func test(_ archive: URL, operationID: UUID? = nil) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/unzip",
            arguments: ["-t", archive.path],
            operationID: operationID
        )
    }

    // MARK: - extract

    /// ZIP 文件的统一解压入口。
    ///
    /// 根据「解压方式」偏好 + 头部加密检测决定 backend 顺序，依次尝试：
    /// `automatic` + 无密码 → 先 macOS、失败 7zz 兜底；
    /// `automatic` + 检出 AES → 直接 7zz（macOS unzip 不支持 AES）；
    /// `automatic` + 检出 ZipCrypto → 先 macOS、失败 7zz；
    /// `aes128/192/256` → 仅 7zz；
    /// `zipCrypto` → 先 macOS 后 7zz。
    /// 前一个失败 → 用 outputObserver 提示「换一个 backend 重试」，再跑下一个。
    /// 全部失败 → 抛第一个错。
    static func extract(
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
        let detectedEncryption = ArchiveService.detectZipEncryption(in: archive)
        let tools = zipExtractionTools(
            for: zipDecryptionMethod,
            detectedEncryption: detectedEncryption,
            password: password
        )

        for (index, tool) in tools.enumerated() {
            do {
                switch tool {
                case .sevenZip:
                    try await SevenZipBackend.extract(
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
                    try await extractWithSystemUnzip(
                        archive,
                        entries: entries,
                        to: destination,
                        overwriteBehavior: overwriteBehavior,
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

    // MARK: - create

    /// `/usr/bin/tar -cvf` 打 .tar。
    static func createTar(
        destination: URL,
        relativeNames: [String],
        excludeArguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-cvf", destination.path] + excludeArguments + relativeNames,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// `/usr/bin/tar -czvf` 打 .tar.gz。
    static func createTarGzip(
        destination: URL,
        relativeNames: [String],
        excludeArguments: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-czvf", destination.path] + excludeArguments + relativeNames,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    /// `/usr/bin/zip` 兜底创建 .zip —— 仅在 7zz 不可用且选项可被原生 zip 覆盖时调用。
    /// 调用方应先用 `ArchiveService.nativeZipFallbackSupported(for:)` 判断选项兼容性。
    static func createZipFallback(
        destination: URL,
        relativeNames: [String],
        options: ArchiveCreationOptions,
        excludePatterns: [String],
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        var arguments = ["-r", "-\(options.compressionLevel.rawValue)"]
        if !options.password.isEmpty {
            arguments.append("-e")
        }
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        if !excludePatterns.isEmpty {
            arguments.append("-x")
            arguments.append(contentsOf: excludePatterns)
        }
        let inputStrategy: ProcessInputStrategy = options.password.isEmpty
            ? .none
            : .passwordPrompts([options.password, options.password])
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/zip",
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    // MARK: - 私有实现

    /// 跟 macOS 自带 unzip/tar 打交道的具体动作 —— 整包 / 选择性 / 带密码三条路径。
    /// 无密码 + 选条目时优先 tar（更快、原始路径稳）；有密码必须用 unzip（tar 不支持加密 ZIP）。
    private static func extractWithSystemUnzip(
        _ archive: URL,
        entries: [String],
        to destination: URL,
        overwriteBehavior: OverwriteBehavior,
        password: String,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        if entries.isEmpty {
            let arguments = [ArchiveService.unzipOverwriteArgument(for: overwriteBehavior), archive.path, "-d", destination.path]
            let inputStrategy: ProcessInputStrategy = password.isEmpty ? .none : .passwordPrompts([password])
            _ = try await BackendProcessRunner.runAndCapture(
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
            _ = try await BackendProcessRunner.runAndCapture(
                "/usr/bin/tar",
                arguments: arguments,
                progressParser: progressParser,
                outputObserver: outputObserver,
                operationID: operationID
            )
        } else {
            var arguments = [ArchiveService.unzipOverwriteArgument(for: overwriteBehavior), archive.path]
            arguments.append(contentsOf: entries)
            arguments.append(contentsOf: ["-d", destination.path])
            _ = try await BackendProcessRunner.runAndCapture(
                "/usr/bin/unzip",
                arguments: arguments,
                progressParser: progressParser,
                inputStrategy: .passwordPrompts([password]),
                outputObserver: outputObserver,
                operationID: operationID
            )
        }
    }

    /// 根据「用户选的解密方式」+「实际检出的加密类型」决定 backend 顺序。
    /// 这条策略表本来在 ArchiveService 里，搬来后是 NativeZipBackend 的内部决策。
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

    private static func zipExtractionToolName(_ tool: ZipExtractionTool) -> String {
        switch tool {
        case .sevenZip:
            return "7-Zip"
        case .macOS:
            return "macOS"
        }
    }

    private enum ZipExtractionTool {
        case sevenZip
        case macOS
    }
}
