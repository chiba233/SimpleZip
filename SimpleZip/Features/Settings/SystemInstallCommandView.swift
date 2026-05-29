//
//  SystemInstallCommandView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 「请用 brew 安装系统级 7zip / RAR」时显示的命令复制面板。
///
/// 之所以独立成组件而不是写在 ArchivePane 里：7zip 和 RAR 都用同一种 UI，
/// 提取后只有一份复制 / 复制并打开终端的实现。
struct SystemInstallCommandView: View {
    let title: String
    let command: String
    @Binding var message: String?
    let copyCommand: (String) -> Void
    let copyAndOpenTerminal: (String) -> Void

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
                copyCommand(command)
            }

            SettingsActionRow(
                title: L10n.text("settings.systemInstall.copyAndOpenTerminal"),
                description: L10n.text("settings.systemInstall.copyAndOpenTerminal.description"),
                systemImage: "terminal",
                buttonTitle: L10n.text("settings.systemInstall.copyAndOpenTerminal")
            ) {
                copyAndOpenTerminal(command)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
