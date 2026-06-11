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

    var body: some View {
        // 0.4.2 体例统一：并入现代弹窗壳，高度贴内容。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "key.viewfinder",
                colors: [.purple, .indigo],
                title: L10n.text("settings.gpg.addSubkey.title"),
                subtitle: L10n.format("settings.gpg.addSubkey.subject", key.userID, key.shortFingerprint)
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
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
                        SecureField(L10n.text("settings.gpg.addSubkey.unlockPlaceholder"), text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Label(L10n.text("settings.gpg.addSubkey.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.addSubkey.applyButton"),
                confirmDisabled: false,
                confirm: {
                    // passphrase 不强制非空 —— 主密钥可能本来就没设 passphrase(无密码密钥)。
                    // 若密钥确实有 passphrase 而这里留空 / 填错,gpg 会失败,错误回到 keyOperationMessage。
                    onApply(capability, algorithm, expiration, passphrase)
                    isPresented = false
                },
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
