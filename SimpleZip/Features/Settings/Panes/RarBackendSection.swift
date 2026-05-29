//
//  RarBackendSection.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// Archive 面板里 RAR 后端这一节。
///
/// 比 7-Zip 复杂得多：除了版本探测，还要管「本地 RAR 安装包」的安装/升级/删除流程，
/// 以及一个带协议确认的 review sheet。
struct RarBackendSection: View {
    @AppStorage(AppPreferences.Key.rarBackend) private var rarBackend = RarBackendChoice.automatic.rawValue
    @Binding var systemInstallMessage: String?

    @State private var rarVersion = L10n.text("settings.rar.checking")
    @State private var isRarMissing = false
    @State private var hasLocalRarBackend = false
    @State private var isInstallingRar = false
    @State private var rarInstallReview: RarInstallReview?
    @State private var rarInstallMessage: String?

    var body: some View {
        Section(L10n.text("settings.rar.backend")) {
            SettingsControlRow(
                title: L10n.text("settings.rar.backend"),
                description: L10n.text("settings.rar.backend.description")
            ) {
                Picker("", selection: $rarBackend) {
                    ForEach(RarBackendChoice.allCases) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(minWidth: 200, alignment: .trailing)
                .onChange(of: rarBackend) { _ in
                    refreshVersion()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("settings.rar.path", ArchiveService.rarBackendDescription()))
                Text(L10n.format("settings.rar.version", rarVersion))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if shouldShowLocalControls {
                localBackendControls
            }

            if shouldShowSystemInstallPrompt {
                SystemInstallCommandView(
                    title: L10n.text("settings.systemInstall.rar.title"),
                    command: "brew install --cask rar",
                    message: $systemInstallMessage
                )
            }
        }
        .onAppear(perform: refreshVersion)
        .sheet(item: $rarInstallReview) { review in
            RarInstallReviewSheet(
                review: review,
                isInstalling: isInstallingRar,
                onCancel: { rarInstallReview = nil },
                onConfirm: { action in
                    rarInstallReview = nil
                    runRarInstaller(action: action)
                }
            )
        }
    }

    /// 只有「自动 / 内置」后端下、且当前没有可用 RAR 或已经装了本地版时才显示这些操作。
    /// 选择「系统级」的用户只关心 brew 提示，不该看到「装到本地」按钮。
    private var shouldShowLocalControls: Bool {
        let selectedBackend = RarBackendChoice(rawValue: rarBackend)
        guard selectedBackend == .automatic || selectedBackend == .bundled else {
            return false
        }
        return isRarMissing || hasLocalRarBackend
    }

    private var shouldShowSystemInstallPrompt: Bool {
        RarBackendChoice(rawValue: rarBackend) == .system && isRarMissing
    }

    private var promptText: String {
        hasLocalRarBackend ? L10n.text("settings.rar.localBackendPrompt") : L10n.text("settings.rar.installPrompt")
    }

    private var localBackendControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(promptText)
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsActionRow(
                title: L10n.text("settings.rar.openReadme"),
                description: L10n.text("settings.rar.openReadme.description"),
                systemImage: "doc.text",
                buttonTitle: L10n.text("settings.rar.openReadme"),
                action: openInstallReadme
            )

            SettingsActionRow(
                title: L10n.text("settings.rar.revealInstallFiles"),
                description: L10n.text("settings.rar.revealInstallFiles.description"),
                systemImage: "folder",
                buttonTitle: L10n.text("settings.rar.revealInstallFiles"),
                action: revealInstallFiles
            )

            SettingsActionRow(
                title: L10n.text("settings.rar.runInstaller"),
                description: L10n.text("settings.rar.runInstaller.description"),
                systemImage: "arrow.down.circle",
                buttonTitle: L10n.text("settings.rar.runInstaller"),
                // 已经装过本地版的禁掉「安装」，避免重复安装；正在装的过程中也整体禁掉。
                isDisabled: isInstallingRar || hasLocalRarBackend
            ) {
                beginInstallReview(.install)
            }

            SettingsActionRow(
                title: L10n.text("settings.rar.updateBackend"),
                description: L10n.text("settings.rar.updateBackend.description"),
                systemImage: "arrow.triangle.2.circlepath",
                buttonTitle: L10n.text("settings.rar.updateBackend"),
                isDisabled: isInstallingRar || !hasLocalRarBackend
            ) {
                beginInstallReview(.update)
            }

            SettingsActionRow(
                title: L10n.text("settings.rar.deleteBackend"),
                description: L10n.text("settings.rar.deleteBackend.description"),
                systemImage: "trash",
                buttonTitle: L10n.text("settings.rar.deleteBackend"),
                role: .destructive,
                isDisabled: isInstallingRar || !hasLocalRarBackend,
                action: deleteLocalBackend
            )

            if let rarInstallMessage {
                Text(rarInstallMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 行为

    private func refreshVersion() {
        let checkingText = L10n.text("settings.rar.checking")
        DispatchQueue.main.async {
            rarVersion = checkingText
            isRarMissing = !ArchiveService.canCreateRAR()
            hasLocalRarBackend = ArchiveService.hasLocalRarBackend()
        }
        Task {
            let version = await ArchiveService.rarVersion()
            DispatchQueue.main.async {
                rarVersion = version
                isRarMissing = !ArchiveService.canCreateRAR()
                hasLocalRarBackend = ArchiveService.hasLocalRarBackend()
            }
        }
    }

    private func openInstallReadme() {
        guard let readmeURL = ArchiveService.rarInstallReadmeURL(),
              FileManager.default.fileExists(atPath: readmeURL.path)
        else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        NSWorkspace.shared.open(readmeURL)
    }

    private func revealInstallFiles() {
        guard let resourcesURL = ArchiveService.rarInstallResourcesURL(),
              FileManager.default.fileExists(atPath: resourcesURL.path)
        else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }
        // 优先在 Finder 里精确选中安装相关文件；缺失时就选父目录。
        let installFiles = [
            ArchiveService.rarInstallReadmeURL(),
            ArchiveService.rarInstallLicenseURL(),
            ArchiveService.rarInstallerScriptURL()
        ].compactMap { $0 }
        NSWorkspace.shared.activateFileViewerSelecting(installFiles.isEmpty ? [resourcesURL] : installFiles)
    }

    private func beginInstallReview(_ action: RarInstallAction) {
        do {
            rarInstallReview = try RarInstallerService.loadReview(action: action)
        } catch {
            rarInstallMessage = error.localizedDescription
        }
    }

    private func runRarInstaller(action: RarInstallAction) {
        isInstallingRar = true
        rarInstallMessage = action == .install
            ? L10n.text("settings.rar.installing")
            : L10n.text("settings.rar.updating")
        Task {
            let message = await RarInstallerService.runInstaller(action: action)
            isInstallingRar = false
            refreshVersion()
            rarInstallMessage = message
        }
    }

    private func deleteLocalBackend() {
        do {
            try ArchiveService.deleteLocalRarBackend()
            refreshVersion()
            rarInstallMessage = L10n.text("settings.rar.deleteSucceeded")
        } catch {
            rarInstallMessage = L10n.format("settings.rar.deleteFailedWithOutput", error.localizedDescription)
        }
    }
}
