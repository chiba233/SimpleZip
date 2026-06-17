//
//  SparkleUpdater.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation
import Sparkle

/// 全局唯一的 Sparkle 更新控制器封装。
///
/// 决策记录（详见 CHANGELOG / docs/release-checklist.md）：
/// - **EdDSA 包完整性签名（v0.1.10 起强制）** —— Info.plist 的 `SUPublicEDKey` 是发版签名公钥；
///   release.yml 在 GitHub Release publish 前会跑 `sign_update`，用 GitHub Secret `SPARKLE_ED_PRIVATE_KEY`
///   对 DMG 签名，并把 `sparkle:edSignature=...` 写进 appcast enclosure。客户端 Sparkle 下载后用 `SUPublicEDKey`
///   校验签名，过不了直接拒绝安装 —— 这给「下载到的 DMG 跟仓库 release 一字节都不差」提供了密码学证据，
///   防止 raw.githubusercontent.com 路径上的 MITM / 仓库被妥协后伪造 release。
/// - **Appcast URL** 写在 Info.plist 的 `SUFeedURL`，指向 `https://raw.githubusercontent.com/chiba233/SimpleZip/main/docs/appcast.xml`。
///   release.yml 在 GitHub Release publish 后会生成 / 更新这个文件。
/// - **Beta channel**：appcast 同一个文件，beta item 带 `sparkle:channel="beta"`；用户在设置 → 软件更新
///   开启「加入 Beta 更新」后，delegate 返回 `["beta"]`，Sparkle 同时看到 stable 和 beta item。
///
/// 用法：
/// - App 启动时 `SimpleZipApp.init()` 拿一次 `shared.controller`，构造 Sparkle 自己的菜单管理器。
/// - 「检查更新」菜单项调 `controller.checkForUpdates(_:)`。
/// - 欢迎助手第 2 步通过 `controller.updater.checkForUpdateInformation()` 跑静默版本检查
///   （不弹 Sparkle UI，把结果转成助手内嵌的 banner）。
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    /// Sparkle 提供的「标准」更新控制器 —— 给菜单项、欢迎助手的检查按钮等共用。
    let controller: SPUStandardUpdaterController

    /// 暴露 updater 给「静默检查」用 —— 助手里跑 `checkForUpdateInformation()` 不弹 Sparkle UI。
    var updater: SPUUpdater { controller.updater }

    /// #31:给 Siri/Spotlight「直接开关」无 UI 切换「自动下载并安装更新」用的薄壳 —— 真值由 Sparkle
    /// 自己持久化,这里只读 / 写它,不把 `SPUUpdater` 类型泄漏进 App Intents 层(那边无需 import Sparkle)。
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    private let delegate = UpdaterDelegate()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    /// 用户切换 beta 开关后调用 —— 通知 Sparkle 重新检查（delegate 会返回新的 channels）。
    func syncBetaChannel() {
        updater.resetUpdateCycleAfterShortDelay()
    }

    /// 「检查更新…」菜单项调这个。Sparkle 自己负责弹完整的「有新版 / 已经最新」UI。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 启动时调一次：若用户在「通用」里开了「每次启动时检查更新」，跑一次**后台**检查 ——
    /// `checkForUpdatesInBackground()` 只在发现新版时才弹 UI，已是最新则静默，不打扰用户。
    /// （与 Sparkle 自带的周期后台检查叠加，不冲突。）
    func checkForUpdatesOnLaunchIfEnabled() {
        guard AppPreferences.checkForUpdatesOnLaunch else { return }
        updater.checkForUpdatesInBackground()
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let enabled = UserDefaults.standard.bool(forKey: AppPreferences.Key.betaUpdatesEnabled)
        return enabled ? Set(["beta"]) : Set()
    }
}
