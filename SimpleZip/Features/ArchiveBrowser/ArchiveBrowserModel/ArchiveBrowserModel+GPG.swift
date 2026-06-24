//
//  ArchiveBrowserModel+GPG.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  双击打开 `.gpg`/`.pgp`/`.asc` 的 model 侧编排：嗅探分类 → 解密（带进度反馈 / 取消静默）→ 在 app 内路由。
//
//  为什么放 model 而不是 View：解密是一段需要「进度状态 + 可取消 + 错误归一」的真·操作，和挂载 DMG / 打开
//  archive 同级。放 ContentView 里裸跑会缺状态反馈（用户看不到「解密中」）、错误信息也容易写岔。
//

import Foundation

extension ArchiveBrowserModel {
    /// 打开一个 `.gpg`/`.pgp`/`.asc` 文件。门控、嗅探、路由全在这里。
    ///
    /// **嗅探瞬时**（`classifyFile` 只读包头，不起 gpg、不弹密码）：
    /// - 公钥 / 私钥 → 弹导入 sheet（`pendingGPGKeyImport`），**不解密**；
    /// - 加密数据 → `decryptAndOpenGPG`（带「解密中」状态 + 解密后在 app 内浏览）；
    /// - 签名 / clearsign / 无法识别 → 提示「不是加密数据」。
    func openGPGFile(_ url: URL) {
        guard AppPreferences.gpgEnabled else {
            errorMessage = L10n.text("gpgFile.disabled.message")
            return
        }
        guard GPGBackend.isAvailable() else {
            errorMessage = L10n.text("gpgFile.backendMissing.message")
            return
        }
        let kind = GPGBackend.classifyFile(at: url)
        switch kind {
        case .publicKey, .privateKey:
            pendingGPGKeyImport = GPGKeyImportRequest(sourceURL: url, isPrivateKey: kind == .privateKey)
        case .encryptedMessage:
            decryptAndOpenGPG(url)
        case .detachedSignature, .clearSigned, .unknown:
            errorMessage = L10n.text("gpgFile.notDecryptable.message")
        }
    }

    /// 解密加密数据并在 app 内打开。**全程显示「解密中」状态**（pinentry 弹密码时用户也能看到 app 在等授权）；
    /// 用户取消 passphrase → 静默返回（不弹错误）；真失败 → 归一成「无法解密」错误。
    private func decryptAndOpenGPG(_ url: URL) {
        status = L10n.format("status.gpgDecrypting", url.lastPathComponent)
        isWorking = true
        Task { @MainActor in
            do {
                let decrypted = try await GPGFileService.decryptToTemporary(url)
                // 登记解密根（卷内临时目录）—— 离开这个 .gpg 档案（退到真实目录 / 开别的真实档案）时即时清掉。
                registerOpenedArchiveItemTemp(decrypted.deletingLastPathComponent())
                // 解密完成 —— 把 isWorking 交还给随后的 openArchive / openFolder（它们各自的 reload 会重新置位）。
                isWorking = false
                if decrypted.pathExtension.lowercased() == SIZArchive.extensionName {
                    // 内层是 `.siz` 签名容器 → 走完整 unwrap + 验签流程（篡改会被验签拦住！），
                    // **地址锚点设成原始 `.gpg`**，否则会暴露解出来的 `.siz` 的 /var/folders scratch 路径。
                    pendingSIZOpen = SIZOpenRequest(url: decrypted, displayOverride: url)
                } else if ArchiveService.isSupportedArchive(decrypted) {
                    // 内层是压缩包 → 和 `.siz` 内层 archive 完全一样地浏览（标题/地址栏显示原 `.gpg`）。
                    openArchive(decrypted, displayedAs: url)
                } else {
                    // 普通文件 → 复用 `.szs` 虚拟目录机制在 app 内展示（不丢 Finder）。
                    openDecryptedFileAsVirtualFolder(decrypted, displayedAs: url)
                }
            } catch is CancellationError {
                isWorking = false
                status = ""
            } catch {
                isWorking = false
                status = ""
                // pinentry 取消（用户放弃输入密码）→ 静默，不弹「失败」吓人。其它失败才报错。
                if Self.errorLooksLikeUserCancellation(error) {
                    return
                }
                errorMessage = L10n.format("gpgFile.decryptFailed", error.localizedDescription)
            }
        }
    }

