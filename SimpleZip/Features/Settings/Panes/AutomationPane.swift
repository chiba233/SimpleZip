//
//  AutomationPane.swift
//  SimpleZip
//
//  0.4.4 #1:自动化中心 —— 四条自动化通道(CLI / Shortcuts·Siri / URL Scheme / Finder 服务)
//  的状态、入口与按来源统计,一页看全。CLI 安装区从「通用」页整体搬来(单一归属,不留两处入口);
//  Finder 服务的逐项开关仍在「通用」页管理,这里只读总览。
//

import AppKit
import SwiftUI

struct AutomationPane: View {
    @State private var cliStatus: CommandLineToolInstaller.Status = .missing
    @State private var cliManualCommand: String?
    @State private var cliMessage: String?
    /// #1 唯一新偏好:自动化通道(CLI / Shortcuts)允许用预设密码。默认 true 保持现行为;
    /// 关掉后无人值守流程只试空密码,绝不静默动用预设。
    @AppStorage(AppPreferences.Key.automationAllowPresetPassword) private var allowPresetPassword = true
    /// 0.4.4 macOS 26 AI:是否把发布包 / 任务捐献进 Spotlight。默认 true = 便利;关 = 更私密(并清空已索引)。
    @AppStorage(AppPreferences.Key.spotlightIndexingEnabled) private var spotlightIndexing = true

    @ObservedObject private var taskCenter = TaskCenter.shared

