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
        var producedURLs: [URL] = []
        // 标题带信息：单个 → 「正在加密 a.txt」；多选 → 「正在加密 3 项」。产物名等成功后从 producedURLs 拿。
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
            refreshOnSuccess: { [weak self] in
                guard let self, let first = producedURLs.first else { return }
                self.status = producedURLs.count == 1
                    ? L10n.format("status.gpgEncrypted", first.lastPathComponent)
                    : L10n.format("status.gpgEncryptedMultiple", "\(producedURLs.count)")
                // 产物就在当前浏览的文件夹里 —— 只刷新当前视图让它出现在列表，并把光标落到第一个产物。
                // **绝不**调 NSWorkspace 把 Finder 拉到前台（与创建压缩包流程一致，全程留在 app 内）。
                self.pendingSelectionURL = first.standardizedFileURL
                self.refreshVisibleFolder(containing: first)
            },
            onSucceeded: { task in
                // 活动中心展开后显示「新增：<产物>.gpg」（逐个加密时是多条）——给「正在加密」真实的结果密度。
                task.transferLog = producedURLs.map {
                    TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false)
                }
            }
        ) { operationID, _, _ in
            let urls = try await GPGFileService.encryptToGPG(
                sources: request.sourceURLs,
                in: request.directoryURL,
                recipients: request.recipientFingerprints,
                symmetricPassphrase: request.symmetricPassphrase.isEmpty ? nil : request.symmetricPassphrase,
                perFile: request.perFile,
                useSimpleZipKeyring: request.useSimpleZipKeyring,
                operationID: operationID
            )
            producedURLs = urls
        }
    }

    /// 粗判一个解密错误是否来自「用户取消 pinentry」——gpg / pinentry 取消时报文里通常含 cancel/abort 字样。
    /// 命中即静默（取消是用户主动动作，不该弹错误框）。判不准时宁可漏判（仍报错），不误吞真失败。
    private static func errorLooksLikeUserCancellation(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("cancel") || text.contains("operation cancelled") || text.contains("abort")
    }
}
