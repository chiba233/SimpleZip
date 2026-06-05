//
//  SIZSignatureSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import AppKit
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
    /// 主操作回调 —— 携带用户在 sheet 里挑的解密密钥 fingerprint（nil 让 gpg 自挑）和对称密码（nil 让 pinentry-mac 接管）。
    /// caller 用这两个值调 `SIZArchive.decryptInnerArchive`。
    /// 语义由宿主决定：主窗口宿主 = 「打开浏览」；独立浮窗宿主 = 「解压」。
    ///
    /// **返回值 = 错误文案（nil 表示成功）**：成功时宿主负责关闭 sheet；失败（如解密密码错误）返回错误串，
    /// sheet **内联红字**显示并保留，让用户改密码 / 换密钥重试。之前 fire-and-forget + 宿主走 errorMessage，
    /// 弹的 alert 被 sheet 盖住 → 用户看不到任何提示（用户反馈的 bug）。
    let onOpen: (_ decryptionKey: String?, _ decryptionPassphrase: String?) async -> String?
    let onCancel: () -> Void

    /// 主操作按钮文案 override。nil → 用内置的「打开 / 仍然打开」措辞（主窗口浏览语境）。
    /// 独立浮窗解压语境传「解压」。
    var primaryActionTitle: String? = nil
    /// 可选「在主窗口打开」入口 —— 仅独立浮窗宿主提供（满足「在独立窗口内可以选择拉起主窗口」）。
    /// nil → 不显示该按钮（主窗口宿主本就在主窗口里，无需此入口）。
    var onOpenInMainWindow: (() -> Void)? = nil

    @State private var availableSecretKeys: [GPGBackend.GPGKey] = []
    @State private var selectedDecryptionKey: String = ""
    @State private var decryptionPassphrase: String = ""
    /// 解密 / 打开进行中 —— 禁用按钮 + 转圈，避免重复点。
    @State private var isOpening = false
    /// 解密失败（密码 / 密钥错）的内联错误文案；非空时在按钮上方红字显示，sheet 保留让用户重试。
    @State private var inlineError: String?
    /// 「收件人说明」(#110)折叠展开状态 —— 默认收起,信息密度优先,用户想看再展开。
    @State private var showInstructions = false

    /// `.badSignature` 时把 Cancel 设为 default action（回车 / Esc 都退出），引导用户不要打开被篡改的容器。
    private var cancelIsDefault: Bool {
        if case .badSignature = signature.verify { return true }
        return false
    }

    /// 是否要展示「选择解密密钥」picker —— 仅当容器有公钥加密 recipients 时（symmetric-only 不需要选 key）。
    private var showsDecryptionKeyPicker: Bool {
        guard let encryption = signature.encryption else { return false }
        return !encryption.recipients.isEmpty
    }

    /// 是否要展示「解密密码」SecureField —— 仅当容器有对称密码加密时。
    private var showsDecryptionPassphraseField: Bool {
        signature.encryption?.hasSymmetricPassphrase == true
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
                // #110 收件人说明：作为 detail 块里的**一行**（标题对齐标签列、展开正文对齐值列），
                // 而不是下面另起一张浮卡 —— 解决「跟上面间距太大 / 正文贴左 / 左右 margin 太小」。
                if let instructions = signature.deliveryInstructions, !instructions.isEmpty {
                    instructionsRow(instructions)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 加密容器：在 detail 块下方加 picker + passphrase 字段；passphrase 字段优先于 pinentry-mac 兜底。
            if showsDecryptionKeyPicker || showsDecryptionPassphraseField {
                decryptionControls
            }

            // 解密失败内联提示（密码 / 密钥错）—— 红字，留在 sheet 里让用户改了重试。
            if let inlineError {
                Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isOpening {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("siz.signatureSheet.decrypting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: onCancel)
                    .keyboardShortcut(cancelIsDefault ? .defaultAction : .cancelAction)
                    .disabled(isOpening)
                if let onOpenInMainWindow {
                    Button(L10n.text("externalExtract.openInMainWindow"), action: onOpenInMainWindow)
                        .disabled(isOpening)
                }
                Button(primaryActionTitle ?? openButtonTitle) {
                    runOpen()
                }
                .keyboardShortcut(cancelIsDefault ? nil : .defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SIZSignatureStatus.color(for: signature.verify))
                .disabled(isOpening)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            // 仅加密容器才需要载入 hasSecretKey 密钥列表 —— 没加密的容器 picker 不显示，省一次 listKeys 调用。
            guard showsDecryptionKeyPicker, AppPreferences.gpgEnabled, GPGBackend.isAvailable() else { return }
            Task { @MainActor in
                if let loaded = try? await GPGBackend.listKeys() {
                    availableSecretKeys = loaded.filter { $0.hasSecretKey }
                }
            }
        }
    }

    /// 跑主操作（打开 / 解压）：转圈 + 调 onOpen；返回非 nil（错误）→ 内联红字、sheet 保留重试；nil（成功）→ 宿主关 sheet。
    private func runOpen() {
        isOpening = true
        inlineError = nil
        Task { @MainActor in
            let error = await onOpen(
                selectedDecryptionKey.isEmpty ? nil : selectedDecryptionKey,
                decryptionPassphrase.isEmpty ? nil : decryptionPassphrase
            )
            isOpening = false
            if let error { inlineError = error }
        }
    }

    /// 解密相关控件块：picker（如果有公钥加密）+ passphrase SecureField（如果有对称密码加密）。
    /// 两者可同时出现（multi-recipient + symmetric 组合模式），布局上下排。
    @ViewBuilder
    private var decryptionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDecryptionKeyPicker {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("extract.gpgDecryptionKey.label"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    GPGSecretKeyMenu(
                        selection: $selectedDecryptionKey,
                        secretKeys: availableSecretKeys,
                        autoLabelKey: "extract.gpgDecryptionKey.auto",
                        missingFingerprintKey: "extract.gpgDecryptionKey.missingFingerprint"
                    )
                    Spacer()
                }
            }
            if showsDecryptionPassphraseField {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L10n.text("extract.gpgDecryptionPassphrase.label"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        SecureField(
                            L10n.text("extract.gpgDecryptionPassphrase.placeholder"),
                            text: $decryptionPassphrase
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    Text(L10n.text("extract.gpgDecryptionPassphrase.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 96)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// #110「收件人说明」—— detail 块里的**一行**：标题右对齐到标签列（跟「签名者/源文件」齐），
    /// 点标题区折叠展开；展开的正文缩进到**值列**（`88 + 12`，跟上面各行的值左对齐），不贴左、有舒适内边距。
    @ViewBuilder
    private func instructionsRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showInstructions.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.text("siz.instructions.disclosure"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .trailing)
                    Image(systemName: showInstructions ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showInstructions {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label(L10n.text("siz.instructions.copy"), systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                // 正文缩进到值列（标签宽 88 + HStack spacing 12），跟上面各行的值左对齐。
                .padding(.leading, 88 + 12)
            }
        }
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
