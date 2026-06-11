//
//  SettingsPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 设置窗口侧栏的分页。
///
/// 用枚举集中描述 pane 的标题、图标，避免 SettingsView 里到处散落 magic string。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case archive
    case browser
    case view
    case fileAssociations
    case gpg
    case updates
    case health
    case backup
    case help
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return L10n.text("settings.section.general")
        case .archive:
            return L10n.text("settings.section.archive")
        case .browser:
            return L10n.text("settings.section.browser")
        case .view:
            return L10n.text("settings.section.view")
        case .fileAssociations:
            return L10n.text("settings.section.fileAssociations")
        case .gpg:
            return L10n.text("settings.section.gpg")
        case .updates:
            return L10n.text("settings.section.updates")
        case .health:
            return L10n.text("settings.section.health")
        case .backup:
            return L10n.text("settings.section.backup")
        case .help:
            return L10n.text("settings.section.help")
        case .about:
            return L10n.text("settings.section.about")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .archive:
            return "archivebox"
        case .browser:
            return "folder"
        case .view:
            return "rectangle.3.group"
        case .fileAssociations:
            return "doc.badge.gearshape"
        case .gpg:
            return "key.fill"
        case .updates:
            return "arrow.triangle.2.circlepath"
        case .health:
            return "heart.text.square"
        case .backup:
            return "arrow.up.arrow.down.square"
        case .help:
            return "lifepreserver"
        case .about:
            return "info.circle"
        }
    }

    /// 侧栏彩色图标瓦片的底色（System Settings 风格，每个分区一色）。
    var iconColor: Color {
        switch self {
        case .general:
            return .gray
        case .archive:
            return .orange
        case .browser:
            return .blue
        case .view:
            return .purple
        case .fileAssociations:
            return .teal
        case .gpg:
            return .green
        case .updates:
            return .red
        case .health:
            return .pink
        case .backup:
            return .indigo
        case .help:
            return .cyan
        case .about:
            return .mint
        }
    }
}

// MARK: - 跨窗口深链（0.4.2）

extension Notification.Name {
    /// 「跳到设置的某个 pane」：菜单栏「关于 SimpleZip」、各处「打开设置」入口共用 —— 多发布者，
    /// 满足 A3 的通知使用条件。object = 目标 `SettingsPane`。
    static let openSettingsPane = Notification.Name("SimpleZip.openSettingsPane")
}

/// 设置窗口深链：窗口没开时用 `pendingPane`（SettingsView onAppear 消费），已开着时走通知即时切页。
@MainActor
enum SettingsDeepLink {
    static var pendingPane: SettingsPane?

    /// 打开设置窗口并定位到 `pane`。走 AppKit 旧式 selector，不依赖 macOS 14+ 的 openSettings。
    static func open(_ pane: SettingsPane) {
        pendingPane = pane
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NotificationCenter.default.post(name: .openSettingsPane, object: pane)
    }

    static func consumePending() -> SettingsPane? {
        defer { pendingPane = nil }
        return pendingPane
    }
}

// SettingsPaneSidebarButton（自绘侧栏按钮）已删 —— 设置窗口改用原生
// NavigationSplitView + List(selection:)，选中态 / hover / 材质全部交给系统。
