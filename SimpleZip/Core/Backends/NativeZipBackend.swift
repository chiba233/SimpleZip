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

    /// zip 条目列表优先走 7zz `l -slt` —— 只有它给得出加密标记（`Encrypted = +`）和
    /// **原始字节**的条目名。系统工具会丢这两样安全关键信息（0.4.3 自检样本抓出的真实漏报）：
    /// - `unzip -l` / `tar -tf` 的输出里没有加密标记 → AES 加密包被列成「未加密」；
    /// - 系统 tar 把文件名统一归一化成 NFD → NFC/NFD 混用包在安全报告里漏报 normalizationCollision。
    /// `unzip -l` + `tar -tf` 合并解析（`ArchiveService.parseZipList`，fixture 已覆盖）保留为
    /// 7zz 不可用时的兜底。
    nonisolated static func list(_ archive: URL, password: String = "", operationID: UUID? = nil) async throws -> [ArchiveItem] {
        if SevenZipBackend.isAvailable() {
            return try await SevenZipBackend.list(archive, password: password, operationID: operationID)
        }
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
    ///
    /// 加密 zip 例外:unzip 对 AES 条目只会「skipping … need PK compat. v5.1」、对 ZipCrypto 等
    /// stdin 口令 —— 两种输出都不含「需要口令」的诊断词,`errorSuggestsPasswordRequirement`
    /// 永远不命中,GUI / CLI 都不会弹口令重试(CLI check 实测漏)。检出加密(含 mixed)且 7zz
    /// 可用时整体交给 7zz t:它报 "Cannot open encrypted archive…",统一密码中心的判定词接得上。
    nonisolated static func test(_ archive: URL, operationID: UUID? = nil, outputObserver: (@Sendable (String) -> Void)? = nil) async throws {
        switch ArchiveService.detectZipEncryption(in: archive) {
        case .zipCrypto, .aes128, .aes192, .aes256, .mixed:
            if SevenZipBackend.isAvailable() {
                try await SevenZipBackend.test(archive, operationID: operationID, outputObserver: outputObserver)
                return
            }
        case .none, .unknown:
            break
        }
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/unzip",
            arguments: ["-t", archive.path],
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    // MARK: - extract

    /// #19 跟进(用户拍板):纯 `.tar` **整包**解压走系统 bsdtar —— 7zz 解 tar 会丢 macOS
    /// 扩展属性(xattr 自检样本实测红),系统 tar 原生往返 PAX 头里的 xattr(创建侧本就走系统 tar)。
    /// bsdtar 默认拒绝绝对路径与 `..` 成员(不加 -P),外层再叠 validateExtractedTree。
    /// 选条目 / flatten 仍走 7zz(7zz 列出的条目名与 tar 存储名不保证逐字节一致,不冒险)。
    nonisolated static func extractWholeTar(
        _ archive: URL,
        to destination: URL,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-xvf", archive.path, "-C", destination.path],
            progressParser: progressParser,
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )
    }

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
    nonisolated static func extract(
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
    private nonisolated static func extractWithSystemUnzip(
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
                operationID: operationID,
                // 解压:调用方丢弃返回串、只用进度 + 活动中心日志。海量碎文件时 unzip 会把每个条目名喷进 stdout,
                // 不设上限会把整串累积进返回 String → 内存暴涨。只保留尾部供失败诊断(对齐 7zz 路径)。
                outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
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
                operationID: operationID,
                outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
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
                operationID: operationID,
                outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
            )
        }
    }

    /// 根据「用户选的解密方式」+「实际检出的加密类型」决定 backend 顺序。
    /// 这条策略表本来在 ArchiveService 里，搬来后是 NativeZipBackend 的内部决策。
    private nonisolated static func zipExtractionTools(
        for method: ArchiveDecryptionMethod,
        detectedEncryption: ZipEncryptionDetection,
        password: String
    ) -> [ZipExtractionTool] {
        switch method {
        case .automatic:
            guard !password.isEmpty else {
                // 大归档稳定性:海量碎文件下 7zz 解压比系统 unzip 更稳(进度 / 输出量可控、不被逐条目 stdout 拖死),
                // 故无密码自动档优先 7zz,系统 unzip 退为兜底(7zz 缺失 / 失败时仍可用,tar/xattr 特例路径不受影响)。
                return [.sevenZip, .macOS]
            }
            switch detectedEncryption {
            case .aes128, .aes192, .aes256:
                return [.sevenZip]
            case .zipCrypto:
                return [.macOS, .sevenZip]
            case .none:
                return [.sevenZip, .macOS]
            case .mixed, .unknown:
                return [.sevenZip, .macOS]
            }
        case .aes128, .aes192, .aes256:
            return [.sevenZip]
        case .zipCrypto:
            return [.macOS, .sevenZip]
        }
    }

    private nonisolated static func zipExtractionToolName(_ tool: ZipExtractionTool) -> String {
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
