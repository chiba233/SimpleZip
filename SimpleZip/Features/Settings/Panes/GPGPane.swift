//
//  GPGPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import SwiftUI
import AppKit

/// GPG 设置面板 —— 用户在这里启用 / 关闭 GPG 集成、装 gnupg 后端、管理钥匙串、设置信任级别。
///
/// 分层策略：
/// - **普通区**（始终展开）：主开关 / 后端可用性徽章 / 安装提示 / 钥匙串列表（三分组）/ 导入公钥按钮。
///   多数用户只需要看这部分就够了。
/// - **高级区**（`DisclosureGroup`，默认折叠）：智能卡 / OpenPGP token 支持开关 / 后端路径 / 版本 /
///   pinentry-mac 状态 / gpg-agent 状态 / `$GNUPGHOME`。只在 `gpgEnabled` 时整段出现。
///
/// 钥匙串分三组（普通区里展示，因为这是核心交互）：
/// - **我的密钥（本机私钥）**：`hasSecretKey && !isSecretKeyStub`，签名 / 解密时不需要外置硬件。
/// - **我的密钥（智能卡 / Token）**：`hasSecretKey && isSecretKeyStub`，私钥在卡上，操作时需要插卡。
///   仅当用户在高级区勾上「启用智能卡支持」(`gpgSmartcardEnabled`) 后展示，避免不用卡的用户被干扰。
/// - **他人公钥**：`!hasSecretKey`，用来验签 + 加密给对方。
///
/// 信任级别 picker 跟着每行密钥走 —— 是 GPG 钥匙管理的核心交互，不该藏到高级区里。
struct GPGPane: View {
    @AppStorage(AppPreferences.Key.gpgEnabled) private var gpgEnabled = false
    @AppStorage(AppPreferences.Key.gpgSmartcardEnabled) private var gpgSmartcardEnabled = false

    @State private var systemInstallMessage: String?
    @State private var gpgAvailable = false
    @State private var pinentryAvailable = false
    @State private var gpgAgentAlive = false
    @State private var gpgVersion: String = L10n.text("settings.gpg.notFound")
    @State private var resolvedPath: String?

    @State private var keys: [GPGBackend.GPGKey] = []
    @State private var isLoadingKeys = false
    @State private var keyOperationMessage: String?
    @State private var isImportingFromSmartcard = false

