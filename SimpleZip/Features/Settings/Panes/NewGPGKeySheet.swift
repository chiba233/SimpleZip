//
//  NewGPGKeySheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 新建 GPG 密钥的对话框 sheet。
///
/// **保存位置在最顶**：用户先决定密钥归属（~/.gnupg/ 共享 vs SimpleZip 私有 ring），再填具体信息。
///
/// **私钥位置 caveat**：gpg 的 secring 是全局的，即使选「SimpleZip 私有」，私钥仍保存到
/// `~/.gnupg/private-keys-v1.d/`，只有公钥进 SimpleZip ring。
///
/// **Passphrase 走 loopback**：本 sheet 用 SecureField 收 passphrase + 确认，通过 stdin pipe 喂给
/// `gpg --pinentry-mode loopback --passphrase-fd 0`。原因：用户本机 `gpg-agent.conf` pinentry-program 配置
/// 不全 / GUI app 进程环境差异时 pinentry-mac 不弹出 → 之前那条路死等。改成 SimpleZip 收 passphrase 几秒后
/// 释放 —— 安全模型稍弱但**总是工作**。其它 GPG 操作（签名 / 解密）仍走 pinentry-mac（不在此 sheet 范围）。
///
/// 留空 passphrase = 创建无 passphrase 密钥（不安全，仅自动化 / 测试用）。UI 会显式警告 + 二次确认。
struct NewGPGKeySheet: View {
    @Binding var isPresented: Bool
    /// 创建成功回调，参数 = 新密钥 fingerprint（gpg 返回空时调用方需要 fallback refresh keyring）。
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var algorithm: GPGBackend.GPGKeyAlgorithm = .ed25519
    @State private var expiration: GPGBackend.GPGKeyExpiration = .oneYear
    @State private var destination: GPGBackend.GPGKeyringSource = .userKeyring
    @State private var addAuthSubkey = false
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var passphraseError: String?
    @State private var showsNoPassphraseConfirm = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    @State private var liveStatus = ""
    @State private var operationID = UUID()

    var body: some View {
        // 0.4.2 体例统一：并入现代弹窗壳。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "key.fill",
                colors: [.green, .teal],
                title: L10n.text("settings.gpg.newKey.title"),
                subtitle: L10n.text("settings.gpg.newKey.subtitle")
            )

