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
        items.append(checkFinderServices(onOpenSettings: { onOpenPane(.general) }))
        items.append(checkShortcuts(onOpenSettings: { onOpenPane(.automation) }))
        items.append(checkStartupLocation(onOpenSettings: { onOpenPane(.general) }))
        items.append(checkSecurityPolicies(onOpenSettings: { onOpenPane(.archive) }))
        items.append(checkSoftwareUpdates(onOpenSettings: { onOpenPane(.updates) }))
        items.append(checkPresetPassword(onOpenSettings: { onOpenPane(.general) }))
        items.append(checkSecureScratchVolume())
        if let gpgItem = await checkGPG(onOpenSettings: { onOpenPane(.gpg) }) {
            items.append(gpgItem)
        }
        return items
    }

    /// 加密临时卷（0.4.1，用户点名）：解密 / 解压的临时产物应落在启动时挂载的 AES-256 加密卷里。
    /// 挂着 → ok（带挂载点路径）；没挂着 → warning（临时产物会回落普通临时目录,明文可能落盘）+
    /// 「重新挂载」修复按钮（挂载是异步的,按完再点「重新检查」看结果）。
    private static func checkSecureScratchVolume() -> HealthCheckItem {
        if let mountPoint = SecureScratchVolume.shared.currentMountPoint {
            return HealthCheckItem(
                title: L10n.text("health.scratchVolume.title"),
                detail: L10n.format("health.scratchVolume.ok", mountPoint.path),
                status: .ok,
                action: nil
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.scratchVolume.title"),
            detail: L10n.text("health.scratchVolume.notMounted"),
            status: .warning,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.scratchVolume.remount"),
                perform: {
                    Task { _ = try? await SecureScratchVolume.shared.ensureMounted() }
                }
            )
        )
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

    /// Finder Services + simplezip:// 回调都来自 Info.plist。Services 缺失时右键快捷操作不会注册；
    /// URL scheme 缺失时 Services / 外部入口回调无法回到 App。
    private static func checkFinderServices(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? []
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let hasSimpleZipScheme = urlTypes.contains { type in
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains("simplezip")
        }
        guard !services.isEmpty, hasSimpleZipScheme else {
            return HealthCheckItem(
                title: L10n.text("health.finderServices.title"),
                detail: L10n.text("health.finderServices.missing"),
                status: .error,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.openGeneral"),
                    perform: onOpenSettings
                )
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.finderServices.title"),
            detail: L10n.format("health.finderServices.ok", services.count),
            status: .ok,
            action: nil
        )
    }

    /// 0.4.5:Shortcuts / Siri 按签名门控 —— ad-hoc 构建(无 Apple TeamIdentifier)下 App Intents 被 linkd 以
    /// requiresValidatedBundle 拒,快捷指令 / Siri 注定跑不起来(「快捷指令」app 仍会列出动作,系统层无法在 app 内移除)。
    /// 没签名 → warning(黄),明确告知用不了 + 直通自动化设置;有签名 → ok。
    private static func checkShortcuts(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        if AppSigningStatus.supportsShortcuts {
            return HealthCheckItem(
                title: L10n.text("health.shortcuts.title"),
                detail: L10n.text("health.shortcuts.ok"),
                status: .ok,
                action: nil
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.shortcuts.title"),
            detail: L10n.text("health.shortcuts.unavailable"),
            status: .warning,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.openAutomation"),
                perform: onOpenSettings
            )
        )
    }

    /// 启动位置失效时 App 会回落到 home，但用户在「为什么没打开我选的文件夹」时需要在运行状态里看到原因。
    private static func checkStartupLocation(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        let location = AppPreferences.startupLocation
        if AppPreferences.startupLocationIsMissing {
            let configured = AppPreferences.resolvedURL(for: location)?.path ?? location.title
            return HealthCheckItem(
                title: L10n.text("health.startupLocation.title"),
                detail: L10n.format("health.startupLocation.missing", configured),
                status: .warning,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.openGeneral"),
                    perform: onOpenSettings
                )
            )
        }
        if let url = AppPreferences.resolvedURL(for: location) {
            return HealthCheckItem(
                title: L10n.text("health.startupLocation.title"),
                detail: L10n.format("health.startupLocation.ok", location.title, url.path),
                status: .ok,
                action: nil
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.startupLocation.title"),
            detail: L10n.format("health.startupLocation.fallback", location.title),
            status: .info,
            action: HealthCheckItem.FixAction(
                title: L10n.text("health.openGeneral"),
                perform: onOpenSettings
            )
        )
    }

    /// 安全策略是 archive manager 的高风险开关：Allow 会让不可信归档更容易落盘/执行；
    /// Deny 会阻止对应工作流但不降低安全性，所以只作为 info 展示。
    private static func checkSecurityPolicies(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        let policies: [(name: String, decision: ArchiveSecurityDecision)] = [
            (L10n.text("settings.security.suspiciousPaths"), AppPreferences.suspiciousPathPolicy),
            (L10n.text("settings.security.symbolicLinks"), AppPreferences.symbolicLinkPolicy),
            (L10n.text("settings.security.activeContent"), AppPreferences.activeContentOpenPolicy)
        ]
        let allowed = policies.filter { $0.decision == .allow }.map(\.name)
        if !allowed.isEmpty {
            return HealthCheckItem(
                title: L10n.text("health.security.title"),
                detail: L10n.format("health.security.allows", allowed.joined(separator: ", ")),
                status: .warning,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.openArchiveSettings"),
                    perform: onOpenSettings
                )
            )
        }
        let denied = policies.filter { $0.decision == .deny }.map(\.name)
        if !denied.isEmpty {
            return HealthCheckItem(
                title: L10n.text("health.security.title"),
                detail: L10n.format("health.security.denies", denied.joined(separator: ", ")),
                status: .info,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.openArchiveSettings"),
                    perform: onOpenSettings
                )
            )
        }
        return HealthCheckItem(
            title: L10n.text("health.security.title"),
            detail: L10n.text("health.security.ok"),
            status: .ok,
            action: nil
        )
    }

    /// Sparkle 的 release 安全依赖 Info.plist 里的 appcast URL + EdDSA 公钥；缺任一项都应该在运行状态里标红。
    private static func checkSoftwareUpdates(onOpenSettings: @escaping () -> Void) -> HealthCheckItem {
        let rawFeedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        let intervalValue = Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval")
        let interval = (intervalValue as? Int) ?? (intervalValue as? NSNumber)?.intValue ?? 0
        let feedURL = URL(string: rawFeedURL)
        guard let feedURL, feedURL.scheme == "https", !publicKey.isEmpty, interval > 0 else {
            return HealthCheckItem(
                title: L10n.text("health.updates.title"),
                detail: L10n.text("health.updates.missing"),
                status: .error,
                action: HealthCheckItem.FixAction(
                    title: L10n.text("health.openUpdates"),
                    perform: onOpenSettings
                )
            )
        }
        let launchCheck = AppPreferences.checkForUpdatesOnLaunch
            ? L10n.text("health.updates.launchCheckOn")
            : L10n.text("health.updates.launchCheckOff")
        return HealthCheckItem(
            title: L10n.text("health.updates.title"),
            detail: L10n.format("health.updates.ok", feedURL.host ?? feedURL.absoluteString, launchCheck),
            status: .ok,
            action: nil
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
