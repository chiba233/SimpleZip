//
//  SIZSignatureSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import SwiftUI

/// `.siz` 容器打开前的签名信息展示 sheet。
///
/// 用 SwiftUI sheet 而不是 NSAlert：
/// - NSAlert 在 SwiftUI 视图 context（没 key window 锚定时）渲染成无 chrome 浮动框，关闭不可控；
/// - sheet 跟创建 / 解压对话框同套机制，行为可控、视觉一致。
///
/// 状态依赖 `SIZPendingVerification`（unwrap 结果 + 验签 outcome），父视图（ContentView）通过
/// `.sheet(item:)` 触发。Open / Cancel 通过 closure 回传给父视图，让父视图统一处理临时目录清理 / 打开内层 archive。
struct SIZSignatureSheet: View {
    let pending: ContentView.SIZPendingVerification
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部：图标 + 主标题 + 副标题（根据 outcome 着色）
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: outcome.iconName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(outcome.iconColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.title)
                        .font(.title3.weight(.semibold))
                    Text(outcome.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Divider()

            // 详细字段表：签名者 / 内层文件 / 签名时间 / 来源路径
            VStack(alignment: .leading, spacing: 8) {
                detailRow(
                    label: L10n.text("siz.signatureSheet.signer"),
                    value: displaySigner
                )
                detailRow(
                    label: L10n.text("siz.signatureSheet.innerArchive"),
                    value: pending.unwrap.metadata.innerArchiveName
                )
                detailRow(
                    label: L10n.text("siz.signatureSheet.signedAt"),
                    value: pending.unwrap.metadata.createdAt
                )
                detailRow(
                    label: L10n.text("siz.signatureSheet.source"),
                    value: pending.sourceURL.path,
                    monospaced: true
                )

                // unknown signer 时给个 Key ID + 「先去钥匙串导入」的指引。
                if case .gpgResult(.unknownSigner(let keyID)) = pending.outcome {
                    detailRow(
                        label: L10n.text("siz.signatureSheet.keyID"),
                        value: keyID ?? pending.unwrap.metadata.signature.signerFingerprint,
                        monospaced: true
                    )
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // outcome 额外说明（如果有）
            if let extra = outcome.extraNote {
                Text(extra)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 底部按钮 —— bad signature 时 Cancel 是默认按钮（回车 / Esc 都取消），避免误开。
            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: onCancel)
                    .keyboardShortcut(outcome.cancelIsDefault ? .defaultAction : .cancelAction)
                Button(outcome.openButtonTitle) {
                    onOpen()
                }
                .keyboardShortcut(outcome.cancelIsDefault ? nil : .defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(outcome.openTint)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    /// 名称 + 值 单行展示。
    @ViewBuilder
    private func detailRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 签名者显示文案 —— 优先用验签时 gpg 报告的 signer 文本；fallback 到 metadata 里记录的 signerUserID。
    private var displaySigner: String {
        if case .gpgResult(.validSignature(let signer, _)) = pending.outcome, let signer {
            return signer
        }
        if case .gpgResult(.badSignature(let signer)) = pending.outcome, let signer {
            return signer
        }
        let stored = pending.unwrap.metadata.signature.signerUserID
        return stored.isEmpty ? L10n.text("siz.signatureSheet.unknownSigner") : stored
    }

    /// 把 ContentView.SIZVerificationOutcome 各 case 映射成 UI 用的「图标 / 颜色 / 文案 / 按钮属性」。
    private var outcome: SignatureUIState {
        switch pending.outcome {
        case .gpgResult(.validSignature(_, let trusted)):
            return SignatureUIState(
                iconName: trusted ? "checkmark.seal.fill" : "checkmark.seal",
                iconColor: .green,
                title: trusted
                    ? L10n.text("siz.verify.valid.trusted.title")
                    : L10n.text("siz.verify.valid.untrusted.title"),
                summary: L10n.text("siz.signatureSheet.valid.summary"),
                extraNote: trusted ? nil : L10n.text("siz.signatureSheet.untrusted.note"),
                openButtonTitle: L10n.text("siz.verify.openButton"),
                openTint: .accentColor,
                cancelIsDefault: false
            )
        case .gpgResult(.unknownSigner):
            return SignatureUIState(
                iconName: "questionmark.circle.fill",
                iconColor: .orange,
                title: L10n.text("siz.verify.unknownSigner.title"),
                summary: L10n.text("siz.signatureSheet.unknownSigner.summary"),
                extraNote: L10n.text("siz.signatureSheet.unknownSigner.note"),
                openButtonTitle: L10n.text("siz.verify.unknownSigner.openAnyway"),
                openTint: .orange,
                cancelIsDefault: false
            )
        case .gpgResult(.badSignature):
            return SignatureUIState(
                iconName: "exclamationmark.triangle.fill",
                iconColor: .red,
                title: L10n.text("siz.verify.bad.title"),
                summary: L10n.text("siz.signatureSheet.bad.summary"),
                extraNote: L10n.text("siz.signatureSheet.bad.note"),
                openButtonTitle: L10n.text("siz.verify.bad.openAnyway"),
                openTint: .red,
                cancelIsDefault: true
            )
        case .gpgResult(.verificationError(let message)),
             .verificationError(let message):
            return SignatureUIState(
                iconName: "xmark.octagon.fill",
                iconColor: .orange,
                title: L10n.text("siz.verify.error.title"),
                summary: message,
                extraNote: L10n.text("siz.signatureSheet.error.note"),
                openButtonTitle: L10n.text("siz.verify.openButton"),
                openTint: .accentColor,
                cancelIsDefault: false
            )
        case .gpgMissing:
            return SignatureUIState(
                iconName: "key.slash",
                iconColor: .orange,
                title: L10n.text("siz.verify.gpgMissing.title"),
                summary: L10n.text("siz.signatureSheet.gpgMissing.summary"),
                extraNote: L10n.text("siz.signatureSheet.gpgMissing.note"),
                openButtonTitle: L10n.text("siz.verify.openButton"),
                openTint: .accentColor,
                cancelIsDefault: false
            )
        }
    }

    private struct SignatureUIState {
        let iconName: String
        let iconColor: Color
        let title: String
        let summary: String
        let extraNote: String?
        let openButtonTitle: String
        let openTint: Color
        /// bad signature → Cancel 是 default action（回车 / Esc 都取消），引导用户不要开。
        let cancelIsDefault: Bool
    }
}