    var body: some View {
        Form {
            // ① CLI(安装区自「通用」整体搬来)。
            Section(L10n.text("settings.cli.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.cli.title"),
                    description: L10n.text("settings.cli.description"),
                    systemImage: "terminal", iconTint: .indigo
                ) {
                    HStack(spacing: 8) {
                        if cliStatus != .installed {
                            Button {
                                installCLITool()
                            } label: {
                                Label(L10n.text("settings.cli.install"), systemImage: "link")
                            }
                            // 转译位置(隔离未清的 DMG 直跑)装出来的链接指向一次性挂载路径,禁装。
                            .disabled(CommandLineToolInstaller.isRunningTranslocated)
                        }
                        // 链接存在就给卸载(指向当前 app 或指向别处都算)—— 有装必有卸。
                        if cliStatus != .missing {
                            Button {
                                uninstallCLITool()
                            } label: {
                                Label(L10n.text("settings.cli.uninstall"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                Text(cliStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if CommandLineToolInstaller.isRunningTranslocated {
                    Text(L10n.text("settings.cli.translocated"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cliManualCommand {
                    // 没有 /usr/local/bin 写权限时不提权 —— 给出可复制的终端命令,用户自己 sudo。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("settings.cli.manualHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(cliManualCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cliManualCommand, forType: .string)
                                cliMessage = L10n.text("diagnostics.copied")
                            } label: {
                                Label(L10n.text("settings.cli.copyCommand"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                if let cliMessage {
                    Text(cliMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                lastRunRow(for: .cli)
            }
            .onAppear(perform: reloadCLIStatus)

            // ② Shortcuts / Siri。
            Section(L10n.text("settings.automation.shortcuts.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.shortcuts.title"),
                    description: L10n.text("settings.automation.shortcuts.description"),
                    systemImage: "sparkles.rectangle.stack", iconTint: .purple
                ) {
                    Button {
                        if let url = URL(string: "shortcuts://") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(L10n.text("settings.automation.shortcuts.open"), systemImage: "arrow.up.forward.app")
                    }
                }
                Text(L10n.text("settings.automation.shortcuts.actions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                lastRunRow(for: .intent)
            }

            // ②.5 Spotlight 索引(发布包 / 任务可搜;安全↔便利)。开关切换即时重建或清空索引。
            Section(L10n.text("settings.automation.spotlight.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.spotlight.title"),
                    description: L10n.text("settings.automation.spotlight.description"),
                    systemImage: "magnifyingglass", iconTint: .blue,
                    isOn: $spotlightIndexing
                )
                .onChange(of: spotlightIndexing) { _ in
                    // indexer 内部按 `spotlightIndexingEnabled` 分支:开→重建、关→清空已捐献的索引。
                    ReleasePackageSpotlightIndexer.reindex()
                }
            }

            // ③ URL Scheme(展示型:现状即「每次都要 app 内确认」,不提供关闭项)。
            Section(L10n.text("settings.automation.urlScheme.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.urlScheme.title"),
                    description: L10n.text("settings.automation.urlScheme.description"),
                    systemImage: "link.circle", iconTint: .cyan
                ) {
                    Text(L10n.text("settings.automation.urlScheme.confirmAlways"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "simplezip://check?path=/…  ·  simplezip://compare?left=/…&right=/…  ·  simplezip://open?path=/…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                lastRunRow(for: .urlScheme)
            }

            // ④ Finder 服务(逐项开关在「通用」页;这里只读总览 + 最近一次)。
            Section(L10n.text("settings.automation.finder.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.finder.title"),
                    description: L10n.text("settings.automation.finder.description"),
                    systemImage: "contextualmenu.and.cursorarrow", iconTint: .orange
                ) {
                    Button {
                        NotificationCenter.default.post(name: .openSettingsPane, object: SettingsPane.general)
                    } label: {
                        Label(L10n.text("settings.automation.finder.manage"), systemImage: "gearshape")
                    }
                }
                lastRunRow(for: .finder)
            }

            // ⑤ 统计:活动中心历史按来源聚合(F1 的字段在此兑现)。
            Section(L10n.text("settings.automation.stats.section")) {
                statsRow(.cli, systemImage: "terminal", tint: .indigo)
                statsRow(.intent, systemImage: "sparkles.rectangle.stack", tint: .purple)
                statsRow(.urlScheme, systemImage: "link.circle", tint: .cyan)
                statsRow(.finder, systemImage: "contextualmenu.and.cursorarrow", tint: .orange)
            }

            // ⑥ 安全闸:自动化通道的预设密码使用。
            Section(L10n.text("settings.automation.security.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.allowPresetPassword"),
                    description: L10n.text("settings.automation.allowPresetPassword.description"),
                    systemImage: "key", iconTint: .orange,
                    isOn: $allowPresetPassword
                )
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    // MARK: - 来源统计

    private func tasks(from source: OperationTask.Source) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.source == source }
    }

    /// 「最近一次:<时间>」行(该来源没跑过 = 整行不渲染)。
    @ViewBuilder
    private func lastRunRow(for source: OperationTask.Source) -> some View {
        if let last = tasks(from: source).map({ $0.finishedAt ?? $0.startedAt }).max() {
            Text(L10n.format("settings.automation.lastRun", last.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statsRow(_ source: OperationTask.Source, systemImage: String, tint: Color) -> some View {
        let sourceTasks = tasks(from: source)
        let failures = sourceTasks.filter { if case .failed = $0.status { return true } else { return false } }.count
        return SettingsControlRow(
            title: L10n.text("tasks.source.\(source.rawValue)"),
            description: L10n.text("settings.automation.stats.row.description"),
            systemImage: systemImage, iconTint: tint
        ) {
            Text(sourceTasks.isEmpty
                 ? L10n.text("settings.automation.stats.never")
                 : L10n.format("settings.automation.stats.value", "\(sourceTasks.count)", "\(failures)"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - CLI companion(自 GeneralPane 整体搬来)

    private var cliStatusText: String {
        switch cliStatus {
        case .installed:
            return L10n.format("settings.cli.status.installed", CommandLineToolInstaller.linkPath)
        case .missing:
            return L10n.text("settings.cli.status.missing")
        case .foreign(let destination):
            return L10n.format("settings.cli.status.foreign", destination)
        }
    }

    private func reloadCLIStatus() {
        cliStatus = CommandLineToolInstaller.status()
    }

    private func installCLITool() {
        do {
            try CommandLineToolInstaller.install()
            cliManualCommand = nil
            cliMessage = nil
        } catch CommandLineToolInstaller.InstallError.cancelled {
            // 用户在系统授权弹窗点了取消 —— 不是失败,什么都不弹。
        } catch {
            // 授权路径也失败(罕见)→ 给可复制的手动命令兜底。
            cliManualCommand = CommandLineToolInstaller.manualInstallCommand
            cliMessage = nil
        }
        reloadCLIStatus()
    }

    private func uninstallCLITool() {
        do {
            try CommandLineToolInstaller.uninstall()
            cliManualCommand = nil
            cliMessage = nil
        } catch CommandLineToolInstaller.InstallError.cancelled {
            // 取消授权 —— 静默。
        } catch {
            cliManualCommand = CommandLineToolInstaller.manualUninstallCommand
            cliMessage = nil
        }
        reloadCLIStatus()
    }
}
