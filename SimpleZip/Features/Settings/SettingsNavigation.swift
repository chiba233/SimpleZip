//
//  SettingsNavigation.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// 浏览器 / 设置间通信的通知名。
///
/// 单独抽出来是因为 ContentView、TableSupport 都要 import 这些通知名，
/// 放在 SettingsView 内部会造成「主界面需要 import SettingsView」的反向依赖。
extension Notification.Name {
    static let requestOpenSettingsColumns = Notification.Name("SimpleZip.requestOpenSettingsColumns")
    static let openSettingsColumns = Notification.Name("SimpleZip.openSettingsColumns")
    static let browserPreferencesChanged = Notification.Name("SimpleZip.browserPreferencesChanged")
}

/// 设置窗口的外部跳转入口。
///
/// `requestOpenColumns` 在 macOS 14+ 直接发通知由 SettingsView 接管；
/// 老系统下需要主动调用 `showSettingsWindow:` 把窗口拉起来再切换 pane，
/// 因此用 `shouldOpenColumns` 这个一次性 flag 缓存意图。
@MainActor
enum SettingsNavigation {
    private static var shouldOpenColumns = false

    static func requestOpenColumns() {
        if #available(macOS 14.0, *) {
            NotificationCenter.default.post(name: .requestOpenSettingsColumns, object: nil)
        } else {
            openColumnsLegacy()
        }
    }

    static func prepareOpenColumns() {
        shouldOpenColumns = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettingsColumns, object: nil)
        }
    }

    static func openColumnsLegacy() {
        prepareOpenColumns()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func consumePendingColumnsRequest() -> Bool {
        defer { shouldOpenColumns = false }
        return shouldOpenColumns
    }
}
