//
//  AddUserIDSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 给现有密钥添加 User ID 的 sheet。
///
/// GPG 密钥可以挂多个 UID（不同邮箱 / 别名 / 用途）。新 UID 由主密钥签名 → 需要私钥 passphrase 解锁。
struct AddUserIDSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    let onApply: (String, String, String, String) -> Void  // (name, email, comment, passphrase)

    @State private var name = ""
    @State private var email = ""
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var validationError: String?

    var body: some View {
        // 0.4.2 体例统一：并入现代弹窗壳，高度贴内容。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "person.badge.plus",
                colors: [.teal, .green],
                title: L10n.text("settings.gpg.addUID.title"),
                subtitle: L10n.format("settings.gpg.addUID.subject", key.userID, key.shortFingerprint)
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
                    formRow(label: L10n.text("settings.gpg.newKey.nameLabel")) {
                        TextField(L10n.text("settings.gpg.newKey.namePlaceholder"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    formRow(label: L10n.text("settings.gpg.newKey.emailLabel")) {
                        TextField(L10n.text("settings.gpg.newKey.emailPlaceholder"), text: $email)
                            .textFieldStyle(.roundedBorder)
                    }
                    formRow(label: L10n.text("settings.gpg.addUID.commentLabel")) {
                        TextField(L10n.text("settings.gpg.addUID.commentPlaceholder"), text: $comment)
                            .textFieldStyle(.roundedBorder)
                    }
                    formRow(label: L10n.text("settings.gpg.addUID.unlockLabel")) {
                        SecureField(L10n.text("settings.gpg.addUID.unlockPlaceholder"), text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Label(L10n.text("settings.gpg.addUID.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.addUID.applyButton"),
                confirmDisabled: !canApply,
                confirm: { onClickApply() },
                cancel: { isPresented = false }
            ) {
                EmptyView()
            }
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private func formRow<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            content()
        }
    }

    private var canApply: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
            && !passphrase.isEmpty
    }

    private func onClickApply() {
        validationError = nil
        guard canApply else {
            validationError = L10n.text("settings.gpg.addUID.requiredHint")
            return
        }
        onApply(name, email, comment, passphrase)
        isPresented = false
    }
}
