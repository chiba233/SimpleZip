//
//  AddSubkeySheet.swift
//  SimpleZip
//
//  给现有密钥「补票」追加子密钥的 sheet —— 比如给只有签名能力的旧密钥补一个加密子密钥。
//

import SwiftUI

/// 给现有密钥追加子密钥的 sheet（签名 / 加密 / 认证）。
///
/// 新子密钥由主密钥签名绑定 → 需要私钥 passphrase 解锁（走 loopback，跟新建密钥 / 添加 UID 一致，
/// SimpleZip 短暂持有几秒后释放）。**卡上 / stripped 密钥不走这条路**：调用方（GPGKeyRow）只对本机持有
/// 私钥的密钥（`hasSecretKey && !isSecretKeyStub`）显示入口，所以这里默认主私钥可用。
struct AddSubkeySheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    /// (capability, algorithm, expiration, passphrase)
    let onApply: (GPGBackend.GPGSubkeyCapability, GPGBackend.GPGKeyAlgorithm, GPGBackend.GPGKeyExpiration, String) -> Void

    @State private var capability: GPGBackend.GPGSubkeyCapability = .encrypt
    @State private var algorithm: GPGBackend.GPGKeyAlgorithm = .ed25519
    @State private var expiration: GPGBackend.GPGKeyExpiration = .oneYear
    @State private var passphrase = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.addSubkey.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("settings.gpg.addSubkey.subject", key.userID, key.shortFingerprint))
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
                formRow(label: L10n.text("settings.gpg.addSubkey.capabilityLabel")) {
                    Picker("", selection: $capability) {
                        ForEach(GPGBackend.GPGSubkeyCapability.allCases) { cap in
                            Text(cap.displayName).tag(cap)
                        }
                    }
                    .labelsHidden()
                }
                formRow(label: L10n.text("settings.gpg.newKey.algoLabel")) {
                    Picker("", selection: $algorithm) {
                        ForEach(GPGBackend.GPGKeyAlgorithm.allCases) { algo in
                            Text(algo.displayName).tag(algo)
                        }
                    }
                    .labelsHidden()
                }
                formRow(label: L10n.text("settings.gpg.newKey.expirationLabel")) {
                    Picker("", selection: $expiration) {
                        ForEach(GPGBackend.GPGKeyExpiration.allCases) { exp in
                            Text(exp.displayName).tag(exp)
                        }
                    }
                    .labelsHidden()
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
                    Text(L10n.text("settings.gpg.addSubkey.note"))
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
                Button(L10n.text("settings.gpg.addSubkey.applyButton")) { onClickApply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
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

    private func onClickApply() {
        validationError = nil
        guard !passphrase.isEmpty else {
            validationError = L10n.text("settings.gpg.addSubkey.requiredHint")
            return
        }
        onApply(capability, algorithm, expiration, passphrase)
        isPresented = false
    }
}

// MARK: - 子密钥用途本地化

extension GPGBackend.GPGSubkeyCapability {
    var displayName: String {
        switch self {
        case .sign: return L10n.text("settings.gpg.addSubkey.cap.sign")
        case .encrypt: return L10n.text("settings.gpg.addSubkey.cap.encrypt")
        case .authenticate: return L10n.text("settings.gpg.addSubkey.cap.auth")
        }
    }
}
