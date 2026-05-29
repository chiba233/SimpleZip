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
/// 状态来源：`SIZSignatureSummary` —— 同一份 model 解压对话框也在用，两边图标 / 颜色 / 标题 mapping
/// 走 `SIZSignatureStatus` 共用，不在这里再 switch 一遍。
struct SIZSignatureSheet: View {
    let signature: SIZSignatureSummary
    let onOpen: () -> Void
    let onCancel: () -> Void

    /// `.badSignature` 时把 Cancel 设为 default action（回车 / Esc 都退出），引导用户不要打开被篡改的容器。
    private var cancelIsDefault: Bool {
        if case .badSignature = signature.verify { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: SIZSignatureStatus.iconName(for: signature.verify))
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(SIZSignatureStatus.color(for: signature.verify))
                VStack(alignment: .leading, spacing: 4) {
                    Text(SIZSignatureStatus.title(for: signature.verify))
                        .font(.title3.weight(.semibold))
                    Text(SIZSignatureStatus.summary(for: signature.verify))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                detailRow(L10n.text("siz.signatureSheet.signer"), signature.signerDisplay)
                detailRow(L10n.text("siz.signatureSheet.keyFingerprint"), signature.signerFingerprint, monospaced: true)
                detailRow(L10n.text("siz.signatureSheet.signedAt"), signature.signedAt)
                detailRow(L10n.text("siz.signatureSheet.source"), signature.sourceURL.path, monospaced: true)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: onCancel)
                    .keyboardShortcut(cancelIsDefault ? .defaultAction : .cancelAction)
                Button(openButtonTitle, action: onOpen)
                    .keyboardShortcut(cancelIsDefault ? nil : .defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(SIZSignatureStatus.color(for: signature.verify))
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    /// 「打开」按钮文案根据验签结果换措辞（unknownSigner / badSignature 时强调风险）。
    private var openButtonTitle: String {
        switch signature.verify {
        case .unknownSigner: return L10n.text("siz.verify.unknownSigner.openAnyway")
        case .badSignature: return L10n.text("siz.verify.bad.openAnyway")
        default: return L10n.text("siz.verify.openButton")
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
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
}
