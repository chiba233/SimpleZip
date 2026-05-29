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
    @AppStorage(AppPreferences.Key.rarBackend) private var rarBackend = RarBackend.automatic.rawValue
    @Binding var systemInstallMessage: String?
    let copyCommand: (String) -> Void
    let copyAndOpenTerminal: (String) -> Void

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
                    ForEach(RarBackend.allCases) { backend in
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
                    message: $systemInstallMessage,
                    copyCommand: copyCommand,
                    copyAndOpenTerminal: copyAndOpenTerminal
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
        let selectedBackend = RarBackend(rawValue: rarBackend)
        guard selectedBackend == .automatic || selectedBackend == .bundled else {
            return false
        }
        return isRarMissing || hasLocalRarBackend
    }

    private var shouldShowSystemInstallPrompt: Bool {
        RarBackend(rawValue: rarBackend) == .system && isRarMissing
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

    /// 读出协议 / README 原文后弹起 review sheet。
    /// 读文件失败说明安装资源缺失（用户可能删了 Tools 目录），直接给提示。
    private func beginInstallReview(_ action: RarInstallAction) {
        guard let licenseURL = ArchiveService.rarInstallLicenseURL(),
              let readmeURL = ArchiveService.rarInstallReadmeURL()
        else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }

        do {
            let licenseText = try String(contentsOf: licenseURL, encoding: .utf8)
            let readmeText = try String(contentsOf: readmeURL, encoding: .utf8)
            let review = RarInstallReview(action: action, licenseText: licenseText, readmeText: readmeText)
            DispatchQueue.main.async {
                rarInstallReview = review
            }
        } catch {
            rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", error.localizedDescription)
        }
    }

    /// 在后台执行 bash 安装脚本。
    ///
    /// 用 `Task.detached` 而不是 `Task`：脚本耗时几秒到十几秒，detached 避免占着主 actor。
    /// 输出只取最后 4 行 —— 真有错误的话最后几行就是 stderr，太多会撑爆 toast。
    private func runRarInstaller(action: RarInstallAction) {
        guard let installerURL = ArchiveService.rarInstallerScriptURL(),
              FileManager.default.fileExists(atPath: installerURL.path)
        else {
            rarInstallMessage = L10n.text("settings.rar.installFilesMissing")
            return
        }

        isInstallingRar = true
        rarInstallMessage = action == .install ? L10n.text("settings.rar.installing") : L10n.text("settings.rar.updating")

        Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [installerURL.path]
            process.currentDirectoryURL = installerURL.deletingLastPathComponent()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .suffix(4)
                    .joined(separator: "\n")

                await MainActor.run {
                    isInstallingRar = false
                    refreshVersion()
                    if process.terminationStatus == 0 {
                        rarInstallMessage = action == .install ? L10n.text("settings.rar.installSucceeded") : L10n.text("settings.rar.updateSucceeded")
                    } else if text.isEmpty {
                        rarInstallMessage = L10n.text("settings.rar.installFailed")
                    } else {
                        rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", text)
                    }
                }
            } catch {
                await MainActor.run {
                    isInstallingRar = false
                    rarInstallMessage = L10n.format("settings.rar.installFailedWithOutput", error.localizedDescription)
                }
            }
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
