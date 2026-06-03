//
//  ExtractArchiveOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/13.
//

import SwiftUI

/// 整包解压前的选项面板：目标目录和可选密码。
struct ExtractArchiveOptionsView: View {
    @State var request: ExtractArchiveRequest
    let extract: (ExtractArchiveRequest) -> Void
    let cancel: () -> Void
    /// 用户可用于解密的私钥（hasSecretKey）。GPG 启用 + 后端可用时 onAppear 异步加载。
    @State private var availableSecretKeys: [GPGBackend.GPGKey] = []

    var body: some View {
        ExtractOptionsForm(
            title: L10n.text("extract.archive.title"),
            destinationURL: $request.destinationURL,
            password: $request.password,
            zipDecryptionMethod: $request.zipDecryptionMethod,
            showDetails: $request.showDetails,
            showsZipDecryptionMethod: request.archiveURL.pathExtension.lowercased() == "zip",
            zipEncryptionDetectionText: request.detectedZipEncryption.autoDetectionText,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            // `.siz` 直接解压时多三行：签名状态 / 签名时间 / 签名指纹。普通归档时为 nil，extraControls 为空。
            if let signature = request.sizSignature {
                SIZSignatureRows(signature: signature)
            }
            // GPG 解密密钥 picker —— **仅 `.siz` 解压时显示**。
            // 因为只有 SimpleZip 专有 `.siz` v3 会用 GPG 多收件人加密内层 archive；
            // 通用 zip / 7z / rar / tar 等格式不支持 GPG 非对称加密，picker 出现是噪音。
            if isSizExtract && AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                gpgDecryptionKeyRow
                // 加密 .siz 且带对称密码时，多一个 SecureField 让用户填 GPG 解密密码。
                // 0.1.9 的关键 UX：跟内层 ZIP/7z 的加密密码（password 字段）**完全独立** —— 它俩可能是两份不同密码。
                if request.sizSignature?.encryption?.hasSymmetricPassphrase == true {
                    gpgDecryptionPassphraseRow
                }
            }
        }
        .frame(width: 540)
        .onAppear {
            // 仅 .siz 才需要载入密钥列表 —— 通用格式 picker 不显示，省一次 listKeys 调用。
            if isSizExtract && AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                Task { @MainActor in
                    if let loaded = try? await GPGBackend.listKeys() {
                        availableSecretKeys = loaded.filter { $0.hasSecretKey }
                    }
                }
            }
        }
    }

    /// 是否在解压 `.siz` 单文件签名容器 —— 决定 GPG 解密密钥 picker 是否出现。
    /// **判定靠 `sizSignature` 而不是文件扩展名** —— 解压时 `request.archiveURL` 是 unwrap 后的内层 archive（archive.zip / archive.zip.gpg），
    /// 后缀已经不是 `.siz`；只有 `.siz` 走 unwrapAndVerifySIZ 时才会把 sizSignature 塞进 request。
    /// 历史 bug（0.1.8 落地以来一直存在）：旧版用 archiveURL 扩展名判，导致 .siz 解压时 picker 一直没显示。
    private var isSizExtract: Bool {
        request.sizSignature != nil
    }

    /// 解密密钥 picker —— Menu 风格，跟创建对话框签名密钥 picker 视觉对齐。
    /// 首项「让 GPG 自动选」对应空 fingerprint = gpg 按 keyring 自己选合适的私钥（GPG 加密元数据里都会标 recipient key id）。
    @ViewBuilder
    private var gpgDecryptionKeyRow: some View {
        // 跟同 Form 里其它行（保存到 / 密码 / 解密方式）保持 body 字号，不专门 .font(.caption)，避免视觉错落。
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("extract.gpgDecryptionKey.label"))
            GPGSecretKeyMenu(
                selection: $request.gpgDecryptionKeyFingerprint,
                secretKeys: availableSecretKeys,
                autoLabelKey: "extract.gpgDecryptionKey.auto",
                missingFingerprintKey: "extract.gpgDecryptionKey.missingFingerprint"
            )
            Spacer()
        }
    }

    /// `.siz` v3 对称加密的密码输入。和「内层 ZIP/7z 解压密码」独立 —— 用户的两份密码通常不一样。
    /// 长说明放下方 caption Text，避免 SecureField placeholder 横向被截断。
    @ViewBuilder
    private var gpgDecryptionPassphraseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("extract.gpgDecryptionPassphrase.label"))
                SecureField(L10n.text("extract.gpgDecryptionPassphrase.placeholder"), text: $request.gpgDecryptionPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            Text(L10n.text("extract.gpgDecryptionPassphrase.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// `.siz` 解压对话框里多出来的三行：签名状态、签名时间、签名指纹。
/// 走标准 Form 的行布局，不另开卡片块，保持跟 destination / password / decryptionMethod 等行一致。
/// 用户要求签名时间 + 公钥指纹必须可见，不藏 tooltip。
private struct SIZSignatureRows: View {
    let signature: SIZSignatureSummary

    var body: some View {
        // Form 内部会按行折行，每个 HStack = 一行。
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("siz.signatureSheet.signer"))
            Image(systemName: SIZSignatureStatus.iconName(for: signature.verify))
                .foregroundStyle(SIZSignatureStatus.color(for: signature.verify))
            Text(SIZSignatureStatus.title(for: signature.verify))
                .foregroundStyle(SIZSignatureStatus.color(for: signature.verify))
            Text("·")
                .foregroundStyle(.secondary)
            Text(signature.signerDisplay)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("siz.signatureSheet.signedAt"))
            Text(signature.signedAt)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.text("siz.signatureSheet.keyFingerprint"))
            Text(signature.signerFingerprint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

/// 跨 view 共用的「GPGVerifyResult → 图标 / 颜色 / 标题」mapping —— sheet 跟 banner 都从这里取。
/// 避免在两个地方各写一份 switch（之前的弯路）。
enum SIZSignatureStatus {
    static func iconName(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            // 有 concerns（密钥过期 / 撤销 / 签名过期）= 密码学有效但「不能放心」→ 跟 untrusted 同视觉档。
            if !concerns.isEmpty { return "checkmark.seal" }
            return trusted ? "checkmark.seal.fill" : "checkmark.seal"
        case .unknownSigner: return "questionmark.circle.fill"
        case .badSignature: return "exclamationmark.triangle.fill"
        case .verificationError: return "xmark.octagon.fill"
        }
    }

    static func color(for verify: GPGBackend.GPGVerifyResult) -> Color {
        switch verify {
        case .validSignature(_, _, _, let concerns):
            // concerns 非空时降级为 orange 提示用户「签名是真的但密钥状态有问题」。
            return concerns.isEmpty ? .green : .orange
        case .unknownSigner, .verificationError: return .orange
        case .badSignature: return .red
        }
    }

    static func title(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            if concerns.contains(.keyRevoked) { return L10n.text("siz.verify.valid.keyRevoked.title") }
            if concerns.contains(.keyExpired) { return L10n.text("siz.verify.valid.keyExpired.title") }
            if concerns.contains(.signatureExpired) { return L10n.text("siz.verify.valid.sigExpired.title") }
            return trusted
                ? L10n.text("siz.verify.valid.trusted.title")
                : L10n.text("siz.verify.valid.untrusted.title")
        case .unknownSigner: return L10n.text("siz.verify.unknownSigner.title")
        case .badSignature: return L10n.text("siz.verify.bad.title")
        case .verificationError: return L10n.text("siz.verify.error.title")
        }
    }

    /// sheet 用的副标题文案 —— 短句解释当前状态。
    static func summary(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, _, let concerns):
            if concerns.contains(.keyRevoked) { return L10n.text("siz.signatureSheet.valid.keyRevoked.summary") }
            if concerns.contains(.keyExpired) { return L10n.text("siz.signatureSheet.valid.keyExpired.summary") }
            if concerns.contains(.signatureExpired) { return L10n.text("siz.signatureSheet.valid.sigExpired.summary") }
            return L10n.text("siz.signatureSheet.valid.summary")
        case .unknownSigner: return L10n.text("siz.signatureSheet.unknownSigner.summary")
        case .badSignature: return L10n.text("siz.signatureSheet.bad.summary")
        case .verificationError(let message): return message
        }
    }
}
