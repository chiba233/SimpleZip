//
//  SZSArchive.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import CryptoKit
import Foundation

/// SimpleZip 的「签名清单」格式。
///
/// 设计动机：`.siz` 解决的是「单 archive + 签名一起送」；`.szs` 解决另一类问题 ——
/// **想签一棵文件树，但希望文件留在原地分别下载 / 分发**。典型用例：
/// - 发布物（app + LICENSE + README + checksums.txt）—— 让用户读 README 不需要先解包；
/// - 镜像 / CDN 内容快照 —— 每文件单独缓存、按文件 ETag 工作；
/// - 收件人按文件挑下载，签名负责「这一堆文件作为整体未被篡改」。
///
/// 容器形态：**GPG clearsigned message**（不是 tar 不是 zip），就是 `gpg --clearsign` 标准输出：
/// ```
/// -----BEGIN PGP SIGNED MESSAGE-----
/// Hash: SHA512
///
/// { ...manifest JSON 字节，确定性编码... }
/// -----BEGIN PGP SIGNATURE-----
/// ...
/// -----END PGP SIGNATURE-----
/// ```
/// 优势：单文件、人类可 `cat`、`gpg --verify` 直接校验、签名 + 元数据天然在一起。
///
/// 详见 `docs/SZS-FORMAT.md`。本 namespace 负责：
/// - 序列化 `Manifest` → 确定性 JSON 字节（给 `clearsign` 当输入）；
/// - 解析 clearsigned `.szs` → 验签结果 + Manifest；
/// - 校验每条 file entry 的实际 SHA256 → 汇总 `SZSVerifyReport`。
enum SZSArchive {
    static let extensionName = "szs"
    static let schemaIdentifier = "SimpleZip.szs"
    static let schemaVersion = 1

    /// 清单 JSON 顶层结构。所有字段在 SZS-FORMAT.md 里有详细说明。
    struct Manifest: Codable, Equatable {
        var schema: String
        var version: Int
        /// ISO-8601 UTC 创建时间。
        var createdAt: String
        /// 创建端 App 版本，比如 "SimpleZip 0.1.9"。
        var createdBy: String
        /// （可选）UI 显示用标题。
        var title: String?
        /// （可选）UI 显示用长说明。
        var description: String?
        /// （可选）建议根目录名（UI 提示用）。
        var rootDirectoryHint: String?
        /// 文件条目列表。**约定**：调用方序列化前必须按 `relativePath` 字典序排好（让签名字节确定）。
        var files: [FileEntry]
    }

    /// 单个文件条目。`relativePath` 是相对路径（forward slash 分隔）；`sha256` 是 64 字符小写 hex。
    struct FileEntry: Codable, Equatable {
        var relativePath: String
        var size: Int
        var sha256: String
        var mediaType: String?
    }

    /// 验签 + 文件校验报告。`signature` 复用 `.siz` 的 `GPGVerifyResult` 枚举 —— 同套状态码、同套 trust 等级、同套 fingerprint 检查。
    struct VerifyReport: Equatable {
        let signature: GPGBackend.GPGVerifyResult
        let manifest: Manifest
        let entries: [Entry]

        enum Entry: Equatable {
            case match(relativePath: String, sizeBytes: Int)
            case mismatch(relativePath: String, expectedSHA: String, actualSHA: String)
            case missing(relativePath: String)
            case unreadable(relativePath: String, reason: String)

            var relativePath: String {
                switch self {
                case .match(let p, _), .mismatch(let p, _, _), .missing(let p), .unreadable(let p, _):
                    return p
                }
            }
        }

        struct Summary: Equatable {
            let total: Int
            let matched: Int
            let mismatched: Int
            let missing: Int
            let unreadable: Int
            /// `true` 时整个 manifest 校验全过（不含签名层）—— UI 头部 badge 用这个判定整体绿 / 黄。
            var allFilesOk: Bool { mismatched == 0 && missing == 0 && unreadable == 0 }
        }

