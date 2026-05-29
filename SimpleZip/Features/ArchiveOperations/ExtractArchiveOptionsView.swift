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
        }
        .frame(width: 540)
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
