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
                if ArchiveService.isSupportedArchive(decrypted) {
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

    /// 粗判一个解密错误是否来自「用户取消 pinentry」——gpg / pinentry 取消时报文里通常含 cancel/abort 字样。
    /// 命中即静默（取消是用户主动动作，不该弹错误框）。判不准时宁可漏判（仍报错），不误吞真失败。
    private static func errorLooksLikeUserCancellation(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("cancel") || text.contains("operation cancelled") || text.contains("abort")
    }
}
