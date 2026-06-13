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
    /// 实测的说明正文高度（GeometryReader 量）—— 用于「自适应高度,到上限才滚动」。
    @State private var instructionsContentHeight: CGFloat = 0
    /// 说明正文的最大显示高度；超过就在面板内滚动，避免超长留言把 sheet 撑出屏幕。
    private let maxInstructionsHeight: CGFloat = 260

    // 0.4.2 #29：unknownSigner 时的本地公钥导入。**绝不联网 keyserver** —— 只扫 .siz 同目录的
    // 公钥文件 + 接受拖入。导入成功后提示重新打开以重验（验证发生在打开时，不在 sheet 内重跑）。
    @State private var siblingKeyFiles: [URL] = []
    @State private var importRing: GPGBackend.GPGKeyringSource = .userKeyring
    @State private var isImportingKey = false
    @State private var keyImportMessage: String?
    @State private var keyImportSucceeded = false

    private var showsUnknownSignerImport: Bool {
        if case .unknownSigner = signature.verify { return true }
        return false
    }

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
        // 0.4.1 重构：套现代体例 —— 验签状态本身就是 hero（大彩色印章 + 标题 + 摘要）,
        // detail 进 DialogSection 卡片,操作钉底 bar,内容区可滚动自适应。
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SIZSignatureStatus.color(for: signature.verify).gradient)
                    .overlay(
                        Image(systemName: SIZSignatureStatus.iconName(for: signature.verify))
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SIZSignatureStatus.title(for: signature.verify))
                        .font(.title3.weight(.semibold))
                    Text(SIZSignatureStatus.summary(for: signature.verify))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            HeightCappedScrollView(maxHeight: 520) {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection {
                        detailRow(L10n.text("siz.signatureSheet.signer"), signature.signerDisplay, systemImage: "person.fill", tint: .green)
                        detailRow(L10n.text("siz.signatureSheet.keyFingerprint"), signature.signerFingerprint, systemImage: "touchid", tint: .indigo, monospaced: true)
                        detailRow(L10n.text("siz.signatureSheet.signedAt"), signature.signedAt, systemImage: "clock.fill", tint: .purple)
                        detailRow(L10n.text("siz.signatureSheet.source"), signature.sourceURL.path, systemImage: "doc.fill", tint: .cyan, monospaced: true)
                        detailRow(L10n.text("siz.signatureSheet.formatVersion"), ".\(SIZArchive.extensionName) v\(signature.schemaVersion)", systemImage: "shippingbox.fill", tint: .brown)
                        if let instructions = signature.deliveryInstructions, !instructions.isEmpty {
                            instructionsRow(instructions)
                        }
                    }

                    // 0.4.2 #29：签名者公钥未导入 → 本地导入区（同目录公钥文件 + 拖入；不联网）。
                    if showsUnknownSignerImport {
                        DialogSection(L10n.text("siz.keyImport.section")) {
                            unknownSignerImportControls
                        }
                    }

                    // 加密容器：picker + passphrase 字段；passphrase 字段优先于 pinentry-mac 兜底。
                    if showsDecryptionKeyPicker || showsDecryptionPassphraseField {
                        DialogSection(L10n.text("siz.signatureSheet.section.decryption")) {
                            decryptionControls
                        }
                    }

                    // 解密失败内联提示（密码 / 密钥错）—— 红字，留在 sheet 里让用户改了重试。
                    if let inlineError {
                        Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                if isOpening {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("siz.signatureSheet.decrypting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // #52:AI 白话解释这份 .siz 签名(是否可信 + 内层是否被改动)。仅 isReady 时出现;绝不放行坏签名。
                AIAssistButton(
                    label: L10n.text("ai.explainVerify"),
                    systemImage: "sparkles",
                    sheetTitle: L10n.text("ai.explainVerify.title"),
                    sheetSubtitle: signature.sourceURL.lastPathComponent
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let built = AIReportAssistant.sizSignatureExplanationPrompt(signature: signature)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                .disabled(isOpening)
                Spacer()
                Button(action: onCancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                .keyboardShortcut(cancelIsDefault ? .defaultAction : .cancelAction)
                .disabled(isOpening)
                if let onOpenInMainWindow {
                    Button(action: onOpenInMainWindow) {
                        Label(L10n.text("externalExtract.openInMainWindow"), systemImage: "macwindow")
                    }
                    .disabled(isOpening)
                }
                Button {
                    runOpen()
                } label: {
                    Label(primaryActionTitle ?? openButtonTitle, systemImage: "doc.zipper")
                }
                .keyboardShortcut(cancelIsDefault ? nil : .defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SIZSignatureStatus.color(for: signature.verify))
                .disabled(isOpening)
            }
        }
        .frame(width: 560)
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onAppear {
            // 0.4.2 #29：unknownSigner 时扫同目录公钥候选（本地文件枚举，瞬时）。
            if showsUnknownSignerImport {
                scanSiblingKeyFiles()
            }
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
                HStack(alignment: .center, spacing: 8) {
                    DialogRowLabel(L10n.text("extract.gpgDecryptionKey.label"), systemImage: "person.badge.key.fill", tint: .green, width: Self.labelColumnWidth)
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
                    HStack(alignment: .center, spacing: 8) {
                        DialogRowLabel(L10n.text("extract.gpgDecryptionPassphrase.label"), systemImage: "lock.rectangle.fill", tint: .orange, width: Self.labelColumnWidth)
                        SecureField(
                            L10n.text("extract.gpgDecryptionPassphrase.placeholder"),
                            text: $decryptionPassphrase
                        )
                        .textFieldStyle(.roundedBorder)
                        .dialogFieldEmphasis()
                    }
                    Text(L10n.text("extract.gpgDecryptionPassphrase.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.labelColumnWidth + 8)
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
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("siz.instructions.disclosure"), systemImage: "text.bubble.fill", tint: .blue, width: Self.labelColumnWidth)
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
                    // 自适应高度：GeometryReader 量正文真实高度，frame 取 min(实测, 上限)。
                    // 内容短 → 刚好贴合不留白；内容长(超长留言) → 到上限后面板内滚动，绝不撑出屏幕。
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: InstructionsHeightKey.self, value: proxy.size.height)
                            })
                    }
                    .frame(height: min(instructionsContentHeight, maxInstructionsHeight))
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onPreferenceChange(InstructionsHeightKey.self) { instructionsContentHeight = $0 }
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

    /// 0.4.2 #29：本地导入签名者公钥。扫同目录的公钥文件逐个给「导入」按钮，整区也接受拖入；
    /// 目标环可选（我的钥匙串 / SimpleZip 专用环）。导入只是第一步 —— 提示重新打开以重验 + 设信任。
    @ViewBuilder
    private var unknownSignerImportControls: some View {
        Text(L10n.text("siz.keyImport.hint"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Picker(L10n.text("siz.keyImport.ring"), selection: $importRing) {
            Text(L10n.text("gpgImport.ring.user")).tag(GPGBackend.GPGKeyringSource.userKeyring)
            Text(L10n.text("gpgImport.ring.simpleZip")).tag(GPGBackend.GPGKeyringSource.simpleZipKeyring)
        }
        .pickerStyle(.segmented)
        if siblingKeyFiles.isEmpty {
            Label(L10n.text("siz.keyImport.noSiblings"), systemImage: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(siblingKeyFiles, id: \.self) { keyURL in
                HStack {
                    Label(keyURL.lastPathComponent, systemImage: "person.badge.key")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        importSignerKey(from: keyURL)
                    } label: {
                        Label(L10n.text("gpgImport.action.import"), systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(isImportingKey)
                }
            }
        }
        if isImportingKey {
            ProgressView().controlSize(.small)
        }
        if let keyImportMessage {
            Label(keyImportMessage, systemImage: keyImportSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(keyImportSucceeded ? Color.green : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 扫 .siz 同目录的公钥候选文件（.asc / .pub / .key / .pgp / .gpg，排除 .siz 自己解出来的内层 .gpg 大文件不现实——
    /// 只按扩展名列出，由用户决定导入哪个；导入失败 gpg 会拒绝非密钥文件，不会污染钥匙串）。
    private func scanSiblingKeyFiles() {
        let directory = signature.sourceURL.deletingLastPathComponent()
        let keyExtensions: Set<String> = ["asc", "pub", "key", "pgp"]
        siblingKeyFiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { keyExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func importSignerKey(from url: URL) {
        isImportingKey = true
        keyImportMessage = nil
        Task { @MainActor in
            do {
                _ = try await GPGBackend.importKey(from: url, into: importRing)
                keyImportSucceeded = true
                keyImportMessage = L10n.text("siz.keyImport.success")
            } catch {
                keyImportSucceeded = false
                keyImportMessage = error.localizedDescription
            }
            isImportingKey = false
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, systemImage: String, tint: Color, monospaced: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DialogRowLabel(label, systemImage: systemImage, tint: tint, width: Self.labelColumnWidth)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 标签列定宽(en 最长 "Decryption passphrase" + 22pt 瓦片也放得下)。
    static let labelColumnWidth: CGFloat = 185
}

/// 量「收件人说明」正文真实高度的 PreferenceKey —— 给「自适应高度,到上限才滚动」用。
private struct InstructionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
