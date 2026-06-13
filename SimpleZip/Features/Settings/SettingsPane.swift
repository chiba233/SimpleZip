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
    case automation
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
        case .automation:
            return L10n.text("settings.section.automation")
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
        case .automation:
            return "bolt.horizontal"
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
        case .automation:
            return .yellow
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
    /// #29:在某个 pane 里把具体设置项滚到可见并短暂高亮。object = 锚点 id 字符串(`.settingsAnchor(_:)` 注册的同一串)。
    static let scrollToSettingsAnchor = Notification.Name("SimpleZip.scrollToSettingsAnchor")
}

/// 设置窗口深链：窗口没开时用 `pendingPane`（SettingsView onAppear 消费），已开着时走通知即时切页。
@MainActor
enum SettingsDeepLink {
    static var pendingPane: SettingsPane?
    /// #29:随 pane 一起带的「滚到这一项」锚点。窗口刚开 / pane 刚挂载时由 `.settingsScrollAnchors()` 的 onAppear 消费;
    /// 已开着同 pane 时走延时通知即时定位(两条路径都幂等,重复滚同一锚点无害)。
    static var pendingAnchor: String?

    /// 打开设置窗口并定位到 `pane`(可选再滚到其中某个设置项 `anchor` 并高亮)。
    ///
    /// **开窗主路径 = SettingsOpenerBridge**（主窗口挂的隐形桥，用官方 `@Environment(\.openSettings)`）——
    /// 私有 selector `showSettingsWindow:` 在 macOS 26 上已失效（用户实测菜单栏「关于」点了没反应）。
    /// 旧 selector 只作兜底（macOS 13 / 主窗口全关时桥不在）。三路都幂等：设置已开就只是提前+切页。
    static func open(_ pane: SettingsPane, anchor: String? = nil) {
        pendingPane = pane
        pendingAnchor = anchor
        NotificationCenter.default.post(name: .openSettingsWindowRequest, object: nil)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NotificationCenter.default.post(name: .openSettingsPane, object: pane)
        // 已开着同 pane 的即时定位:延一拍等 pane 切换 / 内容布局完再发滚动通知(没这个锚点的 pane 收到 = no-op)。
        if let anchor {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .scrollToSettingsAnchor, object: anchor)
            }
        }
    }

    static func consumePending() -> SettingsPane? {
        defer { pendingPane = nil }
        return pendingPane
    }

    static func consumePendingAnchor() -> String? {
        defer { pendingAnchor = nil }
        return pendingAnchor
    }
}

// MARK: - #29 设置项滚动定位 + 高亮(深链 / Spotlight 跳转基建)

private struct SettingsHighlightedAnchorKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// 当前要高亮的设置项锚点(由 `.settingsScrollAnchors()` 下发,`.settingsAnchor(_:)` 行据此闪一下)。
    var settingsHighlightedAnchor: String? {
        get { self[SettingsHighlightedAnchorKey.self] }
        set { self[SettingsHighlightedAnchorKey.self] = newValue }
    }
}

/// 加在 pane 的 `Form` 上:用 ScrollViewReader 包住,收到滚动请求(深链 pendingAnchor / 通知)就把对应
/// `.settingsAnchor(_:)` 行滚到中间并下发高亮,2 秒后自动取消高亮。没有匹配锚点 → scrollTo no-op,安全。
struct SettingsScrollAnchors: ViewModifier {
    @State private var highlighted: String?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.settingsHighlightedAnchor, highlighted)
                .onAppear {
                    // 窗口刚开 / pane 刚切过来:消费深链待定锚点(等内容布局完一拍再滚)。
                    if let anchor = SettingsDeepLink.consumePendingAnchor() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollAndHighlight(anchor, proxy: proxy)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollToSettingsAnchor)) { note in
                    guard let anchor = note.object as? String else { return }
                    scrollAndHighlight(anchor, proxy: proxy)
                }
        }
    }

    private func scrollAndHighlight(_ anchor: String, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(anchor, anchor: .center) }
        highlighted = anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if highlighted == anchor {
                withAnimation(.easeInOut(duration: 0.4)) { highlighted = nil }
            }
        }
    }
}

/// 加在某个设置行 / Section 上:注册滚动锚点 id,并在被深链命中时短暂高亮一圈。
struct SettingsAnchorModifier: ViewModifier {
    let anchorID: String
    @Environment(\.settingsHighlightedAnchor) private var highlighted

    func body(content: Content) -> some View {
        content
            .id(anchorID)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted == anchorID ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -2)
                    .animation(.easeInOut(duration: 0.35), value: highlighted == anchorID)
            )
    }
}

extension View {
    /// pane 的 Form 套这个,启用「滚到某设置项 + 高亮」。
    func settingsScrollAnchors() -> some View { modifier(SettingsScrollAnchors()) }
    /// 设置行 / Section 套这个,注册可被深链 / Spotlight 跳转命中的锚点 id。
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchorModifier(anchorID: id)) }
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
