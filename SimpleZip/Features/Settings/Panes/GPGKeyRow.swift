//
//  GPGKeyRow.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 GPGPane.swift 切出的密钥展示行 + 信任级别本地化扩展，纯移动、零行为变更。
//

import AppKit
import SwiftUI

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
struct GPGKeyRow: View {
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
                    // 「当前值」用**用户设置的 ownertrust**,不是 validity —— 否则设 never/marginal/full 后
                    // validity 仍是 unknown,dropdown 会弹回「未设置」,看起来只有终极信任生效。
                    get: { key.ownerTrust },
                    set: { newValue in
                        if newValue != key.ownerTrust {
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
