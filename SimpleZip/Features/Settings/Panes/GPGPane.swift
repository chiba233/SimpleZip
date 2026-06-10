//
//  GPGPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// GPG 设置面板 —— 用户在这里启用 / 关闭 GPG 集成、装 gnupg 后端、管理钥匙串、设置信任级别 / 默认签名密钥。
///
/// **分层策略**：
/// - **普通区**（始终展开）：主开关 / 后端可用性 / 默认签名密钥状态行 / 智能卡状态行（卡插入时）/ 钥匙串四分组 / 操作按钮组。
/// - **高级区**（`DisclosureGroup`，默认折叠）：智能卡 / OpenPGP token 支持 toggle / 后端路径 / 版本 / pinentry-mac / gpg-agent / GNUPGHOME。
///
/// **钥匙串四分组**（按 `(hasSecretKey, isSecretKeyStub, source)` 切分）：
/// - 我的密钥（本机私钥）：`hasSecretKey && !isSecretKeyStub`
/// - 我的密钥（智能卡 / Token）：`hasSecretKey && isSecretKeyStub`，仅 `gpgSmartcardEnabled` 时展示
/// - 他人公钥（来自 GPG keyring）：`!hasSecretKey && source == .userKeyring`
/// - 他人公钥（仅 SimpleZip）：`!hasSecretKey && source == .simpleZipKeyring`，**不**污染用户 `~/.gnupg/`
///
/// **每行展示**：UID / 主密钥短指纹 / 信任级别 picker / 子密钥列表（capability 图标 + 卡上 / stripped 标记）/
/// 默认签名密钥按钮（仅本机私钥 + 卡 stub 行）/ 右键 context menu（复制指纹 / 导出公钥）。
struct GPGPane: View {
    @AppStorage(AppPreferences.Key.gpgEnabled) private var gpgEnabled = false
    @AppStorage(AppPreferences.Key.gpgSmartcardEnabled) private var gpgSmartcardEnabled = false
    @AppStorage(AppPreferences.Key.gpgDefaultSigningKeyFingerprint) private var defaultSigningKeyFingerprint = ""
    /// 签名密钥选择策略 —— false 静默 / true 询问。在「默认值」段里的 picker 控制。
    @AppStorage(AppPreferences.Key.gpgPromptForSigningKey) private var promptForSigningKey = false

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

    @State private var cardStatus: GPGBackend.GPGCardStatus?
    @State private var isDetectingCard = false

    @State private var isShowingNewKeySheet = false

    /// 待删除密钥的待确认 alert 状态。nil = 不显示。
    @State private var pendingDeleteKey: GPGBackend.GPGKey?
    /// 「修改过期时间」sheet 的目标密钥。nil = 不显示。
    @State private var pendingExpirationKey: GPGBackend.GPGKey?
    /// 「生成撤销证书」sheet 的目标密钥。nil = 不显示。
    @State private var pendingRevocationKey: GPGBackend.GPGKey?
    /// 「修改 passphrase」sheet 的目标密钥。
    @State private var pendingPassphraseKey: GPGBackend.GPGKey?
    /// 「添加 User ID」sheet 的目标密钥。
    @State private var pendingAddUIDKey: GPGBackend.GPGKey?
    /// 「补票」添加子密钥 sheet 的目标密钥。
    @State private var pendingAddSubkeyKey: GPGBackend.GPGKey?

