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
    /// 「把设置窗口打开」—— 由主窗口的 SettingsOpenerBridge 用官方 openSettings 处理（macOS 14+）。
    static let openSettingsWindowRequest = Notification.Name("SimpleZip.openSettingsWindowRequest")
}

/// 设置窗口深链：窗口没开时用 `pendingPane`（SettingsView onAppear 消费），已开着时走通知即时切页。
@MainActor
enum SettingsDeepLink {
    static var pendingPane: SettingsPane?

    /// 打开设置窗口并定位到 `pane`。
    ///
    /// **开窗主路径 = SettingsOpenerBridge**（主窗口挂的隐形桥，用官方 `@Environment(\.openSettings)`）——
    /// 私有 selector `showSettingsWindow:` 在 macOS 26 上已失效（用户实测菜单栏「关于」点了没反应）。
    /// 旧 selector 只作兜底（macOS 13 / 主窗口全关时桥不在）。三路都幂等：设置已开就只是提前+切页。
    static func open(_ pane: SettingsPane) {
        pendingPane = pane
        NotificationCenter.default.post(name: .openSettingsWindowRequest, object: nil)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NotificationCenter.default.post(name: .openSettingsPane, object: pane)
    }

    static func consumePending() -> SettingsPane? {
        defer { pendingPane = nil }
        return pendingPane
    }
}

// SettingsPaneSidebarButton（自绘侧栏按钮）已删 —— 设置窗口改用原生
// NavigationSplitView + List(selection:)，选中态 / hover / 材质全部交给系统。


/// 主窗口底下的隐形桥：收到 `.openSettingsWindowRequest` 就用官方 openSettings 开设置窗口。
/// 必须挂在**普通窗口**的视图树里（environment action 只在视图上下文可用，Commands 里拿不到）。
struct SettingsOpenerBridge: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsOpenerBridgeModern()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

@available(macOS 14.0, *)
private struct SettingsOpenerBridgeModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindowRequest)) { _ in
                openSettings()
            }
    }
}
