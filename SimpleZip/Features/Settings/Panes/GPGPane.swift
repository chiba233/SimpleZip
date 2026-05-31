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
        // 生成撤销证书 sheet
        .sheet(item: $pendingRevocationKey) { key in
            GenerateRevocationSheet(key: key, isPresented: Binding(
                get: { pendingRevocationKey != nil },
                set: { if !$0 { pendingRevocationKey = nil } }
            )) { reason, description in
                generateRevocation(for: key, reason: reason, description: description)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: defaultSigningKeyFingerprint.isEmpty ? "signature" : "signature")
                .foregroundStyle(defaultSigningKeyFingerprint.isEmpty ? .secondary : Color.accentColor)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "creditcard")
                .foregroundStyle(cardStatus == nil ? Color.secondary : Color.orange)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("settings.gpg.defaults.signingStrategy.label"))
                        .font(.caption.weight(.medium))
                    Spacer()
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
                Text(L10n.text(promptForSigningKey
                    ? "settings.gpg.defaults.signingStrategy.askDescription"
                    : "settings.gpg.defaults.signingStrategy.silentDescription"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
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

    /// 生成撤销证书 —— gpg `--gen-revoke <fpr>` 输出 ASCII armor，弹 NSSavePanel 让用户存到 `.asc`。
    private func generateRevocation(for key: GPGBackend.GPGKey, reason: GPGBackend.GPGRevocationReason, description: String) {
        keyOperationMessage = nil
        Task {
            do {
                let armor = try await GPGBackend.generateRevocationCert(
                    fingerprint: key.fingerprint,
                    reason: reason,
                    description: description,
                    source: key.source
                )
                // 回主线程弹 NSSavePanel
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(key.userID.replacingOccurrences(of: " ", with: "_"))_\(key.shortFingerprint)-revocation.asc"
                    panel.allowedContentTypes = [UTType(filenameExtension: "asc") ?? .data]
                    panel.message = L10n.text("settings.gpg.keys.revokeSavePanelMessage")
                    guard panel.runModal() == .OK, let url = panel.url else {
                        keyOperationMessage = L10n.text("settings.gpg.keys.revokeCancelledByUser")
                        return
                    }
                    do {
                        try armor.write(to: url, atomically: true, encoding: .utf8)
                        keyOperationMessage = L10n.format("settings.gpg.keys.revokeSucceeded", url.lastPathComponent)
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

/// 钥匙串里一把密钥的展示行 —— 含主密钥信息 + 可折叠的详情区（完整指纹 / 子密钥列表）+ 信任 picker + 默认签名按钮 + 右键 context menu。
///
/// 默认折叠：只展示 userID + 短指纹 + capability chips + 卡上 badge + trust picker + 默认签名按钮，一眼看完。
/// 点「详情 ▶」展开完整 fingerprint + 子密钥列表。
private struct GPGKeyRow: View {
    let key: GPGBackend.GPGKey
    let isDefaultSigningKey: Bool
    let canBeDefaultSigner: Bool
    let onTrustChange: (GPGBackend.GPGTrustLevel) -> Void
    let onSetDefaultSigning: () -> Void
    let onCopyFingerprint: () -> Void
    let onExportPublicKey: () -> Void
    let onExportPrivateKey: () -> Void
    let onChangePassphrase: () -> Void
    let onAddUserID: () -> Void
    let onEditExpiration: () -> Void
    let onGenerateRevocation: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                keyIcon
                    .frame(width: 26)
                    .help(rowIconHelp)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key.userID)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if key.isExpired {
                            Text(L10n.text("settings.gpg.keys.expired"))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        primaryCapabilityChips
                        if key.isSecretKeyOnSmartcard {
                            onCardBadge
                        } else if key.isSecretKeyStripped {
                            strippedBadge
                        }
                    }
                    HStack(spacing: 6) {
                        Text(key.shortFingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        detailsToggleButton
                    }
                }

                Spacer()

                actionsMenu

                if canBeDefaultSigner {
                    defaultSigningControl
                }

                trustControl
            }

            if isExpanded {
                expandedDetails
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            menuItems
        }
    }

    /// 可见的 `…` Menu 按钮 —— 把所有操作摊出来让用户知道有什么可做的（右键 context menu 是 power user shortcut）。
    /// 内容跟 contextMenu 共用 `menuItems` ViewBuilder。
    @ViewBuilder
    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(L10n.text("settings.gpg.keys.contextCopyFingerprint")) {
            onCopyFingerprint()
        }
        Button(L10n.text("settings.gpg.keys.contextExportPublicKey")) {
            onExportPublicKey()
        }
        // 修改 passphrase / 添加 UID / 改过期 / 生成撤销证书：本机持有私钥的密钥可用（智能卡 stub 也算 ——
        // gpg 会要求插卡 + 输入卡 PIN 来用卡上私钥做这些操作）。
        if key.hasSecretKey {
            // 「导出私钥」**只在私钥材料实际在本机、可导出**时给（非卡上、非 stripped）。
            // 卡上 / stripped 的密钥 `--export-secret-keys` 只会导出一个无用 stub（卡永远不释放私钥本体），
            // 给用户「我备份了私钥」的错觉 —— 对一个本机没有私钥的密钥提供「导出私钥」是错的。
            if !key.isSecretKeyStub {
                Button(L10n.text("settings.gpg.keys.contextExportPrivateKey")) {
                    onExportPrivateKey()
                }
            }
            Divider()
            Button(L10n.text("settings.gpg.keys.contextChangePassphrase")) {
                onChangePassphrase()
            }
            Button(L10n.text("settings.gpg.keys.contextAddUID")) {
                onAddUserID()
            }
            Button(L10n.text("settings.gpg.keys.contextEditExpiration")) {
                onEditExpiration()
            }
            Button(L10n.text("settings.gpg.keys.contextGenerateRevocation")) {
                onGenerateRevocation()
            }
        }
        // 删除密钥：所有密钥都可删（公钥 / 含私钥 / 卡 stub），UI 层做差异化确认。
        Divider()
        Button(L10n.text("settings.gpg.keys.contextDelete"), role: .destructive) {
            onDelete()
        }
    }

    /// 详情切换按钮（带 chevron），始终展示让用户知道有可展开内容；展开 = 完整 fingerprint + 卡 caption + 子密钥列表。
    @ViewBuilder
    private var detailsToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 9, weight: .semibold))
                Text(detailToggleLabel)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// 折叠区里的内容：完整 fingerprint + 卡 / stripped caption + 子密钥列表。
    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.displayFingerprint)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            if key.isSecretKeyOnSmartcard {
                Text(L10n.text("settings.gpg.smartcard.stubNote"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if key.isSecretKeyStripped {
                Text(L10n.text("settings.gpg.keys.stripped"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !key.subkeys.isEmpty {
                subkeyList
            }
        }
        .padding(.leading, 36)
        .padding(.top, 2)
    }

    private var detailToggleLabel: String {
        if isExpanded {
            return L10n.text("settings.gpg.keys.hideDetails")
        }
        if key.subkeys.isEmpty {
            return L10n.text("settings.gpg.keys.showDetails")
        }
        return L10n.format("settings.gpg.keys.showDetailsWithCount", key.subkeys.count)
    }

    // MARK: 行内组件

    /// 主密钥能力 chip —— 从 `key.capabilities` 中提取小写 s/e/a/c 字符；大写表示「整把密钥（主 + 子）合并能力」，
    /// 主密钥这一行只显示小写 = 主密钥自己能做什么。这样用户能立刻看出主密钥是不是签名密钥。
    /// 纯文字单字 chip（不带 SF Symbol）—— 「签 / 密 / 认 / 证」是单 unicode 字符，等宽天然，避免不同 icon 视觉宽度漂移。
    @ViewBuilder
    private var primaryCapabilityChips: some View {
        if key.capabilities.contains("s") {
            capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.sign"), tint: .accentColor)
        }
        if key.capabilities.contains("e") {
            capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.encrypt"), tint: .accentColor)
        }
        if key.capabilities.contains("a") {
            capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.auth"), tint: .accentColor)
        }
        if key.capabilities.contains("c") {
            capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.certify"), tint: .secondary)
        }
    }

    @ViewBuilder
    private var onCardBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 11, alignment: .center)
            Text(L10n.text("settings.gpg.subkey.onCard"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(0.16))
        )
    }

    @ViewBuilder
    private var strippedBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "key.slash")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 11, alignment: .center)
            Text(L10n.text("settings.gpg.subkey.stripped"))
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.14))
        )
    }

    @ViewBuilder
    private var keyIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: key.hasSecretKey ? "key.fill" : "key")
                .font(.system(size: 16))
                .foregroundStyle(key.hasSecretKey ? Color.accentColor : Color.secondary)
            if key.isSecretKeyOnSmartcard {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 14))
                    .offset(x: 4, y: 3)
            }
        }
    }

    /// 子密钥列表 —— 每行缩进，显示短指纹 + 能力图标 + 卡 / stripped 标记 + 过期。
    @ViewBuilder
    private var subkeyList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(key.subkeys) { subkey in
                HStack(spacing: 6) {
                    Image(systemName: subkey.isOnSmartcard ? "key.fill" : (subkey.isStripped ? "key.slash" : "key"))
                        .font(.system(size: 10))
                        .foregroundStyle(subkey.isStripped ? .secondary : (subkey.isOnSmartcard ? .orange : Color.accentColor.opacity(0.8)))
                    Text(subkey.fingerprint.suffix(16))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if subkey.canSign {
                        capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.sign"), tint: .accentColor)
                    }
                    if subkey.canEncrypt {
                        capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.encrypt"), tint: .accentColor)
                    }
                    if subkey.canAuthenticate {
                        capabilityBadge(label: L10n.text("settings.gpg.subkey.cap.auth"), tint: .accentColor)
                    }
                    if subkey.isOnSmartcard {
                        Text(L10n.text("settings.gpg.subkey.onCard"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if subkey.isStripped {
                        Text(L10n.text("settings.gpg.subkey.stripped"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if subkey.isExpired {
                        Text(L10n.text("settings.gpg.keys.expired"))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 38)
        .padding(.top, 2)
    }

    /// 能力 chip —— 纯文字（一个汉字），靠相同 padding + 颜色对比区分 sign / encrypt / auth / certify。
    /// 等宽天然（每个 chip 内容都是 1 个汉字），不再需要固定 frame。
    @ViewBuilder
    private func capabilityBadge(label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.16))
            )
    }

    /// 默认签名状态 —— 已是默认显示绿色「默认」chip；不是默认显示「设为默认」按钮。两者视觉高度对齐 trust picker。
    @ViewBuilder
    private var defaultSigningControl: some View {
        if isDefaultSigningKey {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text(L10n.text("settings.gpg.defaultSigning.isDefault"))
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.green.opacity(0.14))
            )
            .fixedSize()
        } else {
            Button(L10n.text("settings.gpg.defaultSigning.setButton")) {
                onSetDefaultSigning()
            }
            .controlSize(.small)
        }
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
        if key.isSecretKeyOnSmartcard {
            return L10n.text("settings.gpg.smartcard.stubNote")
        }
        if key.isSecretKeyStripped {
            return L10n.text("settings.gpg.keys.stripped")
        }
        return key.hasSecretKey ? L10n.text("settings.gpg.keys.hasSecret") : ""
    }
}
