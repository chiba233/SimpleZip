//
//  ArchiveService+Arguments.swift
//  SimpleZip
//
//  Created by Copilot on 2026/05/28.
//

import Darwin
import Foundation

extension ArchiveService {
    static func unzipOverwriteArgument(for behavior: OverwriteBehavior) -> String {
        switch behavior {
        case .skipExisting:
            return "-n"
        case .ask, .overwrite, .replaceIfDifferent:
            return "-o"
        }
    }

    static func sevenZipOverwriteArgument(for behavior: OverwriteBehavior) -> String {
        switch behavior {
        case .skipExisting:
            return "-aos"
        case .ask, .overwrite, .replaceIfDifferent:
            return "-aoa"
        }
    }

    /// 7zz 多线程参数：用户指定线程数就用它，否则 `-mmt=on`（按可用核心自动并行）。
    /// 单文件 xz / bzip2 压缩、测试等默认偏单线程的操作显式带上它才能跑满 CPU。
    static func sevenZipMultithreadArgument(threadCount: Int) -> String {
        threadCount > 0 ? "-mmt=\(threadCount)" : "-mmt=on"
    }

    static func sevenZipExtractArguments(
        command: String,
        archive: URL,
        entries: [String],
        destination: URL,
        overwriteBehavior: OverwriteBehavior,
        password _: String
    ) -> [String] {
        // 安全（审计 P1，switch 注入）：归档条目名是**不可信输入**。恶意包可以把条目命名成
        // `-snl` / `-o/tmp/elsewhere` 等 7zz 开关样子,直接拼进 argv 会被当开关解释（重定向解压 / 改安全行为）。
        // 所有开关放 `--` 之前、所有位置参数（条目名）放 `--` 之后,7zz 从此把后面的一律当文件名。
        // `-o<dest>` 等开关必须在 `--` 前。已实测 bundled 7zz 支持 `--`。
        var arguments = [command, archive.path]
        // `-mmt=on`：让 7zz 按可用核心数多线程解压（ZIP 等「每文件独立」的格式能并行多个文件）。
        // 默认解压偏单线程、大量文件时跑不满 CPU；对不支持并行的格式 7zz 自行忽略，无副作用。
        arguments.append(contentsOf: ["-o\(destination.path)", sevenZipOverwriteArgument(for: overwriteBehavior), "-mmt=on", "-bb1", "-bsp1", "-y"])
        arguments.append("--")
        arguments.append(contentsOf: entries)
        return arguments
    }

