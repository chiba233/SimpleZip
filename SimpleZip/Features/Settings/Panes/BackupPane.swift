//
//  BackupPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「备份与还原」面板：导出当前偏好为 JSON、从 JSON 导入偏好、把所有偏好恢复出厂默认。
///
/// 设计动机：之前所有 settings 都靠 UserDefaults 自动持久化，但没有「换机器 / 误操作 / 重置」
/// 的便捷入口 —— 用户清掉一项 settings 就得自己重新点回去。这一 pane 把三件维护性事务收在一起，
/// 全部带确认对话框（毁灭性操作必须二次确认），导出 / 导入用 NSSavePanel / NSOpenPanel。
struct BackupPane: View {
    /// 「全部恢复默认」确认弹窗的可见状态。
    @State private var showsRestoreConfirmation = false
    /// 导入前的二次确认 + 路径携带。点了「导入…」选好文件后弹这个确认。
    @State private var pendingImportURL: URL?
    /// 操作完成后的轻量反馈（绿色 ✓ 已导出 / 已导入 / 已恢复）。
    @State private var lastActionMessage: String?
    /// 导出时是否包含「按文件夹记忆」（per-folder 分组覆盖 + 隐藏组展开记忆）。默认关 —— 换机器导入不背废路径。
    @AppStorage(AppPreferences.Key.includePerFolderMemoryInBackup) private var includePerFolderMemoryInBackup = false

    var body: some View {
        Form {
            Section(L10n.text("settings.section.backup")) {
                Text(L10n.text("backup.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsActionRow(
                    title: L10n.text("backup.export.title"),
                    description: L10n.text("backup.export.description"),
                    systemImage: "square.and.arrow.up", iconTint: .blue,
                    buttonTitle: L10n.text("backup.export.button"),
                    action: exportPreferences
                )

                SettingsToggleRow(
                    title: L10n.text("backup.includePerFolderMemory"),
                    description: L10n.text("backup.includePerFolderMemory.description"),
                    systemImage: "clock", iconTint: .purple,
                    isOn: $includePerFolderMemoryInBackup
                )

                SettingsActionRow(
                    title: L10n.text("backup.import.title"),
                    description: L10n.text("backup.import.description"),
                    systemImage: "square.and.arrow.down", iconTint: .green,
                    buttonTitle: L10n.text("backup.import.button"),
                    action: pickImportFile
                )

                SettingsActionRow(
                    title: L10n.text("backup.restore.title"),
                    description: L10n.text("backup.restore.description"),
                    systemImage: "arrow.counterclockwise", iconTint: .red,
                    buttonTitle: L10n.text("backup.restore.button"),
                    role: .destructive
                ) {
                    showsRestoreConfirmation = true
                }

                if let lastActionMessage {
                    Text(lastActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .confirmationDialog(
            L10n.text("backup.restore.confirm.title"),
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible
        ) {
            // role: .destructive → 标红 + 不是默认按钮，防止用户回车键直接触发。
            Button(L10n.text("backup.restore.confirm.button"), role: .destructive) {
                // Keychain 清除可能失败（钥匙串锁定 / 权限）—— 失败时不能谎报「已恢复」,
                // 否则用户以为预设密码删了、其实还在钥匙串里。按实际结果给文案。
                let keychainCleared = AppPreferences.restoreAllDefaultsToFactory()
                lastActionMessage = keychainCleared
                    ? L10n.text("backup.restore.done")
                    : L10n.text("backup.restore.keychainFailed")
            }
            Button(L10n.text("button.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("backup.restore.confirm.message"))
        }
        .confirmationDialog(
            L10n.text("backup.import.confirm.title"),
            isPresented: Binding(
                get: { pendingImportURL != nil },
                set: { if !$0 { pendingImportURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("backup.import.confirm.button"), role: .destructive) {
                if let url = pendingImportURL {
                    applyImport(from: url)
                }
                pendingImportURL = nil
            }
            Button(L10n.text("button.cancel"), role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text(L10n.text("backup.import.confirm.message"))
        }
    }

    // MARK: - 行为

    private func exportPreferences() {
        let panel = NSSavePanel()
        panel.title = L10n.text("backup.export.savePanel.title")
        panel.nameFieldStringValue = defaultExportFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let payload = AppPreferences.exportablePayload()
        do {
            // .prettyPrinted 让用户能直接用文本编辑器看 / 微调；.sortedKeys 让 diff 友好。
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            lastActionMessage = L10n.format("backup.export.done", url.lastPathComponent)
        } catch {
            lastActionMessage = L10n.format("backup.export.failed", error.localizedDescription)
        }
    }

    private func pickImportFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("backup.import.openPanel.title")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
    }

    /// 把选定的文件解码 + 写回 UserDefaults。失败时给一条人类可读的提示，不抛出。
    private func applyImport(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastActionMessage = L10n.text("backup.import.failed.malformed")
                return
            }
            try AppPreferences.importPayload(payload)
            lastActionMessage = L10n.format("backup.import.done", url.lastPathComponent)
        } catch let decodeError as PreferencesPayloadCodec.DecodeError {
            lastActionMessage = describe(decodeError)
        } catch {
            lastActionMessage = L10n.format("backup.import.failed.error", error.localizedDescription)
        }
    }

    /// 把 Codec 抛出的 decode 错误翻译成用户能看懂的话。
    private func describe(_ error: PreferencesPayloadCodec.DecodeError) -> String {
        switch error {
        case .missingSchema:
            return L10n.text("backup.import.failed.missingSchema")
        case .foreignSchema(let raw):
            return L10n.format("backup.import.failed.foreignSchema", raw)
        case .unsupportedVersion(let found, let supported):
            return L10n.format("backup.import.failed.unsupportedVersion", found, supported)
        case .missingValues:
            return L10n.text("backup.import.failed.missingValues")
        }
    }

    /// 默认导出文件名：SimpleZip-Preferences-2026-05-29.json 这种形式，
    /// 方便用户在 Downloads 里按日期排着找。
    private func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "SimpleZip-Preferences-\(formatter.string(from: Date())).json"
    }
}
