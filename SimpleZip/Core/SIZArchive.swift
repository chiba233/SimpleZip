//
//  SIZArchive.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// SimpleZip 自己的「带签名容器」格式。
///
/// 设计动机：业界标准做法是给压缩包生成同目录 `<archive>.asc` 兄弟文件（detached signature）——
/// 但用户在文件管理 / 邮件传输 / 网盘上传时极容易把 `.asc` 漏掉，签名跟压缩包脱钩就失去意义。
/// `.siz` 把内层压缩包 + 元信息 + 签名打成一个 tar 容器（不再压缩，内层 archive 已经是压缩态），
/// 单文件传输天然把三样东西绑在一起，运输路径上不会丢。
///
/// 容器布局（tar 里平铺三个文件，无子目录）：
/// ```
/// archive.<ext>      ← 内层压缩包原样（ext = zip / 7z / rar / tar.gz / …）
/// metadata.json     ← 本 namespace 的 schema 元信息
/// signature.asc     ← `gpg --detach-sign --armor` 输出，对 archive.<ext> 字节签名
/// ```
///
/// 注意：本 namespace 不碰 gpg —— 签名生成 / 验签都交给 `GPGBackend`。这里只负责 tar 打包 / 拆包
/// 和 metadata.json 的序列化。
enum SIZArchive {
    /// 文件名约定：内层 archive 固定叫 `archive.<ext>`，让 unwrap 一眼就识别。
    static let extensionName = "siz"
    static let metadataFileName = "metadata.json"
    static let signatureFileName = "signature.asc"

    /// schema 标记 —— 跟偏好导入用的 `SimpleZip.preferences` 一个套路，
    /// 让以后增加字段 / 改格式时能用 `version` 升级而不破坏老文件兼容。
    static let schemaIdentifier = "SimpleZip.siz"
    static let schemaVersion = 1

    /// `metadata.json` 反序列化产物 —— 描述内层压缩包 + 签名者。
    struct Metadata: Codable, Equatable {
        var schema: String
        var version: Int
        /// tar 内层 archive 的文件名（含扩展名）—— unwrap 时直接读这一项找它。
        var innerArchiveName: String
        /// 内层压缩格式（"zip" / "7z" / "rar" / "tar.gz" / …），UI 展示用。
        var innerFormat: String
        /// 用户最初想给压缩包起的名字（含扩展名），比如 "MyProject.zip" ——
        /// unwrap 后想还原原始命名时用得上。
        var originalArchiveName: String
        /// ISO-8601 创建时间，给 UI 显示「于 X 时签名」用。
        var createdAt: String
        /// 创建端版本，"SimpleZip 0.1.7" 之类，调试 / 兼容性追溯用。
        var createdBy: String
        var signature: SignatureInfo
    }

    /// 签名者元信息 —— 从 `gpg --list-keys` 拷过来的展示字段。
    /// 注意：fingerprint / userID 在 metadata 里是「**主张**」，并非真凭实据，
    /// 真正的可信度由 `signature.asc` + GPG 验签决定。这俩字段仅用于「不打开 gpg 也能展示签名者文案」。
    struct SignatureInfo: Codable, Equatable {
        var signerFingerprint: String
        var signerUserID: String
        /// 签名是 ASCII armor 还是二进制 —— 当前固定 true（detached armor），留字段方便后续扩展。
        var armorFormat: Bool
    }

    // MARK: - 创建

    /// 把已经造好的内层 archive + signature 打包成 `.siz`。
    ///
    /// 步骤：
    /// 1. 起 staging 临时目录
    /// 2. 把 inner archive 复制 / 重命名为 `archive.<ext>`
    /// 3. 把 signature 复制为 `signature.asc`
    /// 4. 写 `metadata.json`（JSON 排序输出方便 diff）
    /// 5. `tar -cf <output>.siz -C staging .` 平铺打包
    /// 6. 删 staging
    ///
    /// 注意：tar 不再额外压缩 —— 内层 archive 已经是压缩态，再压一遍空间无收益还慢。
    static func wrap(
        innerArchive: URL,
        signatureFile: URL,
        metadata: Metadata,
        outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        let innerName = try validatedInnerArchiveName(metadata.innerArchiveName)
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ArchiveError.exportDestinationExists
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-SIZ-Wrap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // 1) 内层 archive → archive.<ext>
        let stagedInner = staging.appendingPathComponent(innerName)
        try fileManager.copyItem(at: innerArchive, to: stagedInner)

        // 2) signature.asc
        let stagedSignature = staging.appendingPathComponent(signatureFileName)
        try fileManager.copyItem(at: signatureFile, to: stagedSignature)

        // 3) metadata.json —— sortedKeys 让二进制 diff 友好，prettyPrinted 让用户用文本编辑器打开能读
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: staging.appendingPathComponent(metadataFileName), options: .atomic)

