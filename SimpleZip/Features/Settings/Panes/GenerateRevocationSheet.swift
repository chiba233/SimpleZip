//
//  GenerateRevocationSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 生成撤销证书的 sheet。
///
/// 撤销证书是「日后宣告密钥失效」的 emergency tool —— 一旦私钥被偷或丢失，把这份 `.asc` 文件发到 keyserver
/// 就能告诉所有用过这把公钥的人「别再信任了」。**应该在密钥还能用时就生成出来并安全保存到离线介质**，
/// 等到私钥真出事时再生成就来不及了。
///
/// 走 `gpg --gen-revoke <fpr>`。`gpg-agent + pinentry-mac` 会弹密码框收私钥 passphrase。SimpleZip 不接触 passphrase。
struct GenerateRevocationSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    /// (reason, description) 用户确认后回调。调用方负责弹 NSSavePanel + 写文件。
    let onGenerate: (GPGBackend.GPGRevocationReason, String) -> Void

    @State private var reason: GPGBackend.GPGRevocationReason = .none
    @State private var description: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.keys.revokeTitle"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("settings.gpg.keys.revokeSubject", key.userID, key.shortFingerprint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 何时该生成 / 为什么提前生成的关键说明 —— 用户经常不知道这是干啥的。
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                        Text(L10n.text("settings.gpg.keys.revokeIntro"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.1))
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("settings.gpg.keys.revokeReasonSection"))
                            .font(.callout.weight(.semibold))

                        Picker("", selection: $reason) {
                            Text(L10n.text("settings.gpg.keys.revokeReason.none")).tag(GPGBackend.GPGRevocationReason.none)
                            Text(L10n.text("settings.gpg.keys.revokeReason.compromised")).tag(GPGBackend.GPGRevocationReason.compromised)
                            Text(L10n.text("settings.gpg.keys.revokeReason.superseded")).tag(GPGBackend.GPGRevocationReason.superseded)
                            Text(L10n.text("settings.gpg.keys.revokeReason.notUsed")).tag(GPGBackend.GPGRevocationReason.notUsed)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("settings.gpg.keys.revokeDescriptionLabel"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("settings.gpg.keys.revokeDescriptionPlaceholder"), text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...5)
                        Text(L10n.text("settings.gpg.keys.revokeDescriptionHint"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(L10n.text("settings.gpg.newKey.passphraseNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.text("settings.gpg.keys.revokeGenerateButton")) {
                    onGenerate(reason, description)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 540)
    }
}