    var body: some View {
        Form {
            mainToggleSection
            backendStatusSection
            if gpgEnabled && gpgAvailable {
                keyringSection
                defaultsSection
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
                if gpgSmartcardEnabled {
                    detectCard()
                }
            }
        }
        .onChange(of: gpgEnabled) { enabled in
            if enabled {
                refreshStatus()
                if gpgAvailable { refreshKeys() }
            }
        }
        .onChange(of: gpgSmartcardEnabled) { enabled in
            if enabled && gpgAvailable {
                detectCard()
            } else {
                cardStatus = nil
            }
        }
        .sheet(isPresented: $isShowingNewKeySheet) {
            NewGPGKeySheet(isPresented: $isShowingNewKeySheet) { fingerprint in
                keyOperationMessage = fingerprint.isEmpty
                    ? L10n.text("settings.gpg.newKey.succeededNoFingerprint")
                    : L10n.format("settings.gpg.newKey.succeeded", String(fingerprint.suffix(16)))
                refreshKeys()
            }
        }
        // 修改过期时间 sheet
        .sheet(item: $pendingExpirationKey) { key in
            EditExpirationSheet(key: key, isPresented: Binding(
                get: { pendingExpirationKey != nil },
                set: { if !$0 { pendingExpirationKey = nil } }
            )) { newExpiration in
                applyExpiration(for: key, expiration: newExpiration)
            }
        }
        // 修改 passphrase sheet
        .sheet(item: $pendingPassphraseKey) { key in
            ChangePassphraseSheet(key: key, isPresented: Binding(
                get: { pendingPassphraseKey != nil },
                set: { if !$0 { pendingPassphraseKey = nil } }
            )) { oldPP, newPP in
                applyPassphraseChange(for: key, oldPassphrase: oldPP, newPassphrase: newPP)
            }
        }
        // 添加 User ID sheet
        .sheet(item: $pendingAddUIDKey) { key in
            AddUserIDSheet(key: key, isPresented: Binding(
                get: { pendingAddUIDKey != nil },
                set: { if !$0 { pendingAddUIDKey = nil } }
            )) { name, email, comment, passphrase in
                applyAddUserID(for: key, name: name, email: email, comment: comment, passphrase: passphrase)
            }
        }
        // 补票添加子密钥 sheet
        .sheet(item: $pendingAddSubkeyKey) { key in
            AddSubkeySheet(key: key, isPresented: Binding(
                get: { pendingAddSubkeyKey != nil },
                set: { if !$0 { pendingAddSubkeyKey = nil } }
            )) { capability, algorithm, expiration, passphrase in
                applyAddSubkey(for: key, capability: capability, algorithm: algorithm, expiration: expiration, passphrase: passphrase)
            }
        }
        // 生成撤销证书 sheet
        .sheet(item: $pendingRevocationKey) { key in
            GenerateRevocationSheet(key: key, isPresented: Binding(
                get: { pendingRevocationKey != nil },
                set: { if !$0 { pendingRevocationKey = nil } }
            )) { reason, description, destination in
                generateRevocation(for: key, reason: reason, description: description, destination: destination)
            }
        }
        // 删除密钥确认 alert —— 走 macOS 标准 destructive alert，二次确认。
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { pendingDeleteKey != nil },
                set: { if !$0 { pendingDeleteKey = nil } }
            ),
            presenting: pendingDeleteKey
        ) { key in
            Button(L10n.text("settings.gpg.keys.deleteConfirmButton"), role: .destructive) {
                deleteKey(key)
            }
            Button(L10n.text("button.cancel"), role: .cancel) {
                pendingDeleteKey = nil
            }
        } message: { key in
            Text(deleteAlertMessage(for: key))
        }
    }

    private var deleteAlertTitle: String {
        guard let key = pendingDeleteKey else { return "" }
        if key.hasSecretKey {
            return L10n.format("settings.gpg.keys.deleteSecretTitle", key.userID)
        }
        return L10n.format("settings.gpg.keys.deletePublicTitle", key.userID)
    }

    private func deleteAlertMessage(for key: GPGBackend.GPGKey) -> String {
        let fp = key.shortFingerprint
        let ringName: String = key.source == .userKeyring
            ? L10n.text("settings.gpg.keys.ringNameUser")
            : L10n.text("settings.gpg.keys.ringNameSimpleZip")
        if key.isSecretKeyOnSmartcard {
            return L10n.format("settings.gpg.keys.deleteSmartcardMessage", fp, ringName)
        }
        if key.hasSecretKey {
            return L10n.format("settings.gpg.keys.deleteSecretMessage", fp, ringName)
        }
        return L10n.format("settings.gpg.keys.deletePublicMessage", fp, ringName)
    }

    // MARK: - 普通区 sections

    private var mainToggleSection: some View {
        Section {
            SettingsToggleRow(
                title: L10n.text("settings.gpg.enabledTitle"),
                description: L10n.text("settings.gpg.enabledDescription"),
                systemImage: "key",
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

            defaultSigningKeyRow

            if gpgSmartcardEnabled {
                cardStatusRow
            }

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

            // 操作按钮组：新建 / 导入到 ~/.gnupg / 导入到 SimpleZip / (智能卡) / 刷新
            HStack(spacing: 8) {
                Button(L10n.text("settings.gpg.newKey.button")) {
                    isShowingNewKeySheet = true
                }
                Button(L10n.text("settings.gpg.keys.importUserButton")) {
                    importKey(into: .userKeyring)
                }
                Button(L10n.text("settings.gpg.keys.importSimpleZipButton")) {
                    importKey(into: .simpleZipKeyring)
                }
                if gpgSmartcardEnabled {
                    Button(L10n.text("settings.gpg.smartcard.importButton")) {
                        importFromSmartcard()
                    }
                    .disabled(isImportingFromSmartcard)
                }
                Button(L10n.text("settings.gpg.keys.refresh")) {
                    refreshKeys()
                    if gpgSmartcardEnabled { detectCard() }
                }
                .disabled(isLoadingKeys)
                Spacer()
            }

            // 两个导入入口的区别说明 —— 用户反馈光看按钮名不知道差异（目录不同 / 私有钥匙串在应用内 / 不污染命令行 gpg）。
            Text(L10n.text("settings.gpg.keys.importHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    /// 「当前默认签名密钥」一行展示 + 清除按钮。fingerprint 为空 = 「未设置」灰字。
    /// 设置 / 清除走 GPGKeyRow 的「设为默认」按钮，不在这一行操作 —— 这一行只展示当前状态。
    @ViewBuilder
    private var defaultSigningKeyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "signature")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(defaultSigningKeyFingerprint.isEmpty ? .secondary : Color.accentColor)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("settings.gpg.defaultSigning.label"))
                    .font(.caption.weight(.medium))
                if defaultSigningKeyFingerprint.isEmpty {
                    Text(L10n.text("settings.gpg.defaultSigning.none"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let matched = keys.first { $0.fingerprint == defaultSigningKeyFingerprint }
                    // 注意：`defaultSigningKeyFingerprint.suffix(16)` 返回 `Substring`，Substring 桥到 CVarArg 时
                    // 被 printf 当字符序列化导致出现 `"\"D\"", "\"8\"",` 一团乱码。必须先 String(...) 转一遍。
                    Text(matched.map { "\($0.userID) · \($0.shortFingerprint)" }
                         ?? L10n.format("settings.gpg.defaultSigning.unknownFingerprint", String(defaultSigningKeyFingerprint.suffix(16))))
                        .font(.caption)
                        .foregroundStyle(matched == nil ? .orange : .secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if !defaultSigningKeyFingerprint.isEmpty {
                Button(L10n.text("settings.gpg.defaultSigning.clear")) {
                    defaultSigningKeyFingerprint = ""
                    keyOperationMessage = L10n.text("settings.gpg.defaultSigning.cleared")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// 「当前插入卡」一行展示 —— 仅智能卡支持开启时出现。卡未检测到时显示「未检测到卡 [检测]」。
    /// 检测到时显示：vendor + serial + 反查的主密钥 UID（找不到对应主密钥时给「卡上 subkey 在本机 keyring 找不到 → 「拉公钥」提示」）。
    @ViewBuilder
    private var cardStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "creditcard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(cardStatus == nil ? Color.secondary : Color.orange)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("settings.gpg.smartcard.statusLabel"))
                    .font(.caption.weight(.medium))
                if isDetectingCard {
                    Text(L10n.text("settings.gpg.smartcard.detecting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let card = cardStatus {
                    cardDetailText(card)
                } else {
                    Text(L10n.text("settings.gpg.smartcard.notDetected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L10n.text("settings.gpg.smartcard.detect")) {
                detectCard()
            }
            .controlSize(.small)
            .disabled(isDetectingCard)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cardDetailText(_ card: GPGBackend.GPGCardStatus) -> some View {
        let identity = card.holderName ?? card.vendor ?? L10n.text("settings.gpg.smartcard.unnamedCard")
        let serialText = card.serial.map { L10n.format("settings.gpg.smartcard.serial", $0) } ?? ""
        let header = "\(identity) \(serialText)".trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 1) {
            Text(header)
                .font(.caption)
                .textSelection(.enabled)
            if let linkedFp = card.linkedPrimaryFingerprint, let linkedKey = keys.first(where: { $0.fingerprint == linkedFp }) {
                Text(L10n.format("settings.gpg.smartcard.linkedKey", linkedKey.userID, linkedKey.shortFingerprint))
                    .font(.caption2)
                    .foregroundStyle(Color.green)
                    .textSelection(.enabled)
            } else {
                Text(L10n.text("settings.gpg.smartcard.linkedKeyMissing"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 四分组渲染。空组不渲染。
    ///
    /// 关闭智能卡 toggle 时，智能卡 stub 密钥**降级**到对应「他人公钥」组（按 source 路由）——
    /// 用户关掉智能卡功能 = 不想再追踪卡上密钥分组；但他们本机有公钥，**不能完全消失**。降级后这些密钥
    /// 视觉上跟普通公钥同居一组（卡上 / stripped badge 仍展示，告诉用户真实状态），但行尾的「设为默认签名密钥」
    /// 按钮自动消失（不让用户给一个「无私钥可用」状态的密钥设默认签名）。
    @ViewBuilder
    private var keyGroupsView: some View {
        // 按 (source, hasSecretKey, isSecretKeyStub) 拆 **5 组**：
        // - 我的密钥（本机私钥 - ~/.gnupg/）：user + secret + 非 stub
        // - 我的密钥（智能卡 / OpenPGP token）：user + secret + stub —— 跟 source 强绑（卡上密钥只可能在用户 GNUPGHOME 里）
        // - 我的密钥（SimpleZip 私有）：simpleZip + secret —— 用户在 SimpleZip 私有 homedir 里新建 / 导入私钥的目标组
        // - 他人公钥（GPG keyring）：user + 无 secret （智能卡 toggle 关时 user stub 也算）
        // - 他人公钥（仅 SimpleZip）：simpleZip + 无 secret
        let myLocalUserKeys = keys.filter { $0.hasSecretKey && !$0.isSecretKeyStub && $0.source == .userKeyring }
        let mySmartcardKeys = keys.filter { $0.hasSecretKey && $0.isSecretKeyStub && $0.source == .userKeyring }
        let mySimpleZipKeys = keys.filter { $0.hasSecretKey && $0.source == .simpleZipKeyring }
        let publicGPGKeys = keys.filter { key in
            guard key.source == .userKeyring else { return false }
            if !key.hasSecretKey { return true }
            if !gpgSmartcardEnabled && key.isSecretKeyStub { return true }
            return false
        }
        let publicSZKeys = keys.filter { key in
            guard key.source == .simpleZipKeyring else { return false }
            return !key.hasSecretKey
        }

        VStack(alignment: .leading, spacing: 14) {
            if !myLocalUserKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.mine.title"),
                    keys: myLocalUserKeys
                )
            }
            if gpgSmartcardEnabled && !mySmartcardKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.mineSmartcard.title"),
                    keys: mySmartcardKeys
                )
            }
            if !mySimpleZipKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.mineSimpleZip.title"),
                    keys: mySimpleZipKeys
                )
            }
            if !publicGPGKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.othersGPG.title"),
                    keys: publicGPGKeys
                )
            }
            if !publicSZKeys.isEmpty {
                keyGroup(
                    title: L10n.text("settings.gpg.keys.othersSimpleZip.title"),
                    keys: publicSZKeys
                )
            }
        }
    }

    @ViewBuilder
    private func keyGroup(title: String, keys: [GPGBackend.GPGKey]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            VStack(spacing: 0) {
                ForEach(keys) { key in
                    GPGKeyRow(
                        key: key,
                        isDefaultSigningKey: defaultSigningKeyFingerprint == key.fingerprint,
                        // canBeDefaultSigner = keyring 里有任何形式的私钥引用（本机 / 智能卡 stub / stripped 都算）。
                        // 智能卡 UI toggle 只影响**展示**（分组 + 卡按钮），不影响功能 —— gpg + 插卡仍可签名，
                        // 所以「设为默认」按钮在所有 hasSecretKey 的行上保留，让用户能把卡上密钥设为默认签名。
                        canBeDefaultSigner: key.hasSecretKey,
                        onTrustChange: { newLevel in
                            setTrust(for: key, to: newLevel)
                        },
                        onSetDefaultSigning: {
                            defaultSigningKeyFingerprint = key.fingerprint
                            keyOperationMessage = L10n.format("settings.gpg.defaultSigning.set", key.userID)
                        },
                        onCopyFingerprint: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key.fingerprint, forType: .string)
                            keyOperationMessage = L10n.text("settings.gpg.keys.fingerprintCopied")
                        },
                        onExportPublicKey: {
                            exportPublicKey(for: key)
                        },
                        onExportPrivateKey: {
                            exportPrivateKey(for: key)
                        },
                        onChangePassphrase: {
                            pendingPassphraseKey = key
                        },
                        onAddSubkey: {
                            pendingAddSubkeyKey = key
                        },
                        onAddUserID: {
                            pendingAddUIDKey = key
                        },
                        onEditExpiration: {
                            pendingExpirationKey = key
                        },
                        onGenerateRevocation: {
                            pendingRevocationKey = key
                        },
                        onDelete: {
                            pendingDeleteKey = key
                        }
                    )
                    if key.id != keys.last?.id {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    // MARK: - 默认值

    /// 「默认值」子段 —— 集中放跟「创建 / 解压时 GPG 默认行为」相关的开关。当前只有「签名密钥选择策略」一项。
    /// 默认密钥本身（fingerprint）仍由钥匙串列表里每行的「设为默认」按钮管理，跟 picker 的「视觉对齐」放在两个 section。
    @ViewBuilder
    private var defaultsSection: some View {
        Section(L10n.text("settings.gpg.defaults.title")) {
            SettingsControlRow(
                title: L10n.text("settings.gpg.defaults.signingStrategy.label"),
                description: L10n.text(promptForSigningKey
                    ? "settings.gpg.defaults.signingStrategy.askDescription"
                    : "settings.gpg.defaults.signingStrategy.silentDescription"),
                systemImage: "signature"
            ) {
                Picker("", selection: $promptForSigningKey) {
                    Text(L10n.text("settings.gpg.defaults.signingStrategy.silent"))
                        .tag(false)
                    Text(L10n.text("settings.gpg.defaults.signingStrategy.ask"))
                        .tag(true)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
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
                        systemImage: "creditcard",
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
                        advancedInfoRow(
                            label: L10n.text("settings.gpg.advanced.szRingLabel"),
                            value: GPGBackend.simpleZipPubringPath().path,
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
            SettingsRowIcon(systemImage: nil)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
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

    /// 导入公钥到指定 ring。`.userKeyring` 进 `~/.gnupg/`（CLI 共享）；`.simpleZipKeyring` 进 SimpleZip 私有 ring（不污染 CLI）。
    private func importKey(into ring: GPGBackend.GPGKeyringSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = ring == .simpleZipKeyring
            ? L10n.text("settings.gpg.keys.importSimpleZipPanelTitle")
            : L10n.text("settings.gpg.keys.importPanelTitle")
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await GPGBackend.importKey(from: url, into: ring)
                await MainActor.run {
                    keyOperationMessage = ring == .simpleZipKeyring
                        ? L10n.text("settings.gpg.keys.importSimpleZipSucceeded")
                        : L10n.text("settings.gpg.keys.importSucceeded")
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
                // 顺手刷新一下卡 binding 显示。
                detectCard()
            } catch {
                await MainActor.run {
                    isImportingFromSmartcard = false
                    keyOperationMessage = L10n.format("settings.gpg.smartcard.importFailed", error.localizedDescription)
                }
            }
        }
    }

    private func setTrust(for key: GPGBackend.GPGKey, to level: GPGBackend.GPGTrustLevel) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.setTrustLevel(fingerprint: key.fingerprint, to: level, source: key.source)
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

    /// 导出公钥到 `.asc` 文件 —— NSSavePanel 选目标，`gpg --armor --export <fp>` 直写文件。
    private func exportPublicKey(for key: GPGBackend.GPGKey) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(key.userID.replacingOccurrences(of: " ", with: "_"))_\(key.shortFingerprint).asc"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "asc") ?? .data]
        savePanel.message = L10n.text("settings.gpg.keys.exportPanelTitle")
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        Task {
            do {
                let armor = try await GPGBackend.exportPublicKey(fingerprint: key.fingerprint, source: key.source)
                try armor.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.exportSucceeded", url.lastPathComponent)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.exportFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 修改 passphrase —— `gpg --edit-key <fp> passwd` interactive 喂旧 / 新 / 确认 / save。
    private func applyPassphraseChange(for key: GPGBackend.GPGKey, oldPassphrase: String, newPassphrase: String) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.changePassphrase(
                    fingerprint: key.fingerprint,
                    oldPassphrase: oldPassphrase,
                    newPassphrase: newPassphrase,
                    source: key.source
                )
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.changePassphrase.succeeded", key.userID)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.changePassphrase.failed", error.localizedDescription)
                }
            }
        }
    }

    /// 添加 User ID —— `gpg --quick-add-uid <fp> "Name (comment) <email>"`，需要 passphrase 解锁主密钥签名新 UID。
    private func applyAddUserID(for key: GPGBackend.GPGKey, name: String, email: String, comment: String, passphrase: String) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.addUserID(
                    fingerprint: key.fingerprint,
                    name: name,
                    email: email,
                    comment: comment,
                    passphrase: passphrase,
                    source: key.source
                )
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? keys
                    keyOperationMessage = L10n.format("settings.gpg.addUID.succeeded", "\(name) <\(email)>")
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.addUID.failed", error.localizedDescription)
                }
            }
        }
    }

    /// 「补票」给现有密钥追加子密钥 —— `gpg --quick-add-key <fp> <algo> <usage> <expire>`，需 passphrase 解锁主密钥。
    private func applyAddSubkey(
        for key: GPGBackend.GPGKey,
        capability: GPGBackend.GPGSubkeyCapability,
        algorithm: GPGBackend.GPGKeyAlgorithm,
        expiration: GPGBackend.GPGKeyExpiration,
        passphrase: String
    ) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.addSubkey(
                    fingerprint: key.fingerprint,
                    capability: capability,
                    algorithm: algorithm,
                    expiration: expiration,
                    passphrase: passphrase,
                    source: key.source
                )
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? keys
                    keyOperationMessage = L10n.format("settings.gpg.addSubkey.succeeded", capability.displayName, key.userID)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.addSubkey.failed", error.localizedDescription)
                }
            }
        }
    }

    /// 导出**私钥**到 `.asc` 文件 —— 备份 / 迁移用。文件里是 passphrase 加密的 blob，分两个地方存（私钥 + passphrase 不要同地存）。
    private func exportPrivateKey(for key: GPGBackend.GPGKey) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(key.userID.replacingOccurrences(of: " ", with: "_"))_\(key.shortFingerprint)-secret.asc"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "asc") ?? .data]
        savePanel.message = L10n.text("settings.gpg.keys.exportPrivatePanelMessage")
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        keyOperationMessage = nil
        Task {
            do {
                let armor = try await GPGBackend.exportSecretKey(fingerprint: key.fingerprint, source: key.source)
                try armor.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.exportPrivateSucceeded", url.lastPathComponent)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.exportPrivateFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 删除密钥 —— 按 `hasSecretKey` 选 `--delete-secret-and-public-key` 还是 `--delete-keys`。
    /// 智能卡 stub 删除只清本机 stub，卡上私钥不动（重新插卡 + import 又能拉回）。
    private func deleteKey(_ key: GPGBackend.GPGKey) {
        pendingDeleteKey = nil
        keyOperationMessage = nil
        Task {
            do {
                _ = try await GPGBackend.deleteKey(
                    fingerprint: key.fingerprint,
                    deleteSecret: key.hasSecretKey,
                    source: key.source
                )
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? []
                    // 删的恰好是当前默认签名密钥 → 清掉
                    if defaultSigningKeyFingerprint == key.fingerprint {
                        defaultSigningKeyFingerprint = ""
                    }
                    keyOperationMessage = L10n.format("settings.gpg.keys.deleteSucceeded", key.userID)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.deleteFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 修改密钥过期 —— gpg `--edit-key <fpr> expire <duration> save`。
    private func applyExpiration(for key: GPGBackend.GPGKey, expiration: GPGBackend.GPGKeyExpiration) {
        keyOperationMessage = nil
        Task {
            do {
                try await GPGBackend.setKeyExpiration(
                    fingerprint: key.fingerprint,
                    expiration: expiration,
                    source: key.source
                )
                let refreshed = try? await GPGBackend.listKeys()
                await MainActor.run {
                    keys = refreshed ?? keys
                    keyOperationMessage = L10n.format("settings.gpg.keys.expirationChangeSucceeded", key.userID, expiration.displayName)
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.expirationChangeFailed", error.localizedDescription)
                }
            }
        }
    }

    /// 生成撤销证书 —— gpg `--gen-revoke <fpr>` 输出 ASCII armor，直接写到 sheet 里选好的 `destination`。
    /// 保存位置已在 GenerateRevocationSheet 选定，这里不再另弹 NSSavePanel；写成功后在 Finder 中定位该文件。
    private func generateRevocation(for key: GPGBackend.GPGKey, reason: GPGBackend.GPGRevocationReason, description: String, destination: URL) {
        keyOperationMessage = nil
        Task {
            do {
                let armor = try await GPGBackend.generateRevocationCert(
                    fingerprint: key.fingerprint,
                    reason: reason,
                    description: description,
                    source: key.source
                )
                await MainActor.run {
                    do {
                        try armor.write(to: destination, atomically: true, encoding: .utf8)
                        keyOperationMessage = L10n.format("settings.gpg.keys.revokeSucceeded", destination.path)
                        // 让用户直接看到 `.asc` 落在哪 —— 在 Finder 中选中该文件。
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    } catch {
                        keyOperationMessage = L10n.format("settings.gpg.keys.revokeWriteFailed", error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    keyOperationMessage = L10n.format("settings.gpg.keys.revokeFailed", error.localizedDescription)
                }
            }
        }
    }

    private func detectCard() {
        isDetectingCard = true
        Task {
            let status = try? await GPGBackend.cardStatus()
            await MainActor.run {
                cardStatus = status
                isDetectingCard = false
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
