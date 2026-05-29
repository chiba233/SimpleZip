//
//  SystemInstallCommandView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 「请用 brew 安装系统级 7zip / RAR / gnupg」时显示的命令复制面板。
///
/// 7zip / RAR / GPG 三个 pane 都用同一种 UI。pasteboard 写入和打开 Terminal 这两件事完全相同，
/// 由本组件直接承包；调用方只提供 title / command 和一个 message binding 用于显示「已复制」反馈。
struct SystemInstallCommandView: View {
    let title: String
    let command: String
    @Binding var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            SettingsActionRow(
                title: L10n.text("settings.systemInstall.copy"),
                description: L10n.text("settings.systemInstall.copy.description"),
                systemImage: "doc.on.doc",
                buttonTitle: L10n.text("settings.systemInstall.copy")
            ) {
                copyCommand()
            }

            SettingsActionRow(
                title: L10n.text("settings.systemInstall.copyAndOpenTerminal"),
                description: L10n.text("settings.systemInstall.copyAndOpenTerminal.description"),
                systemImage: "terminal",
                buttonTitle: L10n.text("settings.systemInstall.copyAndOpenTerminal")
            ) {
                copyCommandAndOpenTerminal()
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        message = L10n.format("settings.systemInstall.copied", command)
    }

    private func copyCommandAndOpenTerminal() {
        copyCommand()
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    }
}
