//
//  HealthCheck.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import SwiftUI

/// 单条健康检查项。一次检查 = 一条行，UI 直接渲染数组。
///
/// 设计动机：把「拼装数据」和「展示」彻底拆开 —— `HealthChecker` 负责拼，
/// `HealthPane` 只负责画。模板里固定一个标题 + 一行说明文 + 一个可选的修复按钮，
/// 所有检查共用这套结构，新增检查时只追加一个 `HealthCheckItem`。
struct HealthCheckItem: Identifiable {
    enum Status {
        /// 一切正常。
        case ok
        /// 配置可用但可能不是用户想要的（比如系统默认 app 不是 SimpleZip）。
        case warning
        /// 实际坏掉了，影响功能（比如 bundled 7zz 找不到）。
        case error
        /// 纯信息展示，没有「好坏」之分。
        case info

        /// 行首小图标的 SF Symbol 名。
        var iconName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "info.circle"
            }
        }

        /// 图标颜色 —— 走系统语义色而非硬编码，跟随深色 / 浅色模式自适应。
        var tintColor: Color {
            switch self {
            case .ok: return .green
            case .warning: return .yellow
            case .error: return .red
            case .info: return .secondary
            }
        }
    }

    /// 修复操作。比如「打开 RAR 设置」「管理文件关联」。
    /// 没有合适修复入口的检查项（例如纯信息展示）就传 nil。
    struct FixAction {
        let title: String
        let perform: () -> Void
    }

    let id = UUID()
    let title: String
    let detail: String
    let status: Status
    let action: FixAction?
}

/// 收集所有健康检查项并返回数组。
///
/// 全部跑在 @MainActor 上：检查内容里只有 `ArchiveService.sevenZipVersion` / `rarVersion`
/// 是真正的耗时异步操作（要 spawn 子进程），其它都是同步的 dict / file 查询，
/// 直接 await 一发就拼完。每次按下「重新检查」就重跑一次完整列表，没有缓存复杂度。
@MainActor
enum HealthChecker {

    /// 收集所有项并按显示顺序排好。
    /// `onOpenPane` 回调用来把「打开 RAR 设置」「管理文件关联」这些 action 路由到对应 pane。
    static func gather(onOpenPane: @escaping (SettingsPane) -> Void) async -> [HealthCheckItem] {
        var items: [HealthCheckItem] = []
        items.append(await checkSevenZip())
        items.append(await checkRAR(onOpenSettings: { onOpenPane(.archive) }))
        items.append(checkFileAssociations(onOpenSettings: { onOpenPane(.fileAssociations) }))
        items.append(checkPresetPassword(onOpenSettings: { onOpenPane(.general) }))
        if let gpgItem = await checkGPG(onOpenSettings: { onOpenPane(.gpg) }) {
            items.append(gpgItem)
        }
        return items
    }

    // MARK: - 单项检查

    private static func checkSevenZip() async -> HealthCheckItem {
        let canUse = ArchiveService.canUseSevenZip()
        let backend = ArchiveService.sevenZipBackendDescription()
        let version = await ArchiveService.sevenZipVersion()
        if canUse {
            return HealthCheckItem(
                title: L10n.text("health.sevenZip.title"),
                detail: L10n.format("health.sevenZip.ok", backend, version),
                status: .ok,
                action: nil
            )
        }
        // 7zz 没找到 = 几乎全部高级功能不能用，标红。
        return HealthCheckItem(
            title: L10n.text("health.sevenZip.title"),
            detail: L10n.format("health.sevenZip.missing", backend),
            status: .error,
            action: nil
        )
    }

