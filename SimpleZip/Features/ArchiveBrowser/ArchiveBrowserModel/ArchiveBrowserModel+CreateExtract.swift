//
//  ArchiveBrowserModel+CreateExtract.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  创建压缩包 / 解压压缩包 / 选择项目解压 / 单项目在外部打开 / 单项目导出 / SIZ 签名 wrap。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension ArchiveBrowserModel {
    func openArchiveItemExternally(_ item: ArchiveItem) {
        guard case .archive(let archiveURL) = mode else { return }

        if ArchiveSafety.requiresExternalOpenConfirmation(item), !allowPotentiallyUnsafeArchiveItemOpen(item) {
            return
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else { return }
        let detectedZipEncryption = archiveURL.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: archiveURL)
            : .unknown
        let shouldPromptBeforeExtraction = ArchiveService.archiveItemsSuggestPasswordRequirement(entries, in: archiveURL)

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            var extractedDiskImageURL: URL?
            var extractedNestedArchiveURL: URL?
            let didSucceed = await runArchiveTask(L10n.format("status.openingArchiveItem", item.displayName)) { progress in
                let destination = try self.makeArchiveItemOpenDirectory()
                self.openedArchiveItemDirectories.append(destination)
                try self.confirmArchiveExtractionSafety(entries: entries)
                // 预设密码可用时把它作为首选 —— 这样用户不必看到弹窗（除非预设是错的）。
                // 没有预设时 password 仍是空字符串，原本「先弹窗再尝试」的路径完整保留。
                let hasPreset = AppPreferences.hasUsablePresetPassword
                var password = hasPreset ? AppPreferences.presetPassword : ""
                var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
                var isRetry = false

                if shouldPromptBeforeExtraction && !hasPreset {
                    guard let authentication = self.promptForArchiveItemPassword(
                        item: item,
                        archiveURL: archiveURL,
                        detectedZipEncryption: detectedZipEncryption,
                        isRetry: false
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }

                let force = self.isForced(archiveURL)
                while true {
                    do {
                        try? self.fileManager.removeItem(at: destination)
                        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                        try await ArchiveService.extract(
                            archiveURL,
                            entries: entries,
                            to: destination,
                            overwriteBehavior: .overwrite,
                            pathMode: .preserve,
                            password: password,
                            zipDecryptionMethod: zipDecryptionMethod,
                            safetyPolicy: .skipValidation,
                            operationID: operationID,
                            progress: progress,
                            force: force
                        )
                        try self.confirmExtractedArchiveLinks(at: destination)

                        let extractedURL = try self.extractedURL(for: item, in: destination)
                        if extractedURL.pathExtension.lowercased() == "dmg" {
                            extractedDiskImageURL = extractedURL
                            return
                        }
                        // **嵌套压缩包的固有问题修复**：解出来的项本身又是受支持压缩包（zip 套 zip、tgz 里的 tar、
                        // 7z 套 tar…）→ 在 app 内打开，**绝不**走 NSWorkspace.open。后者把 /tmp 里的临时档案当外部
                        // 文件按 UTI 转回 SimpleZip → openArchive 拿到的是 /tmp 路径且无 displayedAs → 地址栏 + 上一级
                        // 全暴露 `/var/folders/...`（dmg 必须在此判断**之前**拦掉，它也算 supportedArchive 但走挂载）。
                        if ArchiveService.isSupportedArchive(extractedURL) {
                            extractedNestedArchiveURL = extractedURL
                            return
                        }
                        guard NSWorkspace.shared.open(extractedURL) else {
                            throw ArchiveError.openExtractedItemFailed
                        }
                        return
                    } catch {
                        guard self.shouldPromptForArchivePassword(error) else {
                            throw error
                        }
                        guard let authentication = self.promptForArchiveItemPassword(
                            item: item,
                            archiveURL: archiveURL,
                            detectedZipEncryption: detectedZipEncryption,
                            isRetry: isRetry
                        ) else {
                            throw CancellationError()
                        }
                        password = authentication.password
                        zipDecryptionMethod = authentication.zipDecryptionMethod
                        isRetry = true
                    }
                }
            }
            if didSucceed {
                if let extractedDiskImageURL {
                    openDiskImage(extractedDiskImageURL)
                } else if let extractedNestedArchiveURL {
                    // 在 app 内浏览嵌套档案：地址栏把整条虚拟链堆叠出来（`…/xx.zip/xa/a.zip`），
                    // 「上一级」退出整条链回到最外层档案所在的真实文件夹，全程不露 /tmp。
                    openNestedArchive(extractedNestedArchiveURL, entryName: item.name)
                } else {
                    status = L10n.format("status.openedArchiveItem", item.displayName)
                }
            }
        }
    }

    func exportArchiveItem(_ item: ArchiveItem, to destinationFolder: URL) async throws {
        guard case .archive(let archiveURL) = mode else {
            throw ArchiveError.unsupportedFormat
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else {
            throw ArchiveError.extractedItemNotFound
        }

        status = L10n.format("status.exportingArchiveItem", item.displayName)
        let stagingURL = try extractionCoordinator.makeExtractionStagingDirectory()
        defer { try? fileManager.removeItem(at: stagingURL) }

        try confirmArchiveExtractionSafety(entries: entries)
        try await ArchiveService.extract(
            archiveURL,
            entries: entries,
            to: stagingURL,
            overwriteBehavior: .overwrite,
            pathMode: .preserve,
            safetyPolicy: .skipValidation,
            force: isForced(archiveURL)
        )
        try confirmExtractedArchiveLinks(at: stagingURL)

        let extractedURL = try extractedURL(for: item, in: stagingURL)
        let destinationURL = destinationFolder.appendingPathComponent(item.displayName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw ArchiveError.exportDestinationExists
        }
        try fileManager.moveItem(at: extractedURL, to: destinationURL)
        status = L10n.format("status.exportedArchiveItem", item.displayName)
    }

    func createArchive() {
        guard case .folder(let currentFolder) = mode else {
            errorMessage = L10n.text("error.openFolderFirst")
            return
        }

        let items = selectedFileItems
        guard !items.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let destination = currentFolder.appendingPathComponent(defaultArchiveName(for: items.map(\.url)))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: items.map(\.url), directoryURL: currentFolder, destinationURL: destination)
    }

    func createArchive(fromFinderURLs urls: [URL]) {
        let fileURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !fileURLs.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let parentDirectory = fileURLs[0].deletingLastPathComponent()
        let destination = parentDirectory.appendingPathComponent(defaultArchiveName(for: fileURLs))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: fileURLs, directoryURL: parentDirectory, destinationURL: destination)
    }

    func performCreateArchive(_ request: ArchiveCreationRequest) {
        // 勾选 GPG 签名 → 实际输出会被改名成 `<name>.siz` —— title 也跟着用最终文件名，
        // 避免长任务面板显示「正在创建 1.zip」但实际产物是 1.siz 的违和。
        let finalDestination = request.options.gpgSign
            ? request.destinationURL.deletingPathExtension().appendingPathExtension(SIZArchive.extensionName)
            : request.destinationURL
        let title = L10n.format("status.creating", finalDestination.lastPathComponent)
        startManagedArchiveTask(
            title: title,
            kind: .compress,
            showsDetails: request.options.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(containing: finalDestination)
            }
        ) { operationID, progress, outputObserver in
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
                try await GPGBackend.encrypt(
                    fileURL: plaintextInnerURL,
                    recipients: recipients,
                    symmetricPassphrase: symmetricPassphrase,
                    outputURL: encryptedURL,
                    operationID: operationID
                )
                // 把明文从临时目录抹掉，最小化在磁盘上停留时间。
                try? FileManager.default.removeItem(at: plaintextInnerURL)
                // 把每个 recipient fingerprint 反查 keyring 拿 UID，metadata 里同时记 fp + UID 给 UI 显示。
                // listKeys 失败时 fall back 到「只有 fingerprint，没有 UID」的占位 RecipientInfo —— metadata 仍合法。
                let allKeys = recipients.isEmpty ? [] : ((try? await GPGBackend.listKeys()) ?? [])
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
            let metadata = SIZArchive.Metadata(
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

            // Step 4：把 metadata 落到 staging（用同一个确定性 encoder 让 wrap 和签名字节一致），
            // 然后 gpg detached sign。gpg-agent + pinentry-mac 弹密码框，我们不碰 passphrase。
            let metadataForSigning = staging.appendingPathComponent(SIZArchive.metadataFileName)
            try SIZArchive.encodeMetadata(metadata).write(to: metadataForSigning, options: .atomic)
            let signatureURL = try await GPGBackend.sign(
                archiveURL: metadataForSigning,
                signingKeyFingerprint: keyFingerprint,
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

    func extractFromCurrentContext() {
        if case .archive = mode, !selectedArchiveItems.isEmpty {
            extractSelectedArchiveItems()
        } else {
            extractArchive()
        }
    }

    func extractArchive() {
        // 文件浏览器里选中 `.siz` + 点 Extract —— `.siz` 不在 `supportedExtensions` 里（ArchiveService
        // 不直接处理 tar 壳），所以特判走 @Published 状态给 ContentView 跑「unwrap + 验签 + 标准解压对话框」。
        if case .folder = mode,
           let sizURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SIZArchive.extensionName })?.url {
            pendingSIZExtract = sizURL
            return
        }
        // `.szs` 不是压缩包 —— 解压语义不适用。改成弹 alert 解释，附「以虚拟目录浏览」按钮把用户引到正确流程。
        if case .folder = mode,
           let szsURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SZSArchive.extensionName })?.url {
            pendingSZSExtractHint = szsURL
            return
        }

        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        // 预设密码开启时 request 的初始密码就填好；ExtractOptionsForm 那一头会同时把
        // 「使用预设密码」复选框默认勾上 —— 用户不需要在偏好和对话框两处再点一遍。
        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractArchiveRequest = ExtractArchiveRequest(
            archiveURL: archiveURL,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    /// 解压默认目标路径 —— 普通 archive 用自身父目录；`.siz` 打开内层时 archiveURL 是 /tmp 路径，
    /// 这时回退到 `archiveDisplayOverride`（=原始 .siz 文件路径）的父目录，
    /// 用户期望的「桌面 / 下载」目录，而不是 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-xxx/`。
    private func defaultExtractDestination(for archiveURL: URL) -> URL {
        if let displayed = archiveDisplayOverride {
            return displayed.deletingLastPathComponent()
        }
        return archiveURL.deletingLastPathComponent()
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        let title = L10n.format("status.extracting", request.archiveURL.lastPathComponent)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            // `.siz` v3 加密前置：如果是加密的内层 archive（`.gpg` 后缀 + sizSignature 带 encryption），
            // 先用 gpg --decrypt 出明文 sibling 文件，再走原本的 ArchiveService.extract 路径。
            // 用 defer 把解密产物在任务结束时抹掉，避免明文长期留在 /tmp。
            // **后缀检查 `.lowercased()`**：容错跨平台 / 手工拼包的 `.GPG` 大写。
            let archiveURLForExtract: URL
            let decryptedSiblingToCleanup: URL?
            if request.sizSignature?.encryption != nil,
               request.archiveURL.lastPathComponent.lowercased().hasSuffix(".gpg") {
                do {
                    archiveURLForExtract = try await SIZArchive.decryptInnerArchive(
                        encryptedURL: request.archiveURL,
                        decryptionKeyFingerprint: request.gpgDecryptionKeyFingerprint.isEmpty ? nil : request.gpgDecryptionKeyFingerprint,
                        passphrase: request.gpgDecryptionPassphrase.isEmpty ? nil : request.gpgDecryptionPassphrase,
                        operationID: operationID
                    )
                    decryptedSiblingToCleanup = archiveURLForExtract
                } catch {
                    throw ArchiveError.commandFailed(L10n.format("error.siz.decryptionFailed", error.localizedDescription))
                }
            } else {
                archiveURLForExtract = request.archiveURL
                decryptedSiblingToCleanup = nil
            }
            defer {
                if let toCleanup = decryptedSiblingToCleanup {
                    try? self.fileManager.removeItem(at: toCleanup)
                }
            }

            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            // 安全检查只跑一次 —— 第一次 list 成功后置 true，后续 retry 不重复跑 NSAlert。
            // 旧版本把这步放在循环外，对 header-encrypted 7z 用空密码 list 直接失败，
            // 用户根本进不到下面的密码 prompt。
            var didCheckSafety = false
            // 安全检查 list 出的文件数 —— 复用给 ArchiveService.extract 的 knownFileCount，省掉解压时再 list 一遍。
            var knownFileCount: Int?
            while true {
                do {
                    if !didCheckSafety {
                        let items = try await self.confirmArchiveExtractionSafety(
                            archiveURL: archiveURLForExtract,
                            password: password,
                            operationID: operationID,
                            force: force
                        )
                        knownFileCount = items.filter { !$0.isDirectory }.count
                        didCheckSafety = true
                    }
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        archiveURLForExtract,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        knownFileCount: knownFileCount,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: archiveURLForExtract,
                        displayName: request.archiveURL.lastPathComponent,
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { status in
                progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status))
            } updateProgress: { mergeProgress in
                progress(mergeProgress)
            }
        }
    }

    func extractSelectedArchiveItems() {
        guard case .archive(let archiveURL) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let entries = expandedSelectedArchiveItems()
        guard !entries.isEmpty else {
            errorMessage = L10n.text("error.selectArchiveItemsToExtract")
            return
        }

        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractSelectionRequest = ExtractSelectionRequest(
            archiveURL: archiveURL,
            entries: entries,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        let title = L10n.format("status.extractingSelected", request.entries.count)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            try self.confirmArchiveExtractionSafety(entries: request.entries)
            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            while true {
                do {
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        request.archiveURL,
                        entries: request.entries,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        pathMode: request.pathMode,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: request.archiveURL,
                        displayName: L10n.format("status.extractingSelected", request.entries.count),
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { status in
                progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status))
            } updateProgress: { mergeProgress in
                progress(mergeProgress)
            }
        }
    }

    /// 「右键 → 创建签名清单」入口：把当前选中的 file URL 集合 + 推断出的 payload root 发到 ContentView 弹 CreateSZSSheet。
    /// payload root 推断：所有选中文件的最深公共祖先目录。多选时如果分散在不同父目录，公共祖先可能是 `/` 之类的祖先 —— UI 仍然
    /// 让用户在 sheet 里改 payload root（默认值即可），不强制走推断结果。
    func createSignedManifest() {
        let urls = selectedFileItems.map(\.url)
        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        let inferredRoot = Self.commonAncestorDirectory(for: urls) ?? urls.first!.deletingLastPathComponent()
        pendingCreateSZS = CreateSZSPrefill(payloadRoot: inferredRoot, files: urls)
    }

    /// 算 URL 集合的最深公共祖先目录（用于推断 payload root）。
    /// 如果集合空 → nil；单个文件 → 其父目录。
    static func commonAncestorDirectory(for urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let paths = urls.map { $0.standardizedFileURL.deletingLastPathComponent().pathComponents }
        // 逐层比对，找最长共同前缀。
        var prefix: [String] = []
        outer: for i in 0..<(paths.first?.count ?? 0) {
            let comp = paths[0][i]
            for p in paths.dropFirst() {
                if i >= p.count || p[i] != comp { break outer }
            }
            prefix.append(comp)
        }
        guard prefix.count > 1 else { return URL(fileURLWithPath: "/") } // 只剩根 → /
        // pathComponents 第一个是 "/"，URL 还原时不能简单 joined；走 NSString 拼接。
        let joined = (prefix as NSArray).componentsJoined(by: "/")
            .replacingOccurrences(of: "//", with: "/")
        return URL(fileURLWithPath: joined)
    }

    private func defaultArchiveName(for urls: [URL]) -> String {
        if urls.count == 1 {
            return urls[0].deletingPathExtension().lastPathComponent + ".zip"
        }
        return "Archive.zip"
    }

    /// 选中压缩包内目录时，展开成目录下所有项目，避免后端只收到目录占位项。
    func expandedSelectedArchiveItems() -> [ArchiveItem] {
        session.expand(selectedArchiveItems)
    }

    func expandedArchiveItems(for item: ArchiveItem) -> [ArchiveItem] {
        session.expand(item)
    }

    func isOpenableArchiveDirectoryPackage(_ item: ArchiveItem) -> Bool {
        guard item.isDirectory else { return false }
        let ext = URL(fileURLWithPath: item.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .applicationBundle)
    }

    private func makeArchiveItemOpenDirectory() throws -> URL {
        try TemporaryResourceManager.makeOpenedArchiveItemDirectory(fileManager: fileManager)
    }

    private func extractedURL(for item: ArchiveItem, in destination: URL) throws -> URL {
        let relativePath = item.isDirectory
            ? ArchiveSession.normalizedDirectoryPrefix(item.name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : ArchiveSession.normalizedEntryName(item.name, isDirectory: false)
        let expectedURL = destination.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }

        if let fallbackURL = firstExtractedURL(named: item.displayName, in: destination) {
            return fallbackURL
        }
        throw ArchiveError.extractedItemNotFound
    }

    private func firstExtractedURL(named fileName: String, in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }
}
