//
//  GPGEncryptOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  右键「加密为 .gpg」的选项 sheet。**复用** ArchiveCreationOptionsView 的收件人 / 对称密码 idiom
//  （同一份 `GPGBackend.GPGKey` + `[String]` fingerprint 模型，不另造 DTO），只是把它从「创建 .siz 签名包」
//  里摘出来用于「直接把文件 / 文件夹加密成 .gpg」这一独立动作。收件人公钥**或**对称密码至少给一个
//  （两者皆空时 `GPGBackend.encrypt` 会抛错 → 这里用按钮禁用 + 提示拦在前面）。
//

import AppKit
import SwiftUI

/// 「加密为 .gpg」的待确认请求。沿用 ArchiveCreationRequest 的极简形态：源 + 所在目录 + 加密参数。
/// 收件人 / 对称密码直接是后端消费的类型（`[String]` fingerprint / `String`），不套壳。
struct GPGEncryptRequest: Identifiable {
    let id = UUID()
    let sourceURLs: [URL]
    let directoryURL: URL
    var recipientFingerprints: [String] = []
    var symmetricPassphrase: String = ""
    /// 多选时的加密方式：true = 逐个文件各产一个 `.gpg`；false = 打包成一个 `.tar.gpg`。
    /// 默认逐个（用户更直觉的「一个文件一个 .gpg」）。单个源时此项无影响（两种产物一致）。
    var perFile: Bool = true
    /// 收件人公钥都在 SimpleZip 私有环时 → 加密走私有 `--homedir`（否则 ~/.gnupg 里找不到这些公钥）。
    /// 一次 gpg 调用只能用一个 homedir,所以不允许混选两环(UI 在前面拦)。
    var useSimpleZipKeyring: Bool = false
}

struct GPGEncryptOptionsView: View {
    @State var request: GPGEncryptRequest
    /// 用户钥匙串里可用于加密的公钥。仅 `.userKeyring`（GPGBackend.encrypt 默认用 ~/.gnupg/，
    /// 私有环里的 key 选了也加密不到——与 ArchiveCreationOptionsView 的 encryptionEligibleKeys 同口径）。
    @State private var availableKeys: [GPGBackend.GPGKey] = []
    /// 预设密码快照：开了「预设密码」时自动填进对称密码框（与创建对话框对称）。dialog 关即丢。
    @State private var presetPassword = ""
    /// 选区里是否含文件夹 —— 含文件夹时即使只选了一个，「逐个 vs 打包」也有区别，要显示模式选择。
    @State private var hasDirectory = false
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false
    let confirm: (GPGEncryptRequest) -> Void
    let cancel: () -> Void

    /// 多选、或选区含文件夹时才显示「加密方式」——这两种情况「逐个 vs 打包」产物不同。
    private var showsModePicker: Bool {
        request.sourceURLs.count > 1 || hasDirectory
    }

    /// 收件人候选公钥 —— **两个环都列**(~/.gnupg 的 + SimpleZip 私有环的),但**只列有加密能力的 key**:
    /// gpg 不能加密给纯签名/认证密钥(caps 里没有 `e`/`E`),选了会报「使用できない公開鍵」。
    /// 加密时按所选收件人所在环选 homedir。
    private var encryptionEligibleKeys: [GPGBackend.GPGKey] {
        availableKeys.filter { $0.canEncryptToRecipient }
    }

    /// 已选收件人分布在哪些环(用于「混选两环」拦截 + 选 homedir)。
    private var selectedRecipientSources: Set<GPGBackend.GPGKeyringSource> {
        Set(request.recipientFingerprints.compactMap { fp in
            availableKeys.first(where: { $0.fingerprint == fp })?.source
        })
    }

    /// 收件人来自两个不同钥匙串 —— 一次 gpg 加密只能用一个 homedir,做不到,拦下来。
    private var hasMixedRecipientRings: Bool {
        selectedRecipientSources.count > 1
    }

    /// 收件人或对称密码至少一个非空,且收件人没混选两环 —— 否则没法加密。
    private var canEncrypt: Bool {
        (!request.recipientFingerprints.isEmpty || !request.symmetricPassphrase.isEmpty) && !hasMixedRecipientRings
    }

    var body: some View {
        // 0.4.1 重构：与创建 / 解压对话框同一套现代体例（DialogChrome）。
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "lock.fill",
                colors: [.green, .mint],
                title: L10n.text("gpgEncrypt.title"),
                subtitle: L10n.format("gpgEncrypt.sourceSummary", "\(request.sourceURLs.count)")
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 多选 / 含文件夹才有意义：逐个文件分别加密 vs 打包成一个归档再加密。
                    if showsModePicker {
                        DialogSection(L10n.text("gpgEncrypt.section.mode")) {
                            Picker("", selection: $request.perFile) {
                                Label(L10n.text("gpgEncrypt.mode.perFile"), systemImage: "doc.on.doc").tag(true)
                                Label(L10n.text("gpgEncrypt.mode.bundle"), systemImage: "shippingbox").tag(false)
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }
                    }
                    // 收件人公钥单独成卡 —— 内含「添加菜单 + chip 行」，挤在别的控件旁边会重叠（用户报间距问题）。
                    DialogSection(L10n.text("gpgEncrypt.section.recipients")) {
                        recipientsRow
                    }
                    // 对称密码 + 说明单独成卡。
                    DialogSection(L10n.text("gpgEncrypt.section.passphrase")) {
                        encryptionPassphraseRow
                        Text(L10n.text("gpgEncrypt.description"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 520)

            Divider()

            HStack {
                if hasMixedRecipientRings {
                    Text(L10n.text("gpgEncrypt.mixedKeyrings"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if !canEncrypt {
                    Text(L10n.text("gpgEncrypt.needsRecipientOrPassphrase"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("gpgEncrypt.button")) {
                    // 收件人全在 SimpleZip 私有环 → 加密用私有 homedir。混选已被 canEncrypt 拦住,到不了这里。
                    request.useSimpleZipKeyring = selectedRecipientSources == [.simpleZipKeyring]
                    confirm(request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canEncrypt)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 520)
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onAppear {
            presetPassword = AppPreferences.presetPassword
            hasDirectory = request.sourceURLs.contains { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue
            }
            // 开了预设密码 → 默认填入对称密码框（用户可清空改用公钥）。与创建对话框的 preset 自动填一致。
            if presetPasswordEnabled, !presetPassword.isEmpty {
                request.symmetricPassphrase = presetPassword
            }
            if AppPreferences.gpgEnabled, GPGBackend.isAvailable() {
                Task { @MainActor in
                    if let loaded = try? await GPGBackend.listKeys() {
                        availableKeys = loaded
                    }
                }
            }
        }
    }

    // MARK: - 收件人公钥（沿用 ArchiveCreationOptionsView 的 Menu + chip idiom）

    @ViewBuilder
    private var recipientsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.text("archive.gpgEncrypt.recipientsLabel"), systemImage: "person.2.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                GPGAddRecipientMenu(eligibleKeys: encryptionEligibleKeys, selection: $request.recipientFingerprints)
            }
            GPGRecipientChipRow(selection: $request.recipientFingerprints, lookupKeys: availableKeys)
        }
    }

    @ViewBuilder
    private var encryptionPassphraseRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("archive.gpgEncrypt.passphraseLabel"), systemImage: "lock.rectangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $request.symmetricPassphrase)
                .textFieldStyle(.roundedBorder)
            Text(L10n.text("archive.gpgEncrypt.passphraseHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