        var summary: Summary {
            var matched = 0, mismatched = 0, missing = 0, unreadable = 0
            for entry in entries {
                switch entry {
                case .match: matched += 1
                case .mismatch: mismatched += 1
                case .missing: missing += 1
                case .unreadable: unreadable += 1
                }
            }
            return Summary(
                total: entries.count,
                matched: matched,
                mismatched: mismatched,
                missing: missing,
                unreadable: unreadable
            )
        }
    }

    enum SZSError: LocalizedError {
        case manifestParseFailed(String)
        case unexpectedSchema(String)
        case unsafeRelativePath(String)
        case fileOutsidePayloadRoot(String)
        case noFilesToSign
        case duplicateRelativePath(String)

        var errorDescription: String? {
            switch self {
            case .manifestParseFailed(let reason):
                return L10n.format("error.szs.manifestParseFailed", reason)
            case .unexpectedSchema(let schema):
                return L10n.format("error.szs.unexpectedSchema", schema)
            case .unsafeRelativePath(let path):
                return L10n.format("error.szs.unsafeRelativePath", path)
            case .fileOutsidePayloadRoot(let path):
                return L10n.format("error.szs.fileOutsidePayloadRoot", path)
            case .noFilesToSign:
                return L10n.text("error.szs.noFilesToSign")
            case .duplicateRelativePath(let path):
                return L10n.format("error.szs.duplicateRelativePath", path)
            }
        }
    }

    // MARK: - 序列化