    /// 0.4.2：.gpg 解压确认请求（非 nil = 弹对话框）。不能静默解压 ——
    /// 解压前给正规对话框：看清产物名、可改目标目录。
    struct GPGExtractRequest: Identifiable {
        let id = UUID()
        let url: URL
        var destinationURL: URL
        /// 解密产物文件名（剥一层 .gpg/.asc 后缀）。
        var productName: String { GPGFileService.decryptedInnerName(for: url) }
    }

    // MARK: - .gpg「解压到此」（0.4.2）

    /// 文件浏览里对 `.gpg`/`.pgp`/`.asc` 点「解压」：解密产物落在源文件**旁边**（同名先到先得、
    /// 重名自动编号，绝不覆盖）。嗅探分类与双击打开同源：钥匙串材料 → 导入 sheet；非加密数据 → 明确报错。
    func extractGPGFileHere(_ url: URL) {
        guard AppPreferences.gpgEnabled else {
            errorMessage = L10n.text("gpgFile.disabled.message")
            return
        }
        guard GPGBackend.isAvailable() else {
            errorMessage = L10n.text("gpgFile.backendMissing.message")
            return
        }
        switch GPGBackend.classifyFile(at: url) {
        case .publicKey:
            pendingGPGKeyImport = GPGKeyImportRequest(sourceURL: url, isPrivateKey: false)
        case .privateKey:
            pendingGPGKeyImport = GPGKeyImportRequest(sourceURL: url, isPrivateKey: true)
        case .encryptedMessage:
            // 0.4.2 不静默解 —— 弹解压对话框（产物名 + 可改目标目录）再动手。
            gpgExtractRequest = GPGExtractRequest(url: url, destinationURL: url.deletingLastPathComponent())
        case .detachedSignature, .clearSigned, .unknown:
            errorMessage = L10n.text("gpgFile.notDecryptable.message")
        }
    }

    /// 执行解密落盘：先解到加密临时卷（fail-closed），成功后才移到 `destination` —— 半截失败不会留下半个明文。
    /// 用户在 pinentry 取消 → 任务按取消收尾（不报失败）。
    func runGPGExtract(_ url: URL, to destination: URL) {
        var product: URL?
        startManagedArchiveTask(
            title: L10n.format("status.gpgDecrypting", url.lastPathComponent),
            kind: .extract,
            showsDetails: false,
            successStatus: nil,
            // #3 产物:解密落盘后的明文文件(操作内唯一化定名,成功时 product 已填)。
            successOutputURL: { product },
            refreshOnSuccess: { [weak self] in
                guard let self, let product else { return }
                self.status = L10n.format("status.gpgExtracted", product.lastPathComponent)
                // 产物落在当前浏览目录时刷新视图并把光标落上去（不拉起 Finder,与加密流程一致）。
                self.pendingSelectionURL = product.standardizedFileURL
                self.refreshVisibleFolder(containing: product)
            },
            onSucceeded: { task in
                if let product {
                    task.transferLog = [TransferLogEntry(name: product.lastPathComponent, action: .added, isDirectory: false)]
                }
            },
            rerunAction: { [weak self] in self?.runGPGExtract(url, to: destination) }
        ) { operationID, _, _ in
            // 解密中转仍在加密临时卷（fail-closed）；明文落到用户确认过的目标目录是明确意图。
            let decrypted: URL
            do {
                decrypted = try await GPGFileService.decryptToTemporary(url, operationID: operationID)
            } catch where Self.errorLooksLikeUserCancellation(error) {
                // pinentry 取消是用户主动动作 —— 映射成任务取消，不在活动中心标红「失败」。
                throw CancellationError()
            }
            let fm = FileManager.default
            let desired = destination.appendingPathComponent(decrypted.lastPathComponent)
            let target = fm.fileExists(atPath: desired.path)
                ? UniqueFileName.suffixed(for: desired, suffix: "", exists: { fm.fileExists(atPath: $0.path) })
                : desired
            try fm.moveItem(at: decrypted, to: target)
            await MainActor.run { product = target }
        }
    }

