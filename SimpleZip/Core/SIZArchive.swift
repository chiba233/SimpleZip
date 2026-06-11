//
//  SIZArchive.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import CryptoKit
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
/// metadata.json     ← 本 namespace 的 schema 元信息（含内层 SHA256）
/// signature.asc     ← `gpg --detach-sign --armor` 输出，对 **metadata.json** 字节签名
/// ```
///
/// **签名目标 = metadata.json，不是内层 archive。** 直接签内层 archive 会导致 metadata（包括 signer 名 /
/// 时间 / inner archive 文件名）能被任意改而签名仍然有效——攻击者可以重命名 / 伪造创建者文案。
/// 改签 metadata 后，metadata 内部必须记录内层 archive 的 SHA256（`innerArchiveSHA256`），这样：
/// - 篡改 metadata 任何字段 → gpg 验签直接失败；
/// - 篡改 / 替换 inner archive → metadata 签名仍有效但 SHA 对不上 → verify 阶段判 `.badSignature`。
/// 两道防线都过 = 容器真实未篡改。
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
    /// 当前 schema 版本 —— **v4** 新加 `deliveryInstructions` 字段（#110 收件人说明，签名背书、防篡改）。
    /// 历史：v2 = 仅签名；v3 加 `encryption`（多收件人加密）；v4 加 `deliveryInstructions`。
    /// 版本兼容：unwrap 接受 v2 / v3 / v4（缺哪个新字段就等同于不带它，向前向后都安全）；**创建端总是写最新 v4**。
    /// 跟 v3 同一惯例：新增字段就 bump version + 在 `acceptedSchemaVersions` 加一项。老 v1（如果有）schema mismatch 直接拒绝。
    /// 注意:0.3.1 之前的 SimpleZip(accepted 只到 v3)打不开 v4 .siz —— 跟当年 v2-only 打不开 v3 是同一取舍。
    static let schemaVersion = 4
    /// unwrap 时接受的所有 schema 版本号，新版进来时只在这里加一项就行。
    static let acceptedSchemaVersions: Set<Int> = [2, 3, 4]

    /// `metadata.json` 反序列化产物 —— 描述内层压缩包 + 签名者 + （可选）加密信息。
    struct Metadata: Codable, Equatable {
        var schema: String
        var version: Int
        /// tar 内层 archive 的文件名（含扩展名）——
        /// 不加密时：`archive.<ext>`（比如 `archive.zip`）；
        /// 加密时（`encryption != nil`）：`archive.<ext>.gpg`（gpg --encrypt 产物，二进制）。
        var innerArchiveName: String
        /// 内层压缩格式（"zip" / "7z" / "rar" / "tar.gz" / …），UI 展示用。
        /// 加密时仍是**原始**压缩格式名（即解密后的内层），不是 "gpg"。
        var innerFormat: String
        /// 用户最初想给压缩包起的名字（含扩展名），比如 "MyProject.zip" ——
        /// unwrap 后想还原原始命名时用得上。
        var originalArchiveName: String
        /// **内层 archive 的 SHA256（hex 小写，64 字符）**。
        /// 不加密时 = SHA256 of plaintext archive；
        /// 加密时 = **SHA256 of encrypted bytes**（即 `archive.<ext>.gpg` 文件本身）。
        /// 加密态下用密文 SHA 而不是明文 SHA 是关键决策：让没有解密密钥的人也能校验完整性（SHA 跟 sig 一起验通过 = 容器是真的；
        /// 不解密就不能拿到明文，符合机密性预期）；同时阻止「重加密攻击」—— 攻击者就算有明文也无法生成 SHA 一致的不同密文
        /// （gpg session key 随机，每次密文不同）。
        var innerArchiveSHA256: String
        /// ISO-8601 创建时间，给 UI 显示「于 X 时签名」用。
        var createdAt: String
        /// 创建端版本，"SimpleZip 0.1.7" 之类，调试 / 兼容性追溯用。
        var createdBy: String
        var signature: SignatureInfo
        /// 加密信息。**nil = 不加密**（v2 行为完全保留）；非 nil = 多收件人加密。v3 起新增。
        /// `recipients` 数组的内容是「**主张**」—— 真实加密时实际用了哪些公钥要看 gpg 的 `--list-packets`。
        /// 不过对验证 / 显示而言，metadata 里这份签了名的清单已经够用：因为整个 metadata 由 gpg 签名背书，
        /// 攻击者改不了 recipients 列表又不让签名失效。
        var encryption: EncryptionInfo?
        /// **收件人说明（#110 加密投递包）** —— 人类可读的「这是什么 / 谁签的 / 怎么验签 / 怎么解密」一段文字。
        /// **故意放进 metadata 而不是往容器塞第四个文件**：metadata.json 正是签名目标，所以这段说明被签名背书 →
        /// **防篡改**（改一个字签名就失效），同时**完全不动 `.siz` 的「容器内只允许三个文件」防御**（SECURITY.md 威胁模型）。
        /// 由 `makeDeliveryInstructions(for:)` 在创建时生成。`nil` = 老 .siz / 未生成（Optional 缺省不进 JSON,字节与旧格式一致 →
        /// 向前向后兼容:老版本读到未知键会忽略,签名仍校验通过)。
        var deliveryInstructions: String? = nil
    }

    /// 加密元信息。出现 = 内层 archive 是 `archive.<ext>.gpg` 形式的 gpg 加密包。
    /// **解密路径**：本机持有 `recipients` 任一 fingerprint 对应的私钥**或**知道 `hasSymmetricPassphrase` 对应的密码。
    struct EncryptionInfo: Codable, Equatable {
        /// 收件人列表 —— 每项是一对 fingerprint + UID 文案。UI 用这个列表显示「加密给：Alice <…>、Bob <…>」。
        /// 空数组 = 仅对称密码加密。
        var recipients: [RecipientInfo]
        /// 加密算法标识。当前固定 "gpg"，留字段方便日后扩展（比如 age）。
        var algorithm: String
        /// 是否同时设置了对称密码（`gpg --symmetric`）。
        /// **密码本身不会出现在 metadata 里**（敏感）—— 这只是个开关让 UI 在解压时显示「需要密码」提示。
        /// 老 v3 metadata 无此字段 = false（兼容）；这是 Codable 字段，让 JSON 缺这字段时解码不报错。
        var hasSymmetricPassphrase: Bool? = nil
    }

    /// 单个收件人信息 —— UID 是「打印用」的，fingerprint 是「定位密钥」的。
    struct RecipientInfo: Codable, Equatable {
        var fingerprint: String
        var userID: String
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

    /// 把已经造好的内层 archive + 已签名的 metadata 打包成 `.siz`。
    ///
    /// 调用方负责：
    /// 1. 计算 inner archive 的 SHA256 → 灌进 `metadata.innerArchiveSHA256`（用 `computeInnerArchiveSHA256`）。
    /// 2. 用 `encodeMetadata(metadata)` 拿到将要落盘的字节，用 `gpg --detach-sign` 签这些字节，
    ///    把签名文件交给 `signatureFile`（armor `.asc`）。
    /// 3. 调用本函数 —— 它再次 encode 同一个 metadata（确定性 encoder：sortedKeys + prettyPrinted），
    ///    所以落盘的 metadata.json 字节跟调用方刚才签的字节完全一致。
    ///
    /// 这个分工保持 SIZArchive 不依赖 GPGBackend，签名步骤由 caller 直连 GPG。
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

        // 1) 内层 archive → archive.<ext>（按 metadata 里声明的名字落盘）
        let stagedInner = staging.appendingPathComponent(innerName)
        try fileManager.copyItem(at: innerArchive, to: stagedInner)

        // 2) signature.asc
        let stagedSignature = staging.appendingPathComponent(signatureFileName)
        try fileManager.copyItem(at: signatureFile, to: stagedSignature)

        // 3) metadata.json —— 用同一个确定性 encoder 写盘，跟 caller 签的字节一致。
        let metadataData = try encodeMetadata(metadata)
        try metadataData.write(to: staging.appendingPathComponent(metadataFileName), options: .atomic)

        // 4) tar 平铺：显式列出三个文件名，避免生成 `./` 前缀目录项。
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/tar",
            arguments: ["-cf", outputURL.path, "-C", staging.path, innerName, metadataFileName, signatureFileName]
        )
    }

    /// 把 Metadata 序列化成最终 metadata.json 的字节。
    /// **必须**用这个函数：caller 在签名前需要拿到「跟容器内最终一致」的字节，
    /// 否则 detached signature 跟容器内的 metadata.json 字节不匹配，gpg 验签必败。
    /// 确定性输出：`sortedKeys + prettyPrinted` → 同输入永远同字节。
    static func encodeMetadata(_ metadata: Metadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(metadata)
    }

    /// **#110 收件人说明生成器** —— 从 metadata 派生一段人类可读的「投递说明」,写进 `metadata.deliveryInstructions`,
    /// 随 metadata.json 一起被 gpg 签名(防篡改)。给收到 `.siz` 的人(无论有没有装 SimpleZip)讲清楚:
    /// 这是什么、谁签的、(若加密)加密给谁、用 SimpleZip 怎么验、不用 SimpleZip 怎么手动 tar + gpg 验签 / 解密 / 校验完整性。
    ///
    /// 纯函数(只读 metadata + L10n),无副作用、可单测。
    /// **数据值(指纹 / SHA / 文件名 / 命令)一律用 Swift 插值直接拼**,不走 `L10n.format` 的 `%@` ——
    /// 这样即便某语言没翻全 / 测试环境拿不到 .lproj(SwiftPM Core 排除了本地化),数据也永远在文本里、不会丢。
    /// 只有「解说文字 / 标签」走 `L10n.text`(跟创建者语言)。
    ///
    /// - `senderNote`:创建者自己写给收件人的话(可选,来自创建对话框),放最前面。它也随 metadata 被签名 → 防篡改。
    static func makeDeliveryInstructions(for metadata: Metadata, senderNote: String? = nil) -> String {
        var lines: [String] = []

        // 发送者留言(可选)——放最前。
        if let note = senderNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append(L10n.text("siz.instructions.senderNote"))
            lines.append(note)
            lines.append("")
        }

        lines.append(L10n.text("siz.instructions.header"))
        lines.append("")

        // 签名者(标签走 L10n,值用插值)。
        let signerName = metadata.signature.signerUserID.isEmpty
            ? metadata.signature.signerFingerprint
            : metadata.signature.signerUserID
        if !signerName.isEmpty {
            lines.append("\(L10n.text("siz.instructions.signer")) \(signerName)")
        }
        if !metadata.signature.signerFingerprint.isEmpty {
            lines.append("\(L10n.text("siz.instructions.fingerprint")) \(metadata.signature.signerFingerprint)")
        }
        if !metadata.createdAt.isEmpty {
            lines.append("\(L10n.text("siz.instructions.created")) \(metadata.createdAt)")
        }

        // 加密状态。
        if let encryption = metadata.encryption {
            if encryption.recipients.isEmpty {
                lines.append(L10n.text("siz.instructions.encryptedSymmetric"))
            } else {
                lines.append(L10n.text("siz.instructions.encryptedRecipients"))
                for recipient in encryption.recipients {
                    let who = recipient.userID.isEmpty ? recipient.fingerprint : recipient.userID
                    lines.append("  • \(who) (\(recipient.fingerprint))")
                }
                if encryption.hasSymmetricPassphrase == true {
                    lines.append(L10n.text("siz.instructions.alsoSymmetric"))
                }
            }
        } else {
            lines.append(L10n.text("siz.instructions.notEncrypted"))
        }
        lines.append("")

        // 用 SimpleZip。
        lines.append(L10n.text("siz.instructions.withSimpleZip"))
        lines.append("")

        // 手动验签 / 解密(命令固定,值插值)。
        lines.append(L10n.text("siz.instructions.manualHeader"))
        lines.append("  tar -xf <name>.\(extensionName)")
        lines.append("  gpg --verify \(signatureFileName) \(metadataFileName)")
        let extractTarget: String
        if metadata.encryption != nil {
            // 加密内层:innerArchiveName 形如 archive.<ext>.gpg → 解密出 archive.<ext>。
            let decryptedName = metadata.innerArchiveName.lowercased().hasSuffix(".gpg")
                ? String(metadata.innerArchiveName.dropLast(4))
                : metadata.innerArchiveName
            lines.append("  gpg --output \(decryptedName) --decrypt \(metadata.innerArchiveName)")
            extractTarget = decryptedName
        } else {
            extractTarget = metadata.innerArchiveName
        }
        lines.append("  \(L10n.text("siz.instructions.thenExtract")) \(extractTarget)")
        lines.append("")

        // 完整性校验(SHA 是 innerArchiveName 本体的 SHA;加密态是密文 SHA,可在不解密时先校验)。
        lines.append(L10n.text("siz.instructions.integrity"))
        lines.append("  shasum -a 256 \(metadata.innerArchiveName)")
        lines.append("  = \(metadata.innerArchiveSHA256)")
        lines.append("")

        // SimpleZip 从不经手私钥 passphrase 的提醒(发布说明一贯强调,见 feedback_gpg_release_emphasis)。
        lines.append(L10n.text("siz.instructions.passphraseNote"))
        return lines.joined(separator: "\n")
    }

    /// 流式算 inner archive 的 SHA256 hex（小写 64 字符），不一次性 load 整个 archive 进内存。
    /// 用 1MB 缓冲块读到 EOF。
    static func computeInnerArchiveSHA256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 拆包

    /// 把 `.siz` 拆开到指定目录，返回内层 archive URL + signature URL + 解析过的 metadata。
    /// 调用方应自己清理 destination（unwrap 用 caller 提供的目录，不自己起临时目录）。
    static func unwrap(at sizURL: URL, to destination: URL, allowNewerVersion: Bool = false) async throws -> UnwrapResult {
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
        try validateSchemaVersion(metadata, allowNewerVersion: allowNewerVersion)
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
        return UnwrapResult(
            innerArchiveURL: innerURL,
            signatureURL: signatureURL,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }

    /// 完整验签：gpg 验 metadata 签名 + fingerprint 强校验 + 比对内层 archive SHA256。
    ///
    /// - gpg 验签失败（badSignature / unknownSigner / verificationError）→ 直接透传。
    /// - gpg 说签名有效 → 再做两道额外校验，任一失败就改判 `.badSignature`：
    ///   1. **Fingerprint 强校验**：metadata 声明的 `signerFingerprint` 必须等于 gpg `VALIDSIG` 报告的真实
    ///      签名主密钥 fingerprint。不等 = 攻击者把 metadata 换成自己的内容并用自己的密钥重签 = impersonation。
    ///      （没有 fingerprint 校验，受害者会被 metadata 里的 signer 文案误导。）
    ///   2. **SHA256 比对**：metadata 锁定的内层 archive SHA 必须跟实际 archive SHA 一致，否则容器内层被换过。
    static func verify(
        unwrap: UnwrapResult,
        operationID: UUID? = nil
    ) async throws -> GPGBackend.GPGVerifyResult {
        let gpgResult = try await GPGBackend.verify(
            archiveURL: unwrap.metadataURL,
            signatureURL: unwrap.signatureURL,
            operationID: operationID
        )

        switch gpgResult {
        case .validSignature(let signer, let actualFingerprint, _, _):
            // 1) Fingerprint 强校验：metadata 主张的 signerFingerprint 必须等于 gpg 真报。
            //    metadata 字段可能有空格 / 大小写差异，归一化后比较。
            if let actualFingerprint {
                let claimed = unwrap.metadata.signature.signerFingerprint
                    .filter { $0.isHexDigit }
                    .uppercased()
                if !claimed.isEmpty && claimed != actualFingerprint {
                    return .badSignature(signer: signer, fingerprint: actualFingerprint)
                }
            }
            // 2) 内层 archive SHA256 校验。
            let actual = try computeInnerArchiveSHA256(of: unwrap.innerArchiveURL)
            if actual.lowercased() != unwrap.metadata.innerArchiveSHA256.lowercased() {
                return .badSignature(signer: signer, fingerprint: actualFingerprint)
            }
            return gpgResult
        case .unknownSigner, .badSignature, .verificationError:
            return gpgResult
        }
    }

    /// 仅检查容器结构是否合法 + 读 metadata，不真正解开内层 archive。
    /// 给「打开压缩包之前快速看签名信息」用 —— 比完整 unwrap 轻量。
    /// schema / version 校验。0.4.1 前向兼容：**版本过高**单独成错误（`versionTooNew`，带专属解释文案），
    /// 跟「schema 不认识」区分开；`allowNewerVersion = true` 时放行更新版本（强制打开：未知新字段被
    /// Codable 静默忽略 —— 尽力解码，签名 / 加密语义可能不完整,UI 层弹窗已向用户说明风险）。
    private static func validateSchemaVersion(_ metadata: Metadata, allowNewerVersion: Bool) throws {
        guard metadata.schema == schemaIdentifier else {
            throw SIZError.unexpectedSchema(metadata.schema)
        }
        if acceptedSchemaVersions.contains(metadata.version) { return }
        let maxSupported = acceptedSchemaVersions.max() ?? 0
        if metadata.version > maxSupported {
            if allowNewerVersion { return }
            throw SIZError.versionTooNew(found: metadata.version, supported: maxSupported)
        }
        throw SIZError.unexpectedSchema("\(metadata.schema) v\(metadata.version)")
    }

    static func peekMetadata(at sizURL: URL, allowNewerVersion: Bool = false) async throws -> Metadata {
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
        try validateSchemaVersion(metadata, allowNewerVersion: allowNewerVersion)
        let innerName = try validatedInnerArchiveName(metadata.innerArchiveName)
        _ = try requiredEntry(signatureFileName, in: entries)
        _ = try requiredEntry(innerName, in: entries)
        try validateExpectedContainerComponents(innerArchiveName: innerName, entries: entries)
        return metadata
    }

    /// **解密**入口 —— 仅在 `metadata.encryption != nil` 时由 caller 调，输出是明文 archive URL。
    ///
    /// 内部跑 `GPGBackend.decrypt`，传 `decryptionKeyFingerprint` 作为「优先用哪把私钥」hint（多密钥用户在
    /// 解压对话框 picker 里挑过的）。明文输出文件名 = 把 `archive.<ext>.gpg` 末尾的 `.gpg` 去掉。
    /// 调用方负责：在用 unwrap.innerArchiveURL（密文）做完 SHA 校验后再调本函数；明文文件落到同目录。
    /// 输出 URL 应当跟 unwrap 的 tempRoot 是同一棵临时树，由 caller 的 tempRoot 清理覆盖。
    static func decryptInnerArchive(
        encryptedURL: URL,
        decryptionKeyFingerprint: String? = nil,
        passphrase: String? = nil,
        operationID: UUID? = nil
    ) async throws -> URL {
        // 把 archive.zip.gpg → archive.zip。坚持「去 .gpg 后缀」不是「去 pathExtension」是因为
        // pathExtension 不区分大小写、有可能撞 archive.tar.gz.gpg 这种双扩展名场景。
        let encryptedPath = encryptedURL.path
        let plaintextPath: String = {
            if encryptedPath.hasSuffix(".gpg") {
                return String(encryptedPath.dropLast(4))
            }
            // 兜底：没有 `.gpg` 后缀就在原文件名后加 `.plaintext`，避免覆盖输入。
            return encryptedPath + ".plaintext"
        }()
        let plaintextURL = URL(fileURLWithPath: plaintextPath)
        try await GPGBackend.decrypt(
            fileURL: encryptedURL,
            outputURL: plaintextURL,
            decryptionKeyFingerprint: decryptionKeyFingerprint,
            passphrase: passphrase,
            operationID: operationID
        )
        return plaintextURL
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

    /// `wrap` 返回值的「拆包」对偶 —— 内层 archive / signature / metadata 文件在 destination 下的实际位置 + 元信息。
    /// metadataURL 给 `verify` 调 gpg 时用（gpg 要求签名目标作为文件路径传入）。
    struct UnwrapResult {
        let innerArchiveURL: URL
        let signatureURL: URL
        let metadataURL: URL
        let metadata: Metadata
    }

    enum SIZError: LocalizedError {
        case missingContainerComponents
        case unexpectedSchema(String)
        /// 文件格式版本比本版 App 支持的还新（由更新版本的 SimpleZip 创建）。
        case versionTooNew(found: Int, supported: Int)
        case missingInnerArchive(String)
        case invalidContainerEntry(String)
        case unexpectedContainerComponents(String)

        var errorDescription: String? {
            switch self {
            case .missingContainerComponents:
                return L10n.text("error.siz.missingComponents")
            case .unexpectedSchema(let schema):
                return L10n.format("error.siz.unexpectedSchema", schema)
            case .versionTooNew(let found, let supported):
                return L10n.format("error.siz.versionTooNew", "\(found)", "\(supported)")
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
        // 接受 `archive.<ext>`（v2 / v3 不加密）和 `archive.<ext>.gpg`（v3 加密）两种形态。
        // 共同约束：`archive.` 开头、不含路径分隔符、不撞 metadata / signature 文件名、不可疑路径成分。
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
