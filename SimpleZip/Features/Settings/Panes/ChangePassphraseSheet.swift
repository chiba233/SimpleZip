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
        // 0.4.2 体例统一：并入现代弹窗壳，高度贴内容（不再写死 380）。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "key.horizontal.fill",
                colors: [.orange, .yellow],
                title: L10n.text("settings.gpg.changePassphrase.title"),
                subtitle: L10n.format("settings.gpg.changePassphrase.subject", key.userID, key.shortFingerprint)
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
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
                }

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if newPassphrase.isEmpty && confirmPassphrase.isEmpty {
                    Label(L10n.text("settings.gpg.changePassphrase.removeHint"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.changePassphrase.applyButton"),
                confirmDisabled: oldPassphrase.isEmpty,
                confirm: { onClickApply() },
                cancel: { isPresented = false }
            ) {
                EmptyView()
            }
        }
        .frame(width: 520)
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
