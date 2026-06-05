//
//  SignedContainerService.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/02.
//
//  `.siz` 签名容器的「打开前编排」——unwrap → 验签 → 按需解密。**无 UI、无 model 依赖**，
//  只调 Core（SIZArchive / GPGBackend / AppPreferences）。
//
//  动机：这段逻辑原本内联在 `ContentView`，导致 `.siz` 打开被绑死在主窗口上。抽成 model-free 服务后，
//  主窗口路径（ContentView 浏览）和独立浮窗路径（Finder 自动解压脱钩主窗口）共用同一份编排，
//  不再各写一份（避免 DTO 套 DTO / 逻辑重复）。
//

import Foundation

/// `.siz` 容器打开/解压前的共享编排。纯静态、可跨 actor 调用（返回值均为 Sendable 值类型）。
enum SignedContainerService {
    /// unwrap `.siz` 到 /tmp 临时目录；若 `gpgEnabled` 开则跑 `SIZArchive.verify`（gpg 验签 + SHA 校验）。
    ///
    /// - Returns: `innerArchiveURL` 内层 archive；`tempRoot` unwrap 暂存根（调用方负责清理）；
    ///   `summary` —— nil 表示用户关了 GPG 集成（按规则隐藏所有 GPG UI），非 nil 供 sheet / 解压对话框展示。
    static func unwrapAndVerifySIZ(
        at sourceURL: URL
    ) async throws -> (innerArchiveURL: URL, tempRoot: URL, summary: SIZSignatureSummary?) {
        // **加密容器 → fail-closed**：unwrap 出来的内层档案（及随后内层 .gpg 解密产物）落进加密临时卷；
        // 卷挂不上就抛错，绝不把签名容器的内容明文裸落盘。
        let tempRoot = try await TemporaryResourceManager.makeSecureTemporaryDirectory(prefix: "SimpleZip-SIZ-Unwrap")
        let unwrap = try await SIZArchive.unwrap(at: sourceURL, to: tempRoot)

        // 用户关 GPG 集成 = 主页面所有 GPG 相关入口隐藏（打开 .siz 是刚需例外，但不能露 GPG UI）。
        guard AppPreferences.gpgEnabled else {
            return (unwrap.innerArchiveURL, tempRoot, nil)
        }

        // gpg 后端不可用时，等同于「gpg 验签失败」走 verificationError 一支。文案让用户知道是后端缺失。
        let verify: GPGBackend.GPGVerifyResult
        if GPGBackend.isAvailable() {
            do {
                verify = try await SIZArchive.verify(unwrap: unwrap)
            } catch {
                verify = .verificationError(message: error.localizedDescription)
            }
        } else {
            verify = .verificationError(message: L10n.text("siz.verify.gpgMissing.title"))
        }

        let storedSigner = unwrap.metadata.signature.signerUserID
        let displaySigner: String = {
            // 优先 gpg 返回的 signer（最新版本可能比 metadata 记录的更准）；否则退回 metadata；都没有就「未知」。
            if case .validSignature(let signer, _, _, _) = verify, let signer { return signer }
            if case .badSignature(let signer, _) = verify, let signer { return signer }
            return storedSigner.isEmpty ? L10n.text("siz.signatureSheet.unknownSigner") : storedSigner
        }()

        return (
            unwrap.innerArchiveURL,
            tempRoot,
            SIZSignatureSummary(
                sourceURL: sourceURL,
                signerDisplay: displaySigner,
                signerFingerprint: unwrap.metadata.signature.signerFingerprint,
                signedAt: unwrap.metadata.createdAt,
                verify: verify,
                encryption: unwrap.metadata.encryption,
                deliveryInstructions: unwrap.metadata.deliveryInstructions
            )
        )
    }

    /// `.siz` 签名是否「没问题」—— 用于 Finder 自动解压决定是否静默直解。
    /// - summary == nil：用户关了 GPG 集成，没有可校验的签名 → 视为「无问题」（按规则不弹 GPG UI，直接解压，刚需例外）。
    /// - 仅 `.validSignature` 且**受信任、无 concerns** 才算干净；坏签 / 未知签名者 / 验签错误 / 不受信 / 有 concerns
    ///   都算「有问题」→ 调用方落回正常验签 sheet 让用户决定。
    static func sizSignatureIsClean(_ summary: SIZSignatureSummary?) -> Bool {
        guard let summary else { return true }
        if case .validSignature(_, _, let trusted, let concerns) = summary.verify {
            return trusted && concerns.isEmpty
        }
        return false
    }

    /// 内层 archive 若是加密包（`.gpg` 后缀）→ 走 `SIZArchive.decryptInnerArchive`；否则原样返回。
    /// - `decryptionKey` / `passphrase` 为 nil 时让 gpg-agent + pinentry-mac 兜底，二者非 nil 时优先用（loopback 模式）。
    /// - 后缀检查 `.lowercased()` 容错：自家 wrap 总小写但跨平台 / 手工拼包的 `.siz` 内层可能写 `archive.zip.GPG` 大写。
    static func decryptInnerArchiveIfNeeded(
        _ innerArchiveURL: URL,
        decryptionKey: String? = nil,
        passphrase: String? = nil
    ) async throws -> URL {
        guard innerArchiveURL.lastPathComponent.lowercased().hasSuffix(".gpg") else { return innerArchiveURL }
        return try await SIZArchive.decryptInnerArchive(
            encryptedURL: innerArchiveURL,
            decryptionKeyFingerprint: decryptionKey,
            passphrase: passphrase
        )
    }
}