    /// 确定性 JSON encoder：`[.prettyPrinted, .sortedKeys]` —— 同输入永远同字节，是 clearsign 能校验的前提。
    static func encodeManifest(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    // MARK: - 路径校验

    /// 校验 + 归一化清单里出现的相对路径。
    ///
    /// 拒绝：
    /// - 绝对路径（以 `/` 开头）/ Windows 盘符（含 `:` 第二位）/ UNC 路径（`\\…`）；
    /// - 反斜杠 `\`（强制 forward slash 分隔）；
    /// - 含 `..` 组件（路径穿越）；
    /// - 含空段（`a//b`）/ 以 `.` 或 `..` 单独成段；
    /// - 通过 `ArchiveSafety.isUnsafeEntryName` 标记的可疑名。
    static func validatedRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SZSError.unsafeRelativePath(raw)
        }
        // 拒绝反斜杠 / Windows 盘符 / UNC：在分割前判断更明确。
        if trimmed.contains("\\") {
            throw SZSError.unsafeRelativePath(raw)
        }
        if trimmed.hasPrefix("/") {
            throw SZSError.unsafeRelativePath(raw)
        }
        if trimmed.count >= 2 {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: 1)
            if trimmed[idx] == ":" {
                throw SZSError.unsafeRelativePath(raw)
            }
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component.isEmpty {
                throw SZSError.unsafeRelativePath(raw) // `a//b`
            }
            if component == "." || component == ".." {
                throw SZSError.unsafeRelativePath(raw)
            }
            if ArchiveSafety.isUnsafeEntryName(component) {
                throw SZSError.unsafeRelativePath(raw)
            }
        }
        return trimmed
    }

    // MARK: - 目录展开

    /// 把用户选中的条目（文件 / 目录混合）展开成「要逐条签名的普通文件」列表 —— `.szs` 的目录支持核心。
    ///
    /// `.szs` 清单只签**普通文件**（每条带 relativePath + size + sha256），目录结构隐含在 relativePath 里
    /// （浏览端 `openSZSAsVirtualFolder` 会从 relativePath 反推目录树）。所以「支持目录」= 选了目录就递归收其下所有普通文件。
    ///
    /// - 目录 → 递归收集其下所有**普通文件**；
    /// - 普通文件 → 原样保留；
    /// - 符号链接（无论指向文件还是目录）→ **跳过**：签名应锚定真实文件字节，且不跟随 symlink 可避免把 payloadRoot
    ///   之外的目标偷渡进清单（`FileManager` 目录枚举默认也不descend进 symlink 目录）。
    /// - 空目录无法表示（清单只列文件）→ 自然被忽略，符合「签一棵文件树」的语义。
    ///
    /// 顺序不保证；`create` 之后会按 relativePath 排序。`internal` 以便创建 UI 预先展开、让文件计数 / 列表准确。
    static func expandToRegularFiles(_ urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var result: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [] // 不跳隐藏文件：选了目录就签里面所有真实文件；默认不descend进 symlink 目录
                ) else { continue }
                for case let child as URL in enumerator {
                    let childValues = try? child.resourceValues(forKeys: Set(keys))
                    if childValues?.isSymbolicLink == true { continue }
                    if childValues?.isRegularFile == true { result.append(child) }
                }
            } else if values?.isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - 创建

    /// 给定 root + 文件列表 + 签名密钥，生成签名的 `.szs` 文件。
    ///
    /// 流程（详见 SZS-FORMAT.md「Creation flow」）：
    /// 1. 对每个 file URL 校验「真正在 payloadRoot 下」+ 计算 relativePath + 流式 SHA256 + 文件大小；
    /// 2. 按 relativePath 字典序排（签名确定性前提）；
    /// 3. 组装 Manifest，确定性 encode 成 JSON 字节；
    /// 4. 把 JSON 字节写到 staging plaintext file，跑 `GPGBackend.clearsign` 输出 `.szs`；
    /// 5. 临时 plaintext 在 defer 里清掉。
    ///
    /// 签名 passphrase 跟 `.siz` 一样走 gpg-agent + pinentry-mac，本函数不接触。
    static func create(
        payloadRoot: URL,
        files: [URL],
        signingKeyFingerprint: String?,
        title: String? = nil,
        description: String? = nil,
        rootDirectoryHint: String? = nil,
        outputURL: URL,
        operationID: UUID? = nil
    ) async throws {
        guard !files.isEmpty else {
            throw SZSError.noFilesToSign
        }
        let payloadRootPath = payloadRoot.standardizedFileURL.path

        // Step 0：把选中的目录递归展开成普通文件（`.szs` 目录支持）。文件原样、目录递归、符号链接跳过。
        // 展开后可能为空（只选了空目录 / 符号链接）→ 视为「没东西可签」。
        let resolvedFiles = expandToRegularFiles(files)
        guard !resolvedFiles.isEmpty else {
            throw SZSError.noFilesToSign
        }

        // Step 1：扫每个文件 → relativePath + size + sha256。
        var entries: [FileEntry] = []
        for fileURL in resolvedFiles {
            let absolutePath = fileURL.standardizedFileURL.path
            // 「fileURL 真的在 payloadRoot 下」 —— 不仅看路径前缀，还要保证 path 边界正确：
            // `/foo/bar` 不是 `/foo/barz` 的前缀，得加 `/` 后缀检查。
            let normalizedRoot = payloadRootPath.hasSuffix("/") ? payloadRootPath : payloadRootPath + "/"
            guard absolutePath.hasPrefix(normalizedRoot) else {
                throw SZSError.fileOutsidePayloadRoot(absolutePath)
            }
            let rawRelative = String(absolutePath.dropFirst(normalizedRoot.count))
            let relativePath = try validatedRelativePath(rawRelative)
            let attrs = try FileManager.default.attributesOfItem(atPath: absolutePath)
            let size = (attrs[.size] as? Int) ?? 0
            let sha256 = try SIZArchive.computeInnerArchiveSHA256(of: fileURL)
            entries.append(FileEntry(relativePath: relativePath, size: size, sha256: sha256, mediaType: nil))
        }

        // Step 2：按 relativePath 字典序排序。同时拒绝重复 relativePath（同一文件被签两次）。
        entries.sort { $0.relativePath < $1.relativePath }
        var seen = Set<String>()
        for entry in entries {
            if !seen.insert(entry.relativePath).inserted {
                throw SZSError.duplicateRelativePath(entry.relativePath)
            }
        }

        // Step 3：组装 Manifest + 确定性 encode。
        let manifest = Manifest(
            schema: schemaIdentifier,
            version: schemaVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            createdBy: "SimpleZip \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            title: title?.isEmpty == false ? title : nil,
            description: description?.isEmpty == false ? description : nil,
            rootDirectoryHint: rootDirectoryHint?.isEmpty == false ? rootDirectoryHint : nil,
            files: entries
        )
        let manifestData = try encodeManifest(manifest)

        // Step 4：plaintext 写 staging，clearsign 写到 outputURL。
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-SZS-Create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let plaintextURL = staging.appendingPathComponent("manifest.json")
        try manifestData.write(to: plaintextURL, options: .atomic)

        try await GPGBackend.clearsign(
            plaintextURL: plaintextURL,
            signingKeyFingerprint: signingKeyFingerprint,
            outputURL: outputURL,
            operationID: operationID
        )
    }

    // MARK: - 校验

    /// 给定一个 `.szs` 文件路径 + 一个 payload 根目录，跑完整校验：签名 + 每文件 SHA256。
    static func verify(
        manifestURL: URL,
        payloadRoot: URL,
        operationID: UUID? = nil
    ) async throws -> VerifyReport {
        // Step 1：gpg 校验 + 拿明文 JSON。
        let (signatureResult, plaintext) = try await GPGBackend.verifyClearsign(
            signedURL: manifestURL,
            operationID: operationID
        )
        guard !plaintext.isEmpty else {
            // 拿不到明文 → 既无法解析 manifest，也算不上完整 verify。caller 把 signatureResult 当主信息展示就行。
            throw SZSError.manifestParseFailed("empty plaintext after gpg --decrypt")
        }

        // Step 2：解析 + 校验 Manifest schema。
        let manifest = try decodeManifest(from: plaintext)

        // Step 3：每文件 SHA256 校验。
        let entries = checkFiles(manifest: manifest, payloadRoot: payloadRoot)

        return VerifyReport(signature: signatureResult, manifest: manifest, entries: entries)
    }

    /// 偷懒版：只想拿到 manifest（看看清单 / 选择校验根目录之前），不做文件 SHA 校验。
    /// 签名结果一起返回，UI 可以在「让用户选 payloadRoot」之前先显示「这份 .szs 是 chiba 签的，含 12 个文件」。
    static func peek(
        manifestURL: URL,
        operationID: UUID? = nil
    ) async throws -> (signature: GPGBackend.GPGVerifyResult, manifest: Manifest) {
        let (signatureResult, plaintext) = try await GPGBackend.verifyClearsign(
            signedURL: manifestURL,
            operationID: operationID
        )
        guard !plaintext.isEmpty else {
            throw SZSError.manifestParseFailed("empty plaintext after gpg --decrypt")
        }
        let manifest = try decodeManifest(from: plaintext)
        return (signatureResult, manifest)
    }

    // MARK: - GPG 关闭时的明文路径（master toggle off）

    /// 不经过 GPG，从 clearsigned `.szs` 里直接抽出明文 manifest JSON。
    ///
    /// **仅用于 `AppPreferences.gpgEnabled == false`**：用户主动放弃 GPG（常见原因是 gpg 根本没装），
    /// 但 `.szs` 是注册文件类型，「以虚拟目录浏览」仍要能用 —— 文件级 SHA256 校验不依赖 GPG。
    /// 这里**不做任何签名校验**，只解析 RFC 4880 clearsigned 的明文段：
    /// 取 `-----BEGIN PGP SIGNED MESSAGE-----` 之后的 armor header 块、跳过其后的空行，
    /// 收集到 `-----BEGIN PGP SIGNATURE-----` 之前的正文，并还原 dash-escape（行首 `- ` → 去掉）。
    /// JSON 解析对多余空白宽容，所以不需要逐字节复刻签名时的规范化。
    static func extractClearsignedManifest(manifestURL: URL) throws -> Manifest {
        let raw: String
        do {
            raw = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw SZSError.manifestParseFailed(error.localizedDescription)
        }
        // 统一成 \n，规避 CRLF。
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        guard let beginIdx = lines.firstIndex(where: {
            $0.hasPrefix("-----BEGIN PGP SIGNED MESSAGE-----")
        }) else {
            throw SZSError.manifestParseFailed("missing PGP SIGNED MESSAGE header")
        }
        // armor header 块（Hash: ... 等）一直到第一个空行为止。
        var idx = beginIdx + 1
        while idx < lines.count && !lines[idx].isEmpty { idx += 1 }
        guard idx < lines.count else {
            throw SZSError.manifestParseFailed("malformed clearsigned header")
        }
        idx += 1 // 跳过 header 与正文之间的空行。

        guard let sigOffset = lines[idx...].firstIndex(where: {
            $0.hasPrefix("-----BEGIN PGP SIGNATURE-----")
        }) else {
            throw SZSError.manifestParseFailed("missing PGP SIGNATURE block")
        }

        let body = lines[idx..<sigOffset].map { line -> String in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        }.joined(separator: "\n")

        guard let data = body.data(using: .utf8) else {
            throw SZSError.manifestParseFailed("cleartext not valid UTF-8")
        }
        return try decodeManifest(from: data)
    }

    /// GPG 关闭时的浏览校验：不验签，只抽明文 manifest + 跑文件 SHA256。
    ///
    /// 返回的 `VerifyReport.signature` 用 `.verificationError`（带「GPG 未启用」文案）占位 ——
    /// 调用方（silent browse）在 `gpgEnabled == false` 时本就忽略签名状态、只看文件校验结果，
    /// 这个占位仅在用户主动点开「详情」时显示，明确告知「签名未校验，因为 GPG 未启用」。
    static func verifyWithoutSignature(manifestURL: URL, payloadRoot: URL) throws -> VerifyReport {
        let manifest = try extractClearsignedManifest(manifestURL: manifestURL)
        let entries = checkFiles(manifest: manifest, payloadRoot: payloadRoot)
        return VerifyReport(
            signature: .verificationError(message: L10n.text("szs.signature.gpgDisabled")),
            manifest: manifest,
            entries: entries
        )
    }

    // MARK: - 共享内部逻辑

    /// 解码 manifest JSON 字节 + 校验 schema / version。peek / verify / 明文路径共用。
    private static func decodeManifest(from data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw SZSError.manifestParseFailed(error.localizedDescription)
        }
        guard manifest.schema == schemaIdentifier else {
            throw SZSError.unexpectedSchema(manifest.schema)
        }
        guard manifest.version == schemaVersion else {
            throw SZSError.unexpectedSchema("\(manifest.schema) v\(manifest.version)")
        }
        return manifest
    }

    /// 逐条 file entry 跑 SHA256 校验，产出 `VerifyReport.Entry` 列表。签名校验之外的纯文件层逻辑，
    /// 被 `verify`（GPG 路径）和 `verifyWithoutSignature`（明文路径）共用。
    private static func checkFiles(manifest: Manifest, payloadRoot: URL) -> [VerifyReport.Entry] {
        var entries: [VerifyReport.Entry] = []
        for fileEntry in manifest.files {
            // 双重 validatedRelativePath：保护「攻击者塞个 `../escape.txt` 在 manifest 里」的情况。
            // 即使 manifest 是签了名的（说明信任签名者），但签名者也可能本身被攻陷 / 把恶意 manifest 误签。
            do {
                _ = try validatedRelativePath(fileEntry.relativePath)
            } catch {
                entries.append(.unreadable(
                    relativePath: fileEntry.relativePath,
                    reason: L10n.text("error.szs.unsafeRelativePath.short")
                ))
                continue
            }
            let fileURL = payloadRoot.appendingPathComponent(fileEntry.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                entries.append(.missing(relativePath: fileEntry.relativePath))
                continue
            }
            do {
                let actualSHA = try SIZArchive.computeInnerArchiveSHA256(of: fileURL)
                if actualSHA.lowercased() == fileEntry.sha256.lowercased() {
                    entries.append(.match(relativePath: fileEntry.relativePath, sizeBytes: fileEntry.size))
                } else {
                    entries.append(.mismatch(
                        relativePath: fileEntry.relativePath,
                        expectedSHA: fileEntry.sha256,
                        actualSHA: actualSHA
                    ))
                }
            } catch {
                entries.append(.unreadable(
                    relativePath: fileEntry.relativePath,
                    reason: error.localizedDescription
                ))
            }
        }
        return entries
    }
}
