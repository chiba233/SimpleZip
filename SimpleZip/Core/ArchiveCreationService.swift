//
//  ArchiveCreationService.swift
//  SimpleZip
//
//  0.3.0 架构拆分：把「创建压缩包 / 创建 GPG 签名 .siz 容器」的纯后端编排从
//  ArchiveBrowserModel+CreateExtract.swift 的任务闭包里抽到 Core，让 SwiftPM 可测、
//  且把后端 ownership 从 UI 模型移走。逻辑逐字保留，仅参数化 request / operationID /
//  progress / outputObserver，零行为变更。
//

import Foundation

/// 执行一个 `ArchiveCreationRequest`：未勾选 GPG 签名时直接产出用户指定的压缩包；
/// 勾选后走「内层压缩包 → (可选)加密 → 组装并签名 metadata → tar 成 `.siz`」五步。
enum ArchiveCreationService {
    /// 在 `startManagedArchiveTask` 的任务闭包里被调用 —— 参数与该闭包签名一致。
    static func run(
        _ request: ArchiveCreationRequest,
        operationID: UUID?,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void,
        outputObserver: (@Sendable (String) -> Void)?
    ) async throws {
        // 不带 GPG 签名 → 跟原来一样直接 createArchive 写到用户指定的 destinationURL。
        guard request.options.gpgSign else {
            try await ArchiveService.createArchive(
                from: request.sourceURLs,
                destination: request.destinationURL,
                options: request.options,
                operationID: operationID,
                progress: progress,
                outputObserver: outputObserver
            )
            return
        }

        // 带签名 → 三步走：
        // 1. 把内层压缩包做到临时 staging（用 inner format 的扩展名，比如 archive.zip）；
        // 2. 用 GPG 跑 detached signature；
        // 3. tar 打成 .siz 容器写到自动改名后的 destinationURL（强制 `.siz` 后缀）。
        //
        // 自动改后缀：用户在创建对话框里选的 destinationURL 可能是 `xxx.zip`；勾选「GPG 签名」
        // 后实际输出是 .siz 容器，所以这里把扩展名重写成 `siz`。
        try SIZArchive.validateCreationOptionsForSignedContainer(request.options)
        let sizDestination = request.destinationURL
            .deletingPathExtension()
            .appendingPathExtension(SIZArchive.extensionName)

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("SimpleZip-Sign-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let innerExtension = request.options.format.pathExtension
        let plaintextInnerName = "archive.\(innerExtension)"
        let plaintextInnerURL = staging.appendingPathComponent(plaintextInnerName)

        // Step 1：跑原本的 createArchive，目标改成 staging 里的 inner archive。
        var innerOptions = request.options
        innerOptions.gpgSign = false
        innerOptions.gpgSigningKeyFingerprint = ""
        innerOptions.gpgRecipientFingerprints = []
        try await ArchiveService.createArchive(
            from: request.sourceURLs,
            destination: plaintextInnerURL,
            options: innerOptions,
            operationID: operationID,
            progress: progress,
            outputObserver: outputObserver
        )

        // Step 2：（可选）多收件人加密 + / 或对称密码。SimpleZip v3 行为：
        // - 收件人 + 密码都空 → innerURL 仍是明文 archive，innerName 是 archive.<ext>（v2 兼容）；
        // - 任一非空 → 跑 gpg --[encrypt -r ...] [--symmetric --passphrase-fd 0] → archive.<ext>.gpg；innerName 跟着改。
        // 加密产物覆盖到 staging 后，明文 archive 立即删除（不留在临时目录里给攻击者捡）。
        let recipients = Array(Set(request.options.gpgRecipientFingerprints)).filter { !$0.isEmpty }
        let symmetricPassphrase = request.options.gpgSymmetricPassphrase.isEmpty
            ? nil
            : request.options.gpgSymmetricPassphrase
        let willEncrypt = !recipients.isEmpty || symmetricPassphrase != nil
        let innerURL: URL
        let innerName: String
        let encryptionInfo: SIZArchive.EncryptionInfo?
        if !willEncrypt {
            innerURL = plaintextInnerURL
            innerName = plaintextInnerName
            encryptionInfo = nil
        } else {
            let encryptedName = plaintextInnerName + ".gpg"
            let encryptedURL = staging.appendingPathComponent(encryptedName)
            // 把每个 recipient fingerprint 反查 keyring 拿 UID + 所在 ring。
            // listKeys 失败时 fall back 到「只有 fingerprint，没有 UID」的占位 RecipientInfo —— metadata 仍合法。
            let allKeys = recipients.isEmpty ? [] : ((try? await GPGBackend.listKeys()) ?? [])
            // 收件人全在 SimpleZip 私有环 → 加密走私有 `--homedir`，否则 gpg 在 ~/.gnupg 找不到这些公钥。
            // 混选两环已被创建对话框拦住（一次 gpg 加密只能用一个 homedir），到这里收件人同环。
            let recipientSources = Set(recipients.compactMap { fp in
                allKeys.first(where: { $0.fingerprint == fp })?.source
            })
            let recipientsUseSimpleZipKeyring = recipientSources == [.simpleZipKeyring]
            try await GPGBackend.encrypt(
                fileURL: plaintextInnerURL,
                recipients: recipients,
                symmetricPassphrase: symmetricPassphrase,
                outputURL: encryptedURL,
                useSimpleZipKeyring: recipientsUseSimpleZipKeyring,
                operationID: operationID
            )
            // 把明文从临时目录抹掉，最小化在磁盘上停留时间。
            try? FileManager.default.removeItem(at: plaintextInnerURL)
            let recipientInfos: [SIZArchive.RecipientInfo] = recipients.map { fp in
                let uid = allKeys.first(where: { $0.fingerprint == fp })?.userID ?? ""
                return SIZArchive.RecipientInfo(fingerprint: fp, userID: uid)
            }
            innerURL = encryptedURL
            innerName = encryptedName
            encryptionInfo = SIZArchive.EncryptionInfo(
                recipients: recipientInfos,
                algorithm: "gpg",
                hasSymmetricPassphrase: symmetricPassphrase != nil ? true : nil
            )
        }

        // Step 3：组装 metadata（含 inner SHA256；加密时 SHA 是**密文** SHA），签的是 metadata.json。
        // 选签名密钥的优先级：
        // 1) 用户在创建对话框 ask 模式里挑的密钥（options.gpgSigningKeyFingerprint，create sheet 默认 seed 到 prefs 默认值）
        // 2) AppPreferences.gpgDefaultSigningKeyFingerprint —— 给非对话框入口（Finder 服务等）走默认
        // 3) nil → 让 backend listKeys 兜底挑 first hasSecretKey
        let keyFingerprint: String? = {
            if !request.options.gpgSigningKeyFingerprint.isEmpty {
                return request.options.gpgSigningKeyFingerprint
            }
            let prefsDefault = AppPreferences.gpgDefaultSigningKeyFingerprint
            return prefsDefault.isEmpty ? nil : prefsDefault
        }()
        let signerKey: GPGBackend.GPGKey? = (try? await GPGBackend.listKeys())?.first(where: { key in
            if let keyFingerprint { return key.fingerprint == keyFingerprint }
            return key.hasSecretKey
        })
        let innerSHA256 = try SIZArchive.computeInnerArchiveSHA256(of: innerURL)
        var metadata = SIZArchive.Metadata(
            schema: SIZArchive.schemaIdentifier,
            version: SIZArchive.schemaVersion,
            innerArchiveName: innerName,
            innerFormat: innerExtension,
            originalArchiveName: request.destinationURL.deletingPathExtension().lastPathComponent + ".\(innerExtension)",
            innerArchiveSHA256: innerSHA256,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            createdBy: "SimpleZip \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            signature: SIZArchive.SignatureInfo(
                signerFingerprint: signerKey?.fingerprint ?? "",
                signerUserID: signerKey?.userID ?? "",
                armorFormat: true
            ),
            encryption: encryptionInfo
        )
        // #110 加密投递包：把人类可读的「收件人说明」灌进 metadata（→ 随 metadata.json 一起被签名 = 防篡改，
        // 且不动容器「只三个文件」防御）。必须在 encode/sign 之前设好,这样签名覆盖它。
        // 用户在创建对话框键入的留言(gpgDeliveryNote)作为说明最前面的「发送者留言」,也一并被签名。
        metadata.deliveryInstructions = SIZArchive.makeDeliveryInstructions(
            for: metadata,
            senderNote: request.options.gpgDeliveryNote
        )

        // Step 4：把 metadata 落到 staging（用同一个确定性 encoder 让 wrap 和签名字节一致），
        // 然后 gpg detached sign。gpg-agent + pinentry-mac 弹密码框，我们不碰 passphrase。
        let metadataForSigning = staging.appendingPathComponent(SIZArchive.metadataFileName)
        try SIZArchive.encodeMetadata(metadata).write(to: metadataForSigning, options: .atomic)
        let signatureURL = try await GPGBackend.sign(
            archiveURL: metadataForSigning,
            signingKeyFingerprint: keyFingerprint,
            // 签名密钥在 SimpleZip 私有环时用其独立 homedir,否则 ~/.gnupg 找不到这把私钥 → 签名失败。
            // `signerKey` 已从合并 listKeys() 解析出,直接看它的 source,无需 UI 另传。
            useSimpleZipKeyring: signerKey?.source == .simpleZipKeyring,
            operationID: operationID
        )

        // Step 5：tar wrap 成 .siz。wrap 内部会再次 encode 同一个 metadata，字节跟我们刚签的一致。
        try await SIZArchive.wrap(
            innerArchive: innerURL,
            signatureFile: signatureURL,
            metadata: metadata,
            outputURL: sizDestination
        )
    }
}
