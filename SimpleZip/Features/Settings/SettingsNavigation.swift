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
    static let browserPreferencesChanged = Notification.Name("SimpleZip.browserPreferencesChanged")
}
