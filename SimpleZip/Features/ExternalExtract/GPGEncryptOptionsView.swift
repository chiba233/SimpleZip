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
}

struct GPGEncryptOptionsView: View {
    @State var request: GPGEncryptRequest
    /// 用户钥匙串里可用于加密的公钥。仅 `.userKeyring`（GPGBackend.encrypt 默认用 ~/.gnupg/，
    /// 私有环里的 key 选了也加密不到——与 ArchiveCreationOptionsView 的 encryptionEligibleKeys 同口径）。
    @State private var availableKeys: [GPGBackend.GPGKey] = []
    /// 预设密码快照：开了「预设密码」时自动填进对称密码框（与创建对话框对称）。dialog 关即丢。
    @State private var presetPassword = ""
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false
    let confirm: (GPGEncryptRequest) -> Void
    let cancel: () -> Void

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
                Menu {
                    if encryptionEligibleKeys.isEmpty {
                        Text(L10n.text("archive.gpgEncrypt.noKeysInRing"))
                    } else {
                        ForEach(encryptionEligibleKeys) { key in
                            Button {
                                toggleRecipient(key.fingerprint)
                            } label: {
                                HStack {
                                    Image(systemName: request.recipientFingerprints.contains(key.fingerprint) ? "checkmark.circle.fill" : "circle")
                                    Text("\(key.userID) · \(key.shortFingerprint)")
                                }
                            }
                        }
                    }
                } label: {
                    Text(L10n.text("archive.gpgEncrypt.addRecipient"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            if !request.recipientFingerprints.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(request.recipientFingerprints, id: \.self) { fp in
                            recipientChip(fp)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recipientChip(_ fingerprint: String) -> some View {
        let key = availableKeys.first(where: { $0.fingerprint == fingerprint })
        HStack(spacing: 4) {
            Text(key.map { "\($0.userID) · \($0.shortFingerprint)" }
                ?? L10n.format("archive.gpgEncrypt.unknownRecipient", String(fingerprint.suffix(16))))
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                request.recipientFingerprints.removeAll { $0 == fingerprint }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
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

    private func toggleRecipient(_ fingerprint: String) {
        if let index = request.recipientFingerprints.firstIndex(of: fingerprint) {
            request.recipientFingerprints.remove(at: index)
        } else {
            request.recipientFingerprints.append(fingerprint)
        }
    }
}
