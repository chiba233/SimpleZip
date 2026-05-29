//
//  SevenZipBackendSection.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// Archive 面板里 7-Zip 后端这一节。
///
/// 单独成 section view 是为了把版本探测、缺失提示、SystemInstall 提示三件事
/// 收敛在一处。父 ArchivePane 不需要持有这些 transient 状态。
struct SevenZipBackendSection: View {
    @AppStorage(AppPreferences.Key.sevenZipBackend) private var sevenZipBackend = SevenZipBackendChoice.automatic.rawValue
    @Binding var systemInstallMessage: String?
    let copyCommand: (String) -> Void
    let copyAndOpenTerminal: (String) -> Void

    @State private var sevenZipVersion = L10n.text("settings.7zip.checking")
    @State private var isSevenZipMissing = false

    var body: some View {
        Section(L10n.text("settings.7zip.backend")) {
            SettingsControlRow(
                title: L10n.text("settings.7zip.backend"),
                description: L10n.text("settings.7zip.backend.description")
            ) {
                Picker("", selection: $sevenZipBackend) {
                    ForEach(SevenZipBackendChoice.allCases) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(minWidth: 200, alignment: .trailing)
                .onChange(of: sevenZipBackend) { _ in
                    refreshVersion()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("settings.7zip.path", ArchiveService.sevenZipBackendDescription()))
                Text(L10n.format("settings.7zip.version", sevenZipVersion))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if shouldShowSystemInstallPrompt {
                SystemInstallCommandView(
                    title: L10n.text("settings.systemInstall.7zip.title"),
                    command: "brew install sevenzip",
                    message: $systemInstallMessage,
                    copyCommand: copyCommand,
                    copyAndOpenTerminal: copyAndOpenTerminal
                )
            }
        }
        .onAppear(perform: refreshVersion)
    }

    /// 选了「系统级 7-Zip」但未在 PATH 中找到时才提示 brew 安装，
    /// 选「内置」或「自动」时不应该让用户看到额外噪音。
    private var shouldShowSystemInstallPrompt: Bool {
        SevenZipBackendChoice(rawValue: sevenZipBackend) == .system && isSevenZipMissing
    }

    /// 探测 7-Zip 版本。
    ///
    /// 同步部分先把状态拉成「检测中」+ 当前可用性，async 部分再覆盖准确版本字符串。
    /// 这样切换后端时 UI 不会出现明显空窗期。
    private func refreshVersion() {
        let checkingText = L10n.text("settings.7zip.checking")
        DispatchQueue.main.async {
            sevenZipVersion = checkingText
            isSevenZipMissing = !ArchiveService.canUseSevenZip()
        }
        Task {
            let version = await ArchiveService.sevenZipVersion()
            DispatchQueue.main.async {
                sevenZipVersion = version
                isSevenZipMissing = !ArchiveService.canUseSevenZip()
            }
        }
    }
}
