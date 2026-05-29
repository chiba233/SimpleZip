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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.addUID.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("settings.gpg.addUID.subject", key.userID, key.shortFingerprint))
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

                if let validationError {
                    Text(validationError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("settings.gpg.addUID.note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("settings.gpg.addUID.applyButton")) { onClickApply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
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
