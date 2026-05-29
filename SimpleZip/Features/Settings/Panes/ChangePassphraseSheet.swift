//
//  ChangePassphraseSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 修改密钥 passphrase 的 sheet。三个 SecureField：旧 passphrase / 新 passphrase / 确认。
///
/// 旧 passphrase 走 gpg 的 `--passphrase` arg 形式（**会出现在 `ps`** —— 几秒就完，权衡可靠性）。
/// 新 passphrase 走 stdin `--command-fd 0` 喂 `passwd\n<new>\n<new>\nsave\n`，**不进 ps**。
/// 留空新 passphrase = 移除 passphrase（私钥不再加密）—— 弹 NSAlert 二次确认。
struct ChangePassphraseSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    let onApply: (String, String) -> Void  // (oldPassphrase, newPassphrase)

    @State private var oldPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var validationError: String?
    @State private var showsNoPassphraseConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.changePassphrase.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("settings.gpg.changePassphrase.subject", key.userID, key.shortFingerprint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)
            .background(.bar)

            VStack(alignment: .leading, spacing: 14) {
                formRow(label: L10n.text("settings.gpg.changePassphrase.oldLabel")) {
                    SecureField(L10n.text("settings.gpg.changePassphrase.oldPlaceholder"), text: $oldPassphrase)
                        .textFieldStyle(.roundedBorder)
                }
                formRow(label: L10n.text("settings.gpg.changePassphrase.newLabel")) {
                    SecureField(L10n.text("settings.gpg.changePassphrase.newPlaceholder"), text: $newPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: newPassphrase) { _ in validationError = nil }
                }
                formRow(label: L10n.text("settings.gpg.changePassphrase.confirmLabel")) {
                    SecureField(L10n.text("settings.gpg.changePassphrase.confirmPlaceholder"), text: $confirmPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: confirmPassphrase) { _ in validationError = nil }
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if newPassphrase.isEmpty && confirmPassphrase.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(L10n.text("settings.gpg.changePassphrase.removeHint"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("settings.gpg.changePassphrase.applyButton")) { onClickApply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(oldPassphrase.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
        .alert(L10n.text("settings.gpg.newKey.noPassphraseTitle"), isPresented: $showsNoPassphraseConfirm) {
            Button(L10n.text("settings.gpg.newKey.noPassphraseConfirm"), role: .destructive) {
                onApply(oldPassphrase, "")
                isPresented = false
            }
            Button(L10n.text("button.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.gpg.newKey.noPassphraseMessage"))
        }
    }

    @ViewBuilder
    private func formRow<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
        }
    }

    private func onClickApply() {
        validationError = nil
        if newPassphrase != confirmPassphrase {
            validationError = L10n.text("settings.gpg.newKey.passphraseMismatch")
            return
        }
        if newPassphrase.isEmpty {
            showsNoPassphraseConfirm = true
            return
        }
        onApply(oldPassphrase, newPassphrase)
        isPresented = false
    }
}