            HeightCappedScrollView(maxHeight: 600) {
                VStack(alignment: .leading, spacing: 18) {
                    destinationSection
                    keyInfoSection
                    subkeysSection
                    passphraseSection
                    if isCreating {
                        liveStatusBanner
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.red.opacity(0.1))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.newKey.createButton"),
                confirmDisabled: !canCreate,
                confirm: { onClickCreate() },
                cancel: {
                    if isCreating {
                        cancelCreation()
                    } else {
                        isPresented = false
                    }
                }
            ) {
                EmptyView()
            }
        }
        .frame(width: 560)
        .alert(L10n.text("settings.gpg.newKey.noPassphraseTitle"), isPresented: $showsNoPassphraseConfirm) {
            Button(L10n.text("settings.gpg.newKey.noPassphraseConfirm"), role: .destructive) {
                create()
            }
            Button(L10n.text("button.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.gpg.newKey.noPassphraseMessage"))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var destinationSection: some View {
        DialogSection(L10n.text("settings.gpg.newKey.destinationSection")) {
            Picker("", selection: $destination) {
                Text(L10n.text("settings.gpg.newKey.dest.userKeyring"))
                    .tag(GPGBackend.GPGKeyringSource.userKeyring)
                Text(L10n.text("settings.gpg.newKey.dest.simpleZipKeyring"))
                    .tag(GPGBackend.GPGKeyringSource.simpleZipKeyring)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(isCreating)

            Text(L10n.text(destination == .userKeyring
                           ? "settings.gpg.newKey.dest.userKeyring.detail"
                           : "settings.gpg.newKey.dest.simpleZipKeyring.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyInfoSection: some View {
        DialogSection(L10n.text("settings.gpg.newKey.keyInfoSection")) {
            formRow(label: L10n.text("settings.gpg.newKey.nameLabel")) {
                TextField(L10n.text("settings.gpg.newKey.namePlaceholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }
            formRow(label: L10n.text("settings.gpg.newKey.emailLabel")) {
                TextField(L10n.text("settings.gpg.newKey.emailPlaceholder"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }
            formRow(label: L10n.text("settings.gpg.newKey.algoLabel")) {
                Picker("", selection: $algorithm) {
                    ForEach(GPGBackend.GPGKeyAlgorithm.allCases) { algo in
                        Text(algo.displayName).tag(algo)
                    }
                }
                .labelsHidden()
                .disabled(isCreating)
            }
            formRow(label: L10n.text("settings.gpg.newKey.expirationLabel")) {
                Picker("", selection: $expiration) {
                    ForEach(GPGBackend.GPGKeyExpiration.allCases) { exp in
                        Text(exp.displayName).tag(exp)
                    }
                }
                .labelsHidden()
                .disabled(isCreating)
            }
        }
    }

    @ViewBuilder
    private func formRow<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
        }
    }

    /// **子密钥配置区**：默认就有签名（主密钥）+ 加密 subkey；可选加认证 subkey。
    @ViewBuilder
    private var subkeysSection: some View {
        DialogSection(L10n.text("settings.gpg.newKey.subkeysSection")) {
            // 默认有的两把（不可关）—— 给用户看清楚自己即将得到什么。
            VStack(alignment: .leading, spacing: 6) {
                bundledCapabilityRow(label: L10n.text("settings.gpg.newKey.subkey.signFixed"), detail: L10n.text("settings.gpg.newKey.subkey.signFixedDetail"))
                bundledCapabilityRow(label: L10n.text("settings.gpg.newKey.subkey.encryptFixed"), detail: L10n.text("settings.gpg.newKey.subkey.encryptFixedDetail"))
            }

            Divider().padding(.vertical, 4)

            // 可选的认证 subkey
            Toggle(isOn: $addAuthSubkey) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.gpg.newKey.subkey.authOption"))
                        .font(.callout)
                    Text(L10n.text("settings.gpg.newKey.subkey.authOptionDetail"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(isCreating)
        }
    }

    @ViewBuilder
    private func bundledCapabilityRow(label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// **Passphrase 输入区**（替换原 pinentry-mac 说明卡片）。
    /// 用 SecureField 收 passphrase + 确认；passphrase 走 loopback 模式喂 gpg。
    @ViewBuilder
    private var passphraseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.text("settings.gpg.newKey.passphraseHeader"))
                    .font(.callout.weight(.semibold))
            }

            Text(L10n.text("settings.gpg.newKey.passphraseExplain"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            formRow(label: L10n.text("settings.gpg.newKey.passphraseLabel")) {
                SecureField(L10n.text("settings.gpg.newKey.passphrasePlaceholder"), text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
                    .onChange(of: passphrase) { _ in passphraseError = nil }
            }
            formRow(label: L10n.text("settings.gpg.newKey.passphraseConfirmLabel")) {
                SecureField(L10n.text("settings.gpg.newKey.passphraseConfirmPlaceholder"), text: $passphraseConfirm)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
                    .onChange(of: passphraseConfirm) { _ in passphraseError = nil }
            }

            if let passphraseError {
                Text(passphraseError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            // 留空时的明显警告，让用户知道这条路是「不安全密钥」。
            if passphrase.isEmpty && passphraseConfirm.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(L10n.text("settings.gpg.newKey.noPassphraseHint"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var liveStatusBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(liveStatus.isEmpty ? L10n.text("settings.gpg.newKey.creating") : liveStatus)
                    .font(.callout.weight(.medium))
                Text(L10n.text("settings.gpg.newKey.cancelHint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Logic

    private var canCreate: Bool {
        let nameTrimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailTrimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !nameTrimmed.isEmpty
            && emailTrimmed.contains("@")
            && emailTrimmed.count >= 3
            && !isCreating
    }

    /// 点「创建」时的入口：先做 passphrase 校验，再决定走「无 passphrase 二次确认」还是直接 create。
    private func onClickCreate() {
        passphraseError = nil
        errorMessage = nil

        if passphrase != passphraseConfirm {
            passphraseError = L10n.text("settings.gpg.newKey.passphraseMismatch")
            return
        }

        if passphrase.isEmpty {
            // 二次确认「真的不要 passphrase 吗」
            showsNoPassphraseConfirm = true
        } else {
            create()
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        liveStatus = L10n.text("settings.gpg.newKey.statusStarting")
        operationID = UUID()
        let opID = operationID
        let pp = passphrase  // 拷贝一份避免 closure 捕获 @State 的语义陷阱
        Task {
            do {
                let fingerprint = try await GPGBackend.createKey(
                    name: name,
                    email: email,
                    algorithm: algorithm,
                    expiration: expiration,
                    into: destination,
                    addAuthenticationSubkey: addAuthSubkey,
                    passphrase: pp,
                    outputObserver: { chunk in
                        Task { @MainActor in
                            updateStatus(from: chunk)
                        }
                    },
                    operationID: opID
                )
                await MainActor.run {
                    isCreating = false
                    isPresented = false
                    onCreated(fingerprint)
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    liveStatus = ""
                    if error is CancellationError {
                        errorMessage = L10n.text("settings.gpg.newKey.cancelled")
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cancelCreation() {
        BackendProcessRunner.cancelRunningCommand(operationID: operationID)
    }

    /// 解析 `--status-fd 1` 输出的 `[GNUPG:] XXX` 状态行更新 liveStatus。
    /// loopback 模式下 PINENTRY_LAUNCHED 不会出现；主要看 PROGRESS。
    private func updateStatus(from chunk: String) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[GNUPG:]") else { continue }
            let payload = trimmed.dropFirst("[GNUPG:]".count).trimmingCharacters(in: .whitespaces)
            let token = payload.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? payload
            switch token {
            case "PROGRESS":
                if payload.contains("need_entropy") {
                    liveStatus = L10n.text("settings.gpg.newKey.statusNeedEntropy")
                } else if liveStatus.isEmpty || liveStatus == L10n.text("settings.gpg.newKey.statusStarting") {
                    liveStatus = L10n.text("settings.gpg.newKey.statusGenerating")
                }
            case "KEY_CONSIDERED":
                if liveStatus == L10n.text("settings.gpg.newKey.statusStarting") {
                    liveStatus = L10n.text("settings.gpg.newKey.statusGenerating")
                }
            default:
                break
            }
        }
    }
}

// MARK: - 算法 / 过期时间本地化

extension GPGBackend.GPGKeyAlgorithm {
    var displayName: String {
        switch self {
        case .ed25519: return L10n.text("settings.gpg.newKey.algo.ed25519")
        case .rsa4096: return L10n.text("settings.gpg.newKey.algo.rsa4096")
        case .rsa3072: return L10n.text("settings.gpg.newKey.algo.rsa3072")
        case .rsa2048: return L10n.text("settings.gpg.newKey.algo.rsa2048")
        }
    }
}

extension GPGBackend.GPGKeyExpiration {
    var displayName: String {
        switch self {
        case .never: return L10n.text("settings.gpg.newKey.exp.never")
        case .oneYear: return L10n.text("settings.gpg.newKey.exp.1y")
        case .twoYears: return L10n.text("settings.gpg.newKey.exp.2y")
        case .fiveYears: return L10n.text("settings.gpg.newKey.exp.5y")
        }
    }
}
