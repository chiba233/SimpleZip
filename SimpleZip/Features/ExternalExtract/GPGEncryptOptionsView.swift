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

    private var encryptionEligibleKeys: [GPGBackend.GPGKey] {
        availableKeys.filter { $0.source == .userKeyring }
    }

    /// 收件人或对称密码至少一个非空 —— 否则没有任何方式能解密产物。
    private var canEncrypt: Bool {
        !request.recipientFingerprints.isEmpty || !request.symmetricPassphrase.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("gpgEncrypt.title"))
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.format("gpgEncrypt.sourceSummary", "\(request.sourceURLs.count)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // 多选 / 含文件夹才有意义：逐个文件分别加密 vs 打包成一个归档再加密。
                if showsModePicker {
                    Picker(L10n.text("gpgEncrypt.mode.label"), selection: $request.perFile) {
                        Text(L10n.text("gpgEncrypt.mode.perFile")).tag(true)
                        Text(L10n.text("gpgEncrypt.mode.bundle")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }

                recipientsRow
                encryptionPassphraseRow

                Text(L10n.text("gpgEncrypt.description"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if !canEncrypt {
                    Text(L10n.text("gpgEncrypt.needsRecipientOrPassphrase"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("gpgEncrypt.button")) {
                    confirm(request)
                }
                .disabled(!canEncrypt)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 480)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("archive.gpgEncrypt.recipientsLabel"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                GPGAddRecipientMenu(eligibleKeys: encryptionEligibleKeys, selection: $request.recipientFingerprints)
                Spacer()
            }
            GPGRecipientChipRow(selection: $request.recipientFingerprints, lookupKeys: availableKeys)
        }
    }

    @ViewBuilder
    private var encryptionPassphraseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("archive.gpgEncrypt.passphraseLabel"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $request.symmetricPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            Text(L10n.text("archive.gpgEncrypt.passphraseHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