    var body: some View {
        Form {
            mainToggleSection
            backendStatusSection
            if gpgEnabled && gpgAvailable {
                keyringSection
            }
            if gpgEnabled {
                advancedSection
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onAppear {
            refreshStatus()
            if gpgEnabled && gpgAvailable {
                refreshKeys()
            }
        }
        .onChange(of: gpgEnabled) { enabled in
            if enabled {
                refreshStatus()
                if gpgAvailable { refreshKeys() }
            }
        }
        .onChange(of: gpgSmartcardEnabled) { _ in
            // 智能卡开关变化不会改变 keys 列表内容，但分组渲染会变 —— 不需要额外刷数据。
        }
    }

    // MARK: - 普通区 sections

    private var mainToggleSection: some View {
        Section {
            SettingsToggleRow(
                title: L10n.text("settings.gpg.enabledTitle"),
                description: L10n.text("settings.gpg.enabledDescription"),
                isOn: $gpgEnabled
            )
        }
    }

    @ViewBuilder
    private var backendStatusSection: some View {
        Section(L10n.text("settings.gpg.backend.title")) {
            BackendStatusBadge(
                isOk: gpgAvailable,
                okText: L10n.text("settings.gpg.available"),
                failText: L10n.text("settings.gpg.missing")
            )

            Text(L10n.format("settings.gpg.resolvedVersion", gpgVersion))
                .font(.caption)
                .foregroundStyle(.secondary)

            if gpgAvailable && !pinentryAvailable {
                Text(L10n.text("settings.gpg.pinentryMissing"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !gpgAvailable {
                // Homebrew 安装提示 —— 命令本身已经含智能卡支持（gnupg 自带 scdaemon），
                // 文案里点明这件事，避免用户后续装了 GPG 才发现「智能卡为什么不识别」。
                SystemInstallCommandView(
                    title: L10n.text("settings.gpg.install.brew.title"),
                    command: "brew install gnupg pinentry-mac",
                    message: $systemInstallMessage
                )

                Text(L10n.text("settings.gpg.install.smartcardNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsActionRow(
                    title: L10n.text("settings.gpg.install.gpgsuite.title"),
                    description: "https://gpgtools.org/",
                    systemImage: "safari",
                    buttonTitle: L10n.text("settings.gpg.install.gpgsuite.button"),
                    action: openGPGToolsPage
                )
            }
        }
    }

    @ViewBuilder
    private var keyringSection: some View {
        Section(L10n.text("settings.gpg.keys.title")) {
            Text(L10n.text("settings.gpg.keys.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLoadingKeys {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("settings.gpg.keys.refresh"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if keys.isEmpty {
                Text(L10n.text("settings.gpg.keys.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                keyGroupsView
            }

            HStack(spacing: 8) {
                Button(L10n.text("settings.gpg.keys.importButton")) {
                    importPublicKey()
                }
                if gpgSmartcardEnabled {
                    Button(L10n.text("settings.gpg.smartcard.importButton")) {
                        importFromSmartcard()
                    }
                    .disabled(isImportingFromSmartcard)
                }
                Button(L10n.text("settings.gpg.keys.refresh")) {
                    refreshKeys()
                }
                .disabled(isLoadingKeys)
                Spacer()
            }

            if isImportingFromSmartcard {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("settings.gpg.smartcard.importing"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let keyOperationMessage {
                Text(keyOperationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 三分组渲染：「我的密钥（本机）/ 我的密钥（智能卡）/ 他人公钥」，每组带小标题。
    /// 没有该类密钥的组不展示空标题。
    @ViewBuilder
    private var keyGroupsView: some View {
        let myLocalKeys = keys.filter { $0.hasSecretKey && !$0.isSecretKeyStub }
        let smartcardKeys = keys.filter { $0.hasSecretKey && $0.isSecretKeyStub }
        let publicOnlyKeys = keys.filter { !$0.hasSecretKey }

        VStack(alignment: .leading, spacing: 12) {
            if !myLocalKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.mine.title"),
                    keys: myLocalKeys,
                    smartcard: false
                )
            }
            if gpgSmartcardEnabled && !smartcardKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.mineSmartcard.title"),
                    keys: smartcardKeys,
                    smartcard: true
                )
            }
            if !publicOnlyKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.others.title"),
                    keys: publicOnlyKeys,
                    smartcard: false
                )
            }
        }
    }

    @ViewBuilder
    private func keyGroup(title: String, keys: [GPGBackend.GPGKey], smartcard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            VStack(spacing: 0) {
                ForEach(keys) { key in
                    GPGKeyRow(
                        key: key,
                        smartcardStub: smartcard,
                        onTrustChange: { newLevel in
                            setTrust(for: key.fingerprint, to: newLevel)
                        }
                    )
                    if key.id != keys.last?.id {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    // MARK: - 高级区

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: L10n.text("settings.gpg.smartcard.enableTitle"),
                        description: L10n.text("settings.gpg.smartcard.enableDescription"),
                        isOn: $gpgSmartcardEnabled
                    )

                    if gpgAvailable {
                        Divider()
                        advancedInfoRow(
                            label: L10n.text("settings.gpg.advanced.pathLabel"),
                            value: resolvedPath ?? L10n.text("settings.gpg.notFound"),
                            monospaced: true
                        )
                        advancedInfoRow(
                            label: L10n.text("settings.gpg.advanced.pinentryLabel"),
                            value: pinentryAvailable
                                ? L10n.text("settings.gpg.advanced.statusOk")
                                : L10n.text("settings.gpg.advanced.statusMissing"),
                            tintMissing: !pinentryAvailable
                        )
                        advancedInfoRow(
                            label: L10n.text("settings.gpg.advanced.agentLabel"),
                            value: gpgAgentAlive
                                ? L10n.text("settings.gpg.advanced.agentAlive")
                                : L10n.text("settings.gpg.advanced.agentDown"),
                            tintMissing: !gpgAgentAlive
                        )
                        advancedInfoRow(
                            label: L10n.text("settings.gpg.advanced.gnupgHomeLabel"),
                            value: GPGBackend.gnupgHome() ?? L10n.text("settings.gpg.advanced.gnupgHomeDefault"),
                            monospaced: true
                        )
                    }
                }
            } label: {
                Text(L10n.text("settings.gpg.advanced.title"))
                    .font(.callout.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func advancedInfoRow(label: String, value: String, monospaced: Bool = false, tintMissing: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(tintMissing ? .orange : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 钥匙串操作

    private func refreshKeys() {
        guard GPGBackend.isAvailable() else { return }
        isLoadingKeys = true
        keyOperationMessage = nil
        Task {
            do {
                let fetched = try await GPGBackend.listKeys()
                await MainActor.run {
                    keys = fetched
                    isLoadingKeys = false
                }
            } catch {
                await MainActor.run {
                    keys = []
                    isLoadingKeys = false
                    keyOperationMessage = error.localizedDescription
                }
            }
        }
    }

    private func importPublicKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("settings.gpg.keys.importPanelTitle")
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await GPGBackend.importKey(from: url)
                await MainActor.run {
                    keyOperationMessage = L10n.text("settings.gpg.keys.importSucceeded")
                }
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? []
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.importFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 从插入的智能卡 / OpenPGP token 拉取公钥到 keyring。
    /// 失败常见原因：卡没插好 / scdaemon 没启动 / 卡上没设公钥 URL —— 全部归结成「请检查卡 / scdaemon」错误文案。
    private func importFromSmartcard() {
        isImportingFromSmartcard = true
        keyOperationMessage = nil
        Task {
            do {
                _ = try await GPGBackend.importFromSmartcard()
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? []
                    isImportingFromSmartcard = false
                    keyOperationMessage = L10n.text("settings.gpg.smartcard.importSucceeded")
                }
            } catch {
                await MainActor.run {
                    isImportingFromSmartcard = false
                    keyOperationMessage = L10n.format("settings.gpg.smartcard.importFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 修改某把密钥的信任级别。change 完成后重新 listKeys 确保 UI 反映 gpg 实际状态。
    private func setTrust(for fingerprint: String, to level: GPGBackend.GPGTrustLevel) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.setTrustLevel(fingerprint: fingerprint, to: level)
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? keys
                    keyOperationMessage = L10n.format("settings.gpg.trust.changeSucceeded", level.localizedTitle)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.trust.changeFailed", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 状态刷新

    private func refreshStatus() {
        gpgAvailable = GPGBackend.isAvailable()
        pinentryAvailable = GPGBackend.hasPinentryMac()
        resolvedPath = try? GPGBackend.resolve()
        Task {
            let version = await GPGBackend.version()
            let agentAlive = await GPGBackend.gpgAgentAlive()
            await MainActor.run {
                gpgVersion = version
                gpgAgentAlive = agentAlive
            }
        }
    }

    private func openGPGToolsPage() {
        guard let url = URL(string: "https://gpgtools.org/") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 信任级别本地化

extension GPGBackend.GPGTrustLevel {
    /// picker 里显示的文案。
    var localizedTitle: String {
        switch self {
        case .unknown: return L10n.text("settings.gpg.trust.unknown")
        case .never: return L10n.text("settings.gpg.trust.never")
        case .marginal: return L10n.text("settings.gpg.trust.marginal")
        case .full: return L10n.text("settings.gpg.trust.full")
        case .ultimate: return L10n.text("settings.gpg.trust.ultimate")
        case .expired: return L10n.text("settings.gpg.trust.expired")
        case .revoked: return L10n.text("settings.gpg.trust.revoked")
        }
    }
}

/// 钥匙串里一把密钥的展示行。
///
/// 布局：钥匙图标（本机实心 / 卡 stub 实心+卡角标 / 公钥空心）+ UID + 指纹 + 过期/撤销红字 + trust picker。
/// 卡 stub 行额外显示一句「私钥在卡上，签名 / 解密时需插卡」红字 caption。
private struct GPGKeyRow: View {
    let key: GPGBackend.GPGKey
    let smartcardStub: Bool
    let onTrustChange: (GPGBackend.GPGTrustLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                // 钥匙图标 ——「本机私钥」实心 + 标准蓝；「卡 stub」实心 + 卡片 badge；「他人公钥」空心灰。
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: key.hasSecretKey ? "key.fill" : "key")
                        .font(.system(size: 16))
                        .foregroundStyle(key.hasSecretKey ? Color.accentColor : Color.secondary)
                    if smartcardStub {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 14))
                            .offset(x: 4, y: 3)
                    }
                }
                .frame(width: 26)
                .help(rowIconHelp)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(key.userID)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if key.isExpired {
                            Text(L10n.text("settings.gpg.keys.expired"))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    Text(key.displayFingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                trustControl
            }

            if smartcardStub {
                Text(L10n.text("settings.gpg.smartcard.stubNote"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
    }

    /// 信任级别控件 —— expired / revoked 状态不可改，显示只读 chip；其它状态用 Picker 让用户改。
    @ViewBuilder
    private var trustControl: some View {
        if key.trust == .expired || key.trust == .revoked {
            Text(key.trust.localizedTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.12))
                )
        } else {
            Picker(
                "",
                selection: Binding(
                    get: { key.trust },
                    set: { newValue in
                        if newValue != key.trust {
                            onTrustChange(newValue)
                        }
                    }
                )
            ) {
                ForEach(GPGBackend.GPGTrustLevel.userAssignableCases, id: \.self) { level in
                    Text(level.localizedTitle).tag(level)
                }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help(L10n.text("settings.gpg.trust.pickerHelp"))
        }
    }

    private var rowIconHelp: String {
        if smartcardStub {
            return L10n.text("settings.gpg.smartcard.stubNote")
        }
        return key.hasSecretKey ? L10n.text("settings.gpg.keys.hasSecret") : ""
    }
}