        // 4) tar 平铺：显式列出三个文件名，避免生成 `./` 前缀目录项。
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-cf", outputURL.path, "-C", staging.path, innerName, metadataFileName, signatureFileName]
        )
    }

    // MARK: - 拆包

    /// 把 `.siz` 拆开到指定目录，返回内层 archive URL + signature URL + 解析过的 metadata。
    /// 调用方应自己清理 destination（unwrap 用 caller 提供的目录，不自己起临时目录）。
    static func unwrap(at sizURL: URL, to destination: URL) async throws -> UnwrapResult {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let entries = try await validatedContainerEntries(at: sizURL)
        let metadataEntry = try requiredEntry(metadataFileName, in: entries)
        try await extract(entries: [metadataEntry], from: sizURL, to: destination)

        let metadataURL = destination.appendingPathComponent(metadataFileName)
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(Metadata.self, from: metadataData)
        guard metadata.schema == schemaIdentifier else {
            throw SIZError.unexpectedSchema(metadata.schema)
        }
        let innerName = try validatedInnerArchiveName(metadata.innerArchiveName)
        let signatureEntry = try requiredEntry(signatureFileName, in: entries)
        let innerEntry = try requiredEntry(innerName, in: entries)
        try validateExpectedContainerComponents(innerArchiveName: innerName, entries: entries)
        try await extract(entries: [signatureEntry, innerEntry], from: sizURL, to: destination)

        let signatureURL = destination.appendingPathComponent(signatureFileName)
        let innerURL = destination.appendingPathComponent(innerName)
        guard fileManager.fileExists(atPath: signatureURL.path) else {
            throw SIZError.missingContainerComponents
        }
        guard fileManager.fileExists(atPath: innerURL.path) else {
            throw SIZError.missingInnerArchive(innerName)
        }
        return UnwrapResult(innerArchiveURL: innerURL, signatureURL: signatureURL, metadata: metadata)
    }

    /// 仅检查容器结构是否合法 + 读 metadata，不真正解开内层 archive。
    /// 给「打开压缩包之前快速看签名信息」用 —— 比完整 unwrap 轻量。
    static func peekMetadata(at sizURL: URL) async throws -> Metadata {
        let entries = try await validatedContainerEntries(at: sizURL)
        let metadataEntry = try requiredEntry(metadataFileName, in: entries)
        // tar -O 把指定文件内容打到 stdout，不解到磁盘。
        let metadataJson = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-xOf", sizURL.path, metadataEntry.rawName]
        )
        guard let data = metadataJson.data(using: .utf8) else {
            throw SIZError.missingContainerComponents
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.schema == schemaIdentifier else {
            throw SIZError.unexpectedSchema(metadata.schema)
        }
        let innerName = try validatedInnerArchiveName(metadata.innerArchiveName)
        _ = try requiredEntry(signatureFileName, in: entries)
        _ = try requiredEntry(innerName, in: entries)
        try validateExpectedContainerComponents(innerArchiveName: innerName, entries: entries)
        return metadata
    }

    /// `.siz` 是单文件签名容器。分卷继续使用公开 GPG detached signature 外置 `.asc`，不在容器内半支持。
    static func validateCreationOptionsForSignedContainer(_ options: ArchiveCreationOptions) throws {
        if options.sevenZipDeleteSourceFiles {
            throw ArchiveError.sizContainerUnsupportedOptions(L10n.text("error.siz.unsupportedOptions.deleteSource"))
        }
        if try ArchiveService.normalizedSevenZipVolumeSize(from: options.sevenZipVolumeSize) != nil {
            throw ArchiveError.sizContainerUnsupportedOptions(L10n.text("error.siz.unsupportedOptions.splitVolume"))
        }
    }

    /// `wrap` 返回值的「拆包」对偶 —— 内层 archive / signature 在 destination 下的实际位置 + 元信息。
    struct UnwrapResult {
        let innerArchiveURL: URL
        let signatureURL: URL
        let metadata: Metadata
    }

    enum SIZError: LocalizedError {
        case missingContainerComponents
        case unexpectedSchema(String)
        case missingInnerArchive(String)
        case invalidContainerEntry(String)
        case unexpectedContainerComponents(String)

        var errorDescription: String? {
            switch self {
            case .missingContainerComponents:
                return L10n.text("error.siz.missingComponents")
            case .unexpectedSchema(let schema):
                return L10n.format("error.siz.unexpectedSchema", schema)
            case .missingInnerArchive(let name):
                return L10n.format("error.siz.missingInnerArchive", name)
            case .invalidContainerEntry(let name):
                return L10n.format("error.siz.invalidContainerEntry", name)
            case .unexpectedContainerComponents(let names):
                return L10n.format("error.siz.unexpectedContainerComponents", names)
            }
        }
    }

    private struct ContainerEntry {
        let rawName: String
        let normalizedName: String
        let type: Character
    }

    private static func validatedContainerEntries(at sizURL: URL) async throws -> [ContainerEntry] {
        let namesOutput = try await BackendProcessRunner.runAndCapture("/usr/bin/tar", arguments: ["-tf", sizURL.path])
        let rawNames = namesOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard !rawNames.isEmpty else {
            throw SIZError.missingContainerComponents
        }

        let verboseOutput = try await BackendProcessRunner.runAndCapture("/usr/bin/tar", arguments: ["-tvf", sizURL.path])
        let verboseLines = verboseOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let entries = try rawNames.map { rawName in
            let normalized = normalizedContainerPath(rawName)
            let type = try tarEntryType(for: rawName, verboseLines: verboseLines)
            return ContainerEntry(rawName: rawName, normalizedName: normalized, type: type)
        }

        let unsafeNames = entries
            .map(\.normalizedName)
            .filter { $0 != "." && ArchiveSafety.isUnsafeEntryName($0) }
        guard unsafeNames.isEmpty else {
            throw ArchiveError.unsafeArchiveEntries(Array(unsafeNames.prefix(5)))
        }

        let unsafeTypes = entries.filter { entry in
            guard entry.normalizedName != "." else { return entry.type != "d" }
            return entry.type != "-"
        }
        guard unsafeTypes.isEmpty else {
            throw SIZError.invalidContainerEntry(unsafeTypes.first?.normalizedName ?? "?")
        }

        let duplicate = Dictionary(grouping: entries.map(\.normalizedName), by: { $0 })
            .first { name, values in name != "." && values.count > 1 }
        if let duplicate {
            throw SIZError.unexpectedContainerComponents(duplicate.key)
        }

        return entries
    }

    private static func requiredEntry(_ normalizedName: String, in entries: [ContainerEntry]) throws -> ContainerEntry {
        guard let entry = entries.first(where: { $0.normalizedName == normalizedName }) else {
            if normalizedName == metadataFileName || normalizedName == signatureFileName {
                throw SIZError.missingContainerComponents
            }
            throw SIZError.missingInnerArchive(normalizedName)
        }
        guard entry.type == "-" else {
            throw SIZError.invalidContainerEntry(normalizedName)
        }
        return entry
    }

    private static func validateExpectedContainerComponents(innerArchiveName: String, entries: [ContainerEntry]) throws {
        let expected: Set<String> = [metadataFileName, signatureFileName, innerArchiveName]
        let unexpected = entries
            .map(\.normalizedName)
            .filter { $0 != "." && !expected.contains($0) }
        guard unexpected.isEmpty else {
            throw SIZError.unexpectedContainerComponents(Array(unexpected.prefix(5)).joined(separator: ", "))
        }
    }

    private static func extract(entries: [ContainerEntry], from sizURL: URL, to destination: URL) async throws {
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-xf", sizURL.path, "-C", destination.path] + entries.map(\.rawName)
        )
    }

    private static func validatedInnerArchiveName(_ name: String) throws -> String {
        let normalized = normalizedContainerPath(name)
        guard normalized == name,
              normalized.hasPrefix("archive."),
              normalized.count > "archive.".count,
              !normalized.contains("/"),
              !normalized.contains("\\"),
              normalized != metadataFileName,
              normalized != signatureFileName,
              !ArchiveSafety.isUnsafeEntryName(normalized) else {
            throw SIZError.invalidContainerEntry(name)
        }
        return normalized
    }

    private static func normalizedContainerPath(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("./") {
            name.removeFirst(2)
        }
        return name == "" ? "." : name
    }

    private static func tarEntryType(for rawName: String, verboseLines: [String]) throws -> Character {
        for line in verboseLines {
            guard let first = line.first else { continue }
            if line.hasSuffix(" \(rawName)") || line.contains(" \(rawName) -> ") {
                return first
            }
        }
        throw SIZError.invalidContainerEntry(rawName)
    }
}
