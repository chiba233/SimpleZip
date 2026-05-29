//
//  GPGPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import SwiftUI
import AppKit

/// GPG 设置面板 —— 用户在这里启用 / 关闭 GPG 集成、装 gnupg 后端、设置默认行为。
///
/// 设计动机：GPG 全功能默认对用户**不可见**（创建 / 解压 / 状态徽章里都没入口），
/// 只有用户在这里主动打开主开关 `gpgEnabled` 后，其它地方的 GPG 入口才出现。
/// 这条策略避免「不用 GPG 的人被到处的 PGP 入口打扰」。
///
/// 安装路径：跟 RAR / 7zz pane 同款 —— 用 `SystemInstallCommandView` 给 `brew install gnupg` 命令，
/// 再附一个「打开 GPGTools 下载页」按钮作为不熟悉命令行的用户的备用路径。
/// 不自己捆绑 GnuPG 安装脚本：GnuPG 的依赖链（libgpg-error / libgcrypt / libassuan / libksba /
/// npth / pinentry）远比 RAR 单二进制复杂，重写一遍编译流程不划算。
///
/// 后续轮次（A 阶段剩下的）会在这里加：列出当前钥匙串、导入公钥、签名 / 验签的默认偏好；
/// B 阶段：GUI 创建新密钥、导出公钥、删除密钥。
struct GPGPane: View {
    @AppStorage(AppPreferences.Key.gpgEnabled) private var gpgEnabled = false

    @State private var systemInstallMessage: String?
    @State private var gpgAvailable = false
    @State private var pinentryAvailable = false
    @State private var gpgVersion: String = L10n.text("settings.gpg.notFound")

    // 密钥列表 + 导入相关状态
    @State private var keys: [GPGBackend.GPGKey] = []
    @State private var isLoadingKeys = false
    @State private var keyOperationMessage: String?

    var body: some View {
        Form {
            // 主开关 ——「关」的时候其它地方都没有 GPG 入口；「开」之后下面的更多选项才有意义。
            Section {
                SettingsToggleRow(
                    title: L10n.text("settings.gpg.enabledTitle"),
                    description: L10n.text("settings.gpg.enabledDescription"),
                    isOn: $gpgEnabled
                )
            }

            // 后端可用性 —— 跟 SevenZip / RAR pane 同款 GroupBox-外 状态徽章 + GroupBox-内 picker / 安装提示。
            Section(L10n.text("settings.gpg.backend.title")) {
                BackendAvailabilityRow(
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
                    // Homebrew 安装提示（首选）。
                    SystemInstallCommandView(
                        title: L10n.text("settings.gpg.install.brew.title"),
                        command: "brew install gnupg pinentry-mac",
                        message: $systemInstallMessage,
                        copyCommand: copySystemInstallCommand,
                        copyAndOpenTerminal: copySystemInstallCommandAndOpenTerminal
                    )

                    // GPGTools 安装包路径（备选）。
                    SettingsActionRow(
                        title: L10n.text("settings.gpg.install.gpgsuite.title"),
                        description: "https://gpgtools.org/",
                        systemImage: "safari",
                        buttonTitle: L10n.text("settings.gpg.install.gpgsuite.button"),
                        action: openGPGToolsPage
                    )
                }
            }

            // 钥匙串 ——「主开关 + 后端可用」都满足才显示有意义的内容。
            if gpgEnabled && gpgAvailable {
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
                        VStack(spacing: 0) {
                            ForEach(keys) { key in
                                GPGKeyRow(key: key)
                                if key.id != keys.last?.id {
                                    Divider().padding(.leading, 30)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button(L10n.text("settings.gpg.keys.importButton")) {
                            importPublicKey()
                        }
                        Button(L10n.text("settings.gpg.keys.refresh")) {
                            refreshKeys()
                        }
                        Spacer()
                    }

                    if let keyOperationMessage {
                        Text(keyOperationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
            if enabled && gpgAvailable { refreshKeys() }
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
        // 让用户能挑任意文件 —— gpg 自己识别 ASCII armor / 二进制公钥 / 私钥 / 公私钥对。
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await GPGBackend.importKey(from: url)
                await MainActor.run {
                    keyOperationMessage = L10n.text("settings.gpg.keys.importSucceeded")
                }
                // 重读密钥列表，让刚导入的立刻出现。
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

    // MARK: - 状态刷新

    private func refreshStatus() {
        gpgAvailable = GPGBackend.isAvailable()
        pinentryAvailable = GPGBackend.hasPinentryMac()
        Task {
            let version = await GPGBackend.version()
            await MainActor.run {
                gpgVersion = version
            }
        }
    }

    // MARK: - 安装提示 helpers（跟 ArchivePane 同源 helper）

    private func copySystemInstallCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        systemInstallMessage = L10n.format("settings.systemInstall.copied", command)
    }

    private func copySystemInstallCommandAndOpenTerminal(_ command: String) {
        copySystemInstallCommand(command)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    }

    private func openGPGToolsPage() {
        guard let url = URL(string: "https://gpgtools.org/") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 钥匙串里一把密钥的展示行：左侧钥匙图标（有私钥时实心 / 无私钥空心）+ 中间 UID + 指纹 + 右侧角标。
private struct GPGKeyRow: View {
    let key: GPGBackend.GPGKey

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: key.hasSecretKey ? "key.fill" : "key")
                .font(.system(size: 16))
                .foregroundStyle(key.hasSecretKey ? Color.accentColor : Color.secondary)
                .frame(width: 22)
                .help(key.hasSecretKey ? L10n.text("settings.gpg.keys.hasSecret") : "")

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
        }
        .padding(.vertical, 4)
    }
}

/// 「后端是否就绪」高对比度徽章（与 WelcomeBackendStep 里的 `BackendStatusBadge` 同款样式，
/// 但这里给 Settings GPG pane 用，不复用 private 类型）。
private struct BackendAvailabilityRow: View {
    let isOk: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOk ? Color.green : Color.orange)
            Text(isOk ? okText : failText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isOk ? Color.green : Color.orange)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