    /// 右键「加密为 .gpg」：门控 + 取选区 → 弹 GPGEncryptOptionsView（收件人 / 对称密码）。
    /// 仅 gpgEnabled + 后端可用时可达（菜单项本身也按 A4 门控，不渲染时进不来）。
    func encryptSelectionToGPG() {
        guard AppPreferences.gpgEnabled else {
            errorMessage = L10n.text("gpgFile.disabled.message")
            return
        }
        guard GPGBackend.isAvailable() else {
            errorMessage = L10n.text("gpgFile.backendMissing.message")
            return
        }
        guard case .folder(let currentFolder) = mode else {
            errorMessage = L10n.text("error.openFolderFirst")
            return
        }
        let items = selectedFileItems
        guard !items.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }
        gpgEncryptRequest = GPGEncryptRequest(sourceURLs: items.map(\.url), directoryURL: currentFolder)
    }

    /// 执行加密为 `.gpg`：走 startManagedArchiveTask（进度 / 活动中心 / 可取消），完成后刷新当前文件夹
    /// 并在 Finder 里选中产物。folder/多选会先 tar 进加密临时卷再加密（GPGFileService.encryptToGPG）。
    func performEncryptToGPG(_ request: GPGEncryptRequest) {
        var result: GPGFileService.EncryptResult?
        // 标题带信息：单个 → 「正在加密 a.txt」；多选 → 「正在加密 3 项」。产物名等成功后从 result 拿。
        let title: String
        if request.sourceURLs.count == 1 {
            title = L10n.format("status.gpgEncrypting", request.sourceURLs[0].lastPathComponent)
        } else {
            title = L10n.format("status.gpgEncryptingMultiple", "\(request.sourceURLs.count)")
        }
        startManagedArchiveTask(
            title: title,
            kind: .compress,
            showsDetails: false,
            successStatus: nil,
            // #3 产物:首个加密产物 .gpg(批量时其余在 transferLog;命中精确反查用第一个即可)。
            successOutputURL: { result?.produced.first },
            refreshOnSuccess: { [weak self] in
                guard let self, let result, let first = result.produced.first else { return }
                let produced = result.produced.count
                if result.failures.isEmpty {
                    self.status = produced == 1
                        ? L10n.format("status.gpgEncrypted", first.lastPathComponent)
                        : L10n.format("status.gpgEncryptedMultiple", "\(produced)")
                } else {
                    // 部分成功 → 状态栏明确写「成功 N，失败 M」，别让用户以为全成了。
                    self.status = L10n.format("status.gpgEncryptedPartial", "\(produced)", "\(result.failures.count)")
                }
                // 产物就在当前浏览的文件夹里 —— 只刷新当前视图让它出现在列表，并把光标落到第一个产物。
                // **绝不**调 NSWorkspace 把 Finder 拉到前台（与创建压缩包流程一致，全程留在 app 内）。
                self.pendingSelectionURL = first.standardizedFileURL
                self.refreshVisibleFolder(containing: first)
            },
            onSucceeded: { [weak self] task in
                guard let result else { return }
                // 活动中心展开后显示「新增：<产物>.gpg」+ 失败项（红色 + 原因）——给批量加密真实的结果密度。
                var log = result.produced.map {
                    TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false)
                }
                log += result.failures.map {
                    TransferLogEntry(name: $0.source.lastPathComponent, action: .failed, isDirectory: false, detail: $0.reason)
                }
                task.transferLog = log
                // 有失败项 → 挂「重试失败项」：用同样的收件人 / 密码 / 模式，只对失败的源重跑。
                if !result.failures.isEmpty {
                    let failedSources = result.failures.map(\.source)
                    task.retryFailed = { [weak self] in
                        guard let self else { return }
                        var retry = GPGEncryptRequest(sourceURLs: failedSources, directoryURL: request.directoryURL)
                        retry.recipientFingerprints = request.recipientFingerprints
                        retry.symmetricPassphrase = request.symmetricPassphrase
                        retry.perFile = request.perFile
                        retry.useSimpleZipKeyring = request.useSimpleZipKeyring
                        self.performEncryptToGPG(retry)
                    }
                }
            }
        ) { operationID, _, _ in
            result = try await GPGFileService.encryptToGPG(
                sources: request.sourceURLs,
                in: request.directoryURL,
                recipients: request.recipientFingerprints,
                symmetricPassphrase: request.symmetricPassphrase.isEmpty ? nil : request.symmetricPassphrase,
                perFile: request.perFile,
                useSimpleZipKeyring: request.useSimpleZipKeyring,
                operationID: operationID
            )
        }
    }

    /// 粗判一个解密错误是否来自「用户取消 pinentry」——gpg / pinentry 取消时报文里通常含 cancel/abort 字样。
    /// 命中即静默（取消是用户主动动作，不该弹错误框）。判不准时宁可漏判（仍报错），不误吞真失败。
    private static func errorLooksLikeUserCancellation(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("cancel") || text.contains("operation cancelled") || text.contains("abort")
    }
}
