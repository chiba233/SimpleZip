//
//  MainWindowTabbing.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/01.
//

import AppKit
import SwiftUI

/// 主窗口原生标签（macOS window tabs）相关常量与桥接。
///
/// 设计取舍见 docs / plan：保留单一 valueless `WindowGroup { ContentView() }` +
/// `.handlesExternalEvents(matching: [])`，靠下面的 `WindowAccessor` 给每个宿主 `NSWindow`
/// 设同一个 `tabbingIdentifier` + `tabbingMode = .preferred`，再用 SwiftUI `openWindow()` 开新标签。
/// 不走 `WindowGroup(for:)`（会重新引入 `.siz`/`.szs` 外部事件克隆双窗口），也不全手写 NSWindow 管理。
enum MainWindow {
    /// 主 `WindowGroup` 的标识 —— `openWindow(id:)` 据此开新窗口（=新标签）。
    /// `OpenWindowAction` 没有无参重载，必须给 WindowGroup 一个 id 才能从命令里开它。
    static let windowGroupID = "SimpleZip.main"
    /// 所有主内容窗口共享的标签分组标识（`NSWindow.tabbingIdentifier` 是 String）。
    /// 相同标识 + `.preferred` 模式 → 新窗口强制并成标签，无视系统「偏好标签页」设置
    /// （默认 `.automatic` 会看系统设置，通常不并标签）。
    static let tabbingIdentifier = "SimpleZip.MainWindow"
    /// 主窗口的 window.identifier 前缀——`hideMainWindowIfPossible` / 冷启动建窗判定都靠它识别「主内容窗口」。
    static let windowIdentifier = NSUserInterfaceItemIdentifier("SimpleZip.Main")

    /// 判断一个 NSWindow 是否是 SimpleZip 主内容窗口（标签）。
    /// 用 identifier 命中，或兜底用 `NSHostingView` content（首帧 identifier 可能还没被 accessor 设上）。
    static func isMainContentWindow(_ window: NSWindow) -> Bool {
        if window.identifier == windowIdentifier { return true }
        // sheet（parent 非空）/ 辅助窗口不算主窗口。
        if window.parent != nil { return false }
        return window.contentView is NSHostingView<AnyView>
    }
}

/// 把 SwiftUI 视图挂到宿主 `NSWindow` 上，设标签属性。
///
/// `makeNSView` 时 `view.window` 还是 nil（视图尚未进窗口层级），所以在 `updateNSView`（视图已入窗）里设；
/// 仍保留一次 `DispatchQueue.main.async` 兜底，确保拿到 window。属性是幂等的，重复设无副作用。
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        // 已是辅助窗口（Settings/About/Sparkle/sheet）不染标签属性——它们不该并进主标签组。
        if window.parent != nil { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = MainWindow.tabbingIdentifier
        if window.identifier == nil {
            window.identifier = MainWindow.windowIdentifier
        }
    }
}
