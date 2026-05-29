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
/// - **不公证 / 不签名** —— 现阶段没有 Apple Developer ID。用户安装新版需要在 Finder 右键「打开」绕过 Gatekeeper。
///   README 会专门说明这条；如果将来社区有人愿意提供签名身份再加上。
/// - **不做 EdDSA 包完整性签名** —— 同样因为没有签名身份。Sparkle 仍然能拉 appcast、提示「有新版」、下载并替换；
///   只是没有「下载的 DMG 跟开发者发布的字节一致」的密码学证据。可后期补。
/// - **Appcast URL** 写在 Info.plist 的 `SUFeedURL`，指向 `https://raw.githubusercontent.com/chiba233/SimpleZip/main/docs/appcast.xml`。
///   release.yml 在 GitHub Release publish 后会生成 / 更新这个文件。
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
    /// 第二个参数 `updaterDelegate` / 第三个 `userDriverDelegate` 这里都不需要自定义。
    let controller: SPUStandardUpdaterController

    /// 暴露 updater 给「静默检查」用 —— 助手里跑 `checkForUpdateInformation()` 不弹 Sparkle UI。
    var updater: SPUUpdater { controller.updater }

    private init() {
        // `startingUpdater: true` 让 Sparkle 在创建瞬间立刻自动开始周期检查（按 SUScheduledCheckInterval 走）。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 「检查更新…」菜单项调这个。Sparkle 自己负责弹完整的「有新版 / 已经最新」UI。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
