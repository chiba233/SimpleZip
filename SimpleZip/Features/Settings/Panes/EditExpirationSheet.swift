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
/// SimpleZip 不接触 passphrase。智能卡 stub 密钥会要求插卡 + 输入卡 PIN。
struct EditExpirationSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    let onApply: (GPGBackend.GPGKeyExpiration) -> Void

    @State private var expiration: GPGBackend.GPGKeyExpiration = .oneYear

    var body: some View {
        // 0.4.2 体例统一：并入现代弹窗壳。高度贴内容（DialogSection 自适应），不再写死 280。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "calendar.badge.clock",
                colors: [.indigo, .purple],
                title: L10n.text("settings.gpg.keys.editExpirationTitle"),
                subtitle: L10n.format("settings.gpg.keys.editExpirationSubject", key.userID, key.shortFingerprint)
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L10n.text("settings.gpg.newKey.expirationLabel"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $expiration) {
                            ForEach(GPGBackend.GPGKeyExpiration.allCases) { exp in
                                Text(exp.displayName).tag(exp)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Label(L10n.text("settings.gpg.keys.editExpirationNote"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.keys.applyButton"),
                confirmDisabled: false,
                confirm: {
                    onApply(expiration)
                    isPresented = false
                },
                cancel: { isPresented = false }
            ) {
                EmptyView()
            }
        }
        .frame(width: 480)
    }
}