    private static func checkRAR(onOpenSettings: @escaping () -> Void) async -> HealthCheckItem {
        let canUse = ArchiveService.canCreateRAR()
        let backend = ArchiveService.rarBackendDescription()
        let version = await ArchiveService.rarVersion()
        if canUse {
            return HealthCheckItem(
                title: L10n.text("health.rar.title"),
                detail: L10n.format("health.rar.ok", backend, version),
                status: .ok,
                action: nil
            )
        }
        // RAR 没装属于「可选不致命」，给警告色 + 直通设置的修复按钮。
        return HealthCheckItem(
            title: L10n.text("health.rar.title"),
            detail: L10n.text("health.rar.missing"),
            status: .warning,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.openRarSettings"),
                perform: onOpenSettings
            )
        )
    }

    /// 文件关联：统计 SimpleZip 当前默认了多少种 / 共多少种受支持的格式。
    private static func checkFileAssociations(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        let all = ArchiveAssociationService.supportedAssociations
        let owned = all.filter { ArchiveAssociationService.isSimpleZipDefault(for: $0) }
        if owned.count == all.count {
            return HealthCheckItem(
                title: L10n.text("health.associations.title"),
                detail: L10n.format("health.associations.allOwned", all.count),
                status: .ok,
                action: nil
            )
        }
        // 部分 / 全部没被设为默认 —— 不影响功能但用户可能想知道。
        return HealthCheckItem(
            title: L10n.text("health.associations.title"),
            detail: L10n.format("health.associations.partial", owned.count, all.count),
            status: owned.isEmpty ? .warning : .info,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.openAssociations"),
                perform: onOpenSettings
            )
        )
    }

    /// GPG 后端：仅在 `gpgEnabled == true` 时报告（A4：关掉 GPG 集成 = 主页面不显示 GPG 相关任何东西）。
    /// 一行综合状态：gpg 缺失 → error；gpg 在但 pinentry-mac 缺 → warning；gpg + pinentry 全 ok 但 agent 死 → warning；全绿 → ok + 密钥数量。
    /// detail 文案携带 pinentry-mac / agent 状态 + 密钥计数，不携带 fingerprint / userID。
    private static func checkGPG(onOpenSettings: @escaping () -> Void) async -> HealthCheckItem? {
        guard AppPreferences.gpgEnabled else { return nil }
        guard GPGBackend.isAvailable() else {
            return HealthCheckItem(
                title: L10n.text("health.gpg.title"),
                detail: L10n.text("health.gpg.missing"),
                status: .error,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.gpg.openSettings"),
                    perform: onOpenSettings
                )
            )
        }

        let pinentry = GPGBackend.hasPinentryMac()
        let agentAlive = await GPGBackend.gpgAgentAlive()
        let keys = (try? await GPGBackend.listKeys()) ?? []
        let secretCount = keys.filter { $0.hasSecretKey }.count

        if !pinentry {
            return HealthCheckItem(
                title: L10n.text("health.gpg.title"),
                detail: L10n.format("health.gpg.pinentryMissing", keys.count, secretCount),
                status: .warning,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.gpg.openSettings"),
                    perform: onOpenSettings
                )
            )
        }
        if !agentAlive {
            return HealthCheckItem(
                title: L10n.text("health.gpg.title"),
                detail: L10n.format("health.gpg.agentDown", keys.count, secretCount),
                status: .warning,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.gpg.openSettings"),
                    perform: onOpenSettings
                )
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.gpg.title"),
            detail: L10n.format("health.gpg.ok", keys.count, secretCount),
            status: .ok,
            action: nil
        )
    }

    /// 预设密码：仅在用户启用了这个功能时才报告 ——
    /// 没开 = 静默跳过；开了但 Keychain 里读不出值 = 警告 + 直通通用设置。
    private static func checkPresetPassword(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        guard AppPreferences.presetPasswordEnabled else {
            return HealthCheckItem(
                title: L10n.text("health.presetPassword.title"),
                detail: L10n.text("health.presetPassword.disabled"),
                status: .info,
                action: nil
            )
        }
        if AppPreferences.hasUsablePresetPassword {
            return HealthCheckItem(
                title: L10n.text("health.presetPassword.title"),
                detail: L10n.text("health.presetPassword.ok"),
                status: .ok,
                action: nil
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.presetPassword.title"),
            detail: L10n.text("health.presetPassword.empty"),
            status: .warning,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.openGeneral"),
                perform: onOpenSettings
            )
        )
    }
}