    static func sevenZipExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-xr!\($0)" }
    }

    static func tarExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "--exclude=\($0)" }
    }

    static func sevenZipCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        let command = sevenZipCommand(for: options.updateMode)
        var arguments = [command, "-t7z", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
        arguments.append(contentsOf: sevenZipUpdateArguments(for: options.updateMode))
        if !options.password.isEmpty {
            arguments.append("-p")
            arguments.append(options.sevenZipEncryptFileNames ? "-mhe=on" : "-mhe=off")
        }
        arguments.append("-md=\(options.sevenZipDictionarySizeMB)m")
        arguments.append("-mfb=\(options.sevenZipWordSize)")
        if options.sevenZipSolidArchive {
            if let blockSize = options.sevenZipSolidBlockSize.argumentValue {
                arguments.append("-ms=\(blockSize)")
            } else {
                arguments.append("-ms=on")
            }
        } else {
            arguments.append("-ms=off")
        }
        if let method = options.sevenZipMethod.argumentValue {
            arguments.append("-m0=\(method)")
        }
        if options.sevenZipThreadCount > 0 {
            arguments.append("-mmt=\(options.sevenZipThreadCount)")
        }
        if options.sevenZipPathMode == .full {
            arguments.append("-spf")
        }
        if options.sevenZipStoreSymbolicLinks {
            arguments.append("-snl")
        }
        if options.sevenZipStoreHardLinks {
            arguments.append("-snh")
        }
        if options.sevenZipCompressSharedFiles {
            arguments.append("-ssw")
        }
        if options.sevenZipDeleteSourceFiles {
            arguments.append("-sdel")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        // 安全（审计 P1）：destination / 源文件名前加 `--` —— 文件名以 `-` 开头时不被 7zz 当开关。
        arguments.append("--")
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func sevenZipZipCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        let command = sevenZipCommand(for: options.updateMode)
        var arguments = [command, "-tzip", "-mx=\(options.compressionLevel.rawValue)", "-bb1", "-bsp1", "-y"]
        arguments.append(contentsOf: sevenZipUpdateArguments(for: options.updateMode))
        if !options.password.isEmpty {
            arguments.append("-p")
            arguments.append("-mem=\(options.encryptionMethod.zipArgumentValue)")
        }
        if options.sevenZipThreadCount > 0 {
            arguments.append("-mmt=\(options.sevenZipThreadCount)")
        }
        if options.sevenZipPathMode == .full {
            arguments.append("-spf")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        arguments.append(contentsOf: sevenZipExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        // 安全（审计 P1）：destination / 源文件名前加 `--` —— 文件名以 `-` 开头时不被 7zz 当开关。
        arguments.append("--")
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func rarCreateArguments(destination: URL, relativeNames: [String], options: ArchiveCreationOptions) throws -> [String] {
        var arguments = [rarCommand(for: options.updateMode), "-ma5", "-m\(rarCompressionLevel(for: options.compressionLevel))", "-r"]
        if options.sevenZipPathMode == .relative {
            arguments.append("-ep1")
        }
        if options.sevenZipDeleteSourceFiles {
            arguments.append("-df")
        }
        if let volumeSize = try normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) {
            arguments.append("-v\(volumeSize)")
        }
        if !options.password.isEmpty {
            arguments.append(options.sevenZipEncryptFileNames ? "-hp" : "-p")
        }
        arguments.append(contentsOf: rarExcludeArguments(from: options))
        arguments.append(contentsOf: splitCommandLineArguments(from: options.rawParameters))
        arguments.append(destination.path)
        arguments.append(contentsOf: relativeNames)
        return arguments
    }

    static func normalizedSevenZipVolumeSize(from text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: #"(?i)^\d+[bkmg]?$"#, options: .regularExpression) != nil else {
            throw ArchiveError.invalidSevenZipVolumeSize
        }
        return trimmed.lowercased()
    }

    nonisolated static func customExcludePatterns(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func excludedFileCount(in sourceURLs: [URL], options: ArchiveCreationOptions) -> Int {
        let patterns = zipExcludePatterns(from: options)
        guard !patterns.isEmpty, let parentURL = sourceURLs.first?.deletingLastPathComponent() else {
            return 0
        }
        return regularFileURLs(in: sourceURLs).filter { url in
            let relativePath = relativePathForExcludePreview(url, parent: parentURL)
            return patterns.contains { pattern in
                matchesExcludePattern(pattern, relativePath: relativePath, fileName: url.lastPathComponent)
            }
        }.count
    }

    /// 0.4.2 #18：被排除文件的**相对路径列表**（预览用，升序）。匹配逻辑与 `excludedFileCount` 完全同源。
    nonisolated static func excludedFilePreview(in sourceURLs: [URL], options: ArchiveCreationOptions) -> [String] {
        let patterns = zipExcludePatterns(from: options)
        guard !patterns.isEmpty, let parentURL = sourceURLs.first?.deletingLastPathComponent() else {
            return []
        }
        return regularFileURLs(in: sourceURLs).compactMap { url -> String? in
            let relativePath = relativePathForExcludePreview(url, parent: parentURL)
            let matched = patterns.contains { pattern in
                matchesExcludePattern(pattern, relativePath: relativePath, fileName: url.lastPathComponent)
            }
            return matched ? relativePath : nil
        }.sorted()
    }

    /// 0.4.2 #19：压缩前 dry run —— **输入侧**统计。刻意不估压缩后大小（不准没意义）。
    struct ArchiveCreationDryRun: Equatable {
        /// 将被打包的常规文件数（已扣掉被排除的）。
        let inputFileCount: Int
        /// 将被打包文件的原始字节总和。
        let totalBytes: Int64
        let excludedCount: Int
        let symlinkCount: Int
        /// 包目录（.app 等 bundle）数 —— 解出来不是普通文件夹，提示用。
        let packageCount: Int
        /// 设了分卷大小时，按**未压缩**输入估算的分卷数上限（压缩后通常更少）。
        let estimatedVolumeCount: Int?
    }

    nonisolated static func dryRunSummary(sourceURLs: [URL], options: ArchiveCreationOptions) -> ArchiveCreationDryRun {
        let patterns = options.format.supportsExcludeRules ? zipExcludePatterns(from: options) : []
        let parentURL = sourceURLs.first?.deletingLastPathComponent()
        var fileCount = 0
        var bytes: Int64 = 0
        var excluded = 0
        var symlinks = 0
        var packages = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]

        func process(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: keys) else { return }
            if values.isSymbolicLink == true {
                symlinks += 1
                return
            }
            guard values.isRegularFile == true else { return }
            if !patterns.isEmpty, let parentURL {
                let relativePath = relativePathForExcludePreview(url, parent: parentURL)
                if patterns.contains(where: { matchesExcludePattern($0, relativePath: relativePath, fileName: url.lastPathComponent) }) {
                    excluded += 1
                    return
                }
            }
            fileCount += 1
            bytes += Int64(values.fileSize ?? 0)
        }

        for source in sourceURLs {
            let values = try? source.resourceValues(forKeys: keys)
            if values?.isPackage == true { packages += 1 }
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys)) {
                    for case let child as URL in enumerator {
                        if (try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { packages += 1 }
                        process(child)
                    }
                }
            } else {
                process(source)
            }
        }

        var estimatedVolumes: Int?
        if options.format.supportsVolumeSplitting,
           !options.sevenZipVolumeSize.trimmingCharacters(in: .whitespaces).isEmpty,
           let volumeBytes = ArchiveSearchQuery.parseByteCount(options.sevenZipVolumeSize.trimmingCharacters(in: .whitespaces)),
           volumeBytes > 0, bytes > 0 {
            estimatedVolumes = Int((bytes + volumeBytes - 1) / volumeBytes)
        }

        return ArchiveCreationDryRun(
            inputFileCount: fileCount,
            totalBytes: bytes,
            excludedCount: excluded,
            symlinkCount: symlinks,
            packageCount: packages,
            estimatedVolumeCount: estimatedVolumes
        )
    }

    nonisolated static func regularFileURLs(in urls: [URL]) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        return urls.flatMap { url -> [URL] in
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return [url] }
            if values.isRegularFile == true {
                return [url]
            }
            guard values.isDirectory == true,
                  let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys)
                  )
            else {
                return []
            }
            var files: [URL] = []
            for case let fileURL as URL in enumerator {
                if (try? fileURL.resourceValues(forKeys: resourceKeys).isRegularFile) == true {
                    files.append(fileURL)
                }
            }
            return files
        }
    }

    static func splitCommandLineArguments(from text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quoteCharacter: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if quoteCharacter != nil && character == "\\" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quoteCharacter == character {
                    quoteCharacter = nil
                } else if quoteCharacter == nil {
                    quoteCharacter = character
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace && quoteCharacter == nil {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }

    static func nativeZipFallbackSupported(for options: ArchiveCreationOptions) -> Bool {
        options.updateMode == .addAndReplace &&
        options.rawParameters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        options.sevenZipPathMode == .relative &&
        (try? normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize)) == nil &&
        (options.password.isEmpty || options.encryptionMethod == .zipCrypto)
    }

    static func passwordResponses(for options: ArchiveCreationOptions) -> [String] {
        let confirmation = options.passwordConfirmation.isEmpty ? options.password : options.passwordConfirmation
        return [options.password, confirmation]
    }

    static func sevenZipCommand(for updateMode: ArchiveUpdateMode) -> String {
        switch updateMode {
        case .addAndReplace:
            return "a"
        case .updateAndAdd, .freshen, .synchronize:
            return "u"
        }
    }

    static func sevenZipUpdateArguments(for updateMode: ArchiveUpdateMode) -> [String] {
        switch updateMode {
        case .addAndReplace, .updateAndAdd:
            return []
        case .freshen:
            return ["-up1q1r0x1y2z1w2"]
        case .synchronize:
            return ["-up1q0r2x1y2z1w2"]
        }
    }

    static func rarCommand(for updateMode: ArchiveUpdateMode) -> String {
        switch updateMode {
        case .addAndReplace:
            return "a"
        case .updateAndAdd:
            return "u"
        case .freshen:
            return "f"
        case .synchronize:
            return "s"
        }
    }

    static func rarCompressionLevel(for level: CompressionLevel) -> Int {
        switch level {
        case .store:
            return 0
        case .fast:
            return 1
        case .normal:
            return 3
        case .maximum:
            return 5
        }
    }

    static func rarExcludeArguments(from options: ArchiveCreationOptions) -> [String] {
        zipExcludePatterns(from: options).map { "-x\($0)" }
    }

    private nonisolated static func relativePathForExcludePreview(_ url: URL, parent: URL) -> String {
        let parentPath = parent.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard filePath.hasPrefix(prefix) else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private nonisolated static func matchesExcludePattern(_ pattern: String, relativePath: String, fileName: String) -> Bool {
        if fnmatch(pattern, relativePath, 0) == 0 || fnmatch(pattern, fileName, 0) == 0 { return true }
        // 0.4.2 对齐后端真实语义：创建走 7zz `-xr!`（**递归**按名排除）——模式命中**任一路径段**
        // 即整支被排除（裸目录名如 `node_modules` 在后端是生效的，预览不该漏数它下面的文件）。
        return relativePath.split(separator: "/").contains { fnmatch(pattern, String($0), 0) == 0 }
    }
}
