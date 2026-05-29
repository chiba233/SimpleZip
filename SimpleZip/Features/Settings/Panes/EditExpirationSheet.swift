//
//  EditExpirationSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 修改密钥过期时间的 sheet。
///
/// 走 `gpg --edit-key <fpr> expire <duration> save`。`gpg-agent + pinentry-mac` 会弹密码框收私钥 passphrase，
/// SimpleZip 不接触 passphrase（[[feedback-gpg-release-emphasis]]）。智能卡 stub 密钥会要求插卡 + 输入卡 PIN。
struct EditExpirationSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    let onApply: (GPGBackend.GPGKeyExpiration) -> Void

    @State private var expiration: GPGBackend.GPGKeyExpiration = .oneYear

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.keys.editExpirationTitle"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("settings.gpg.keys.editExpirationSubject", key.userID, key.shortFingerprint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)
            .background(.bar)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L10n.text("settings.gpg.newKey.expirationLabel"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: $expiration) {
                        ForEach(GPGBackend.GPGKeyExpiration.allCases) { exp in
                            Text(exp.displayName).tag(exp)
                        }
                    }
                    .labelsHidden()
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("settings.gpg.keys.editExpirationNote"))
                        .font(.caption)
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
                Button(L10n.text("button.cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.text("settings.gpg.keys.applyButton")) {
                    onApply(expiration)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 480, height: 280)
    }
}
