//
//  MainWindowTabbing.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/01.
//

import AppKit
import SwiftUI

/// 主窗口原生标签（macOS window tabs）相关常量。
enum MainWindow {
    /// 所有主内容窗口共享的标签分组标识（`NSWindow.tabbingIdentifier` 是 String）。
    /// 相同标识让显式 `addTabbedWindow` 进来的窗口归到同一个标签组。
    static let tabbingIdentifier = "SimpleZip.MainWindow"
    /// 主窗口的 window.identifier —— `hideMainWindowIfPossible` / 冷启动建窗判定都靠它识别「主内容窗口」。
    static let windowIdentifier = NSUserInterfaceItemIdentifier("SimpleZip.Main")

    /// 判断一个 NSWindow 是否是 SimpleZip 主内容窗口（标签）。
    /// 用 identifier 命中，或兜底用 `NSHostingView` content（首帧 identifier 可能还没被设上）。
    static func isMainContentWindow(_ window: NSWindow) -> Bool {
        if window.identifier == windowIdentifier { return true }
        // sheet（parent 非空）/ 辅助窗口不算主窗口。
        if window.parent != nil { return false }
        return window.tabbingIdentifier == tabbingIdentifier
    }
}

/// 「在主窗口打开 .szs 虚拟目录」的直达请求 —— 独立浮窗里用户已经验签完，点「以虚拟目录浏览」时
/// 把已算好的校验报告 + payload root 直接交给新主窗口，省得新窗口再弹一次验签 sheet 重验一遍。
struct SZSVirtualFolderRequest: Equatable {
    let manifestURL: URL
    let report: SZSArchive.VerifyReport
    let payloadRoot: URL
}

/// 主窗口工厂：自己用 AppKit 建窗，**不走** SwiftUI `openWindow`。
///
/// 为什么不用 `openWindow`：它一定会先把新窗口当独立窗口画出来（屏幕中央 / 带动画），下一拍才轮到我们
/// 合并标签 —— 用户看到的就是「闪一个新窗口又并回去」，无法消除。自己建窗则能在窗口 **order-front 之前**
/// 就 `addTabbedWindow` 把它并进宿主标签组，新窗口从不以独立形态出现 → **零闪烁**；同时能精确区分
/// 「新标签（并入当前窗口）」和「新窗口（保持独立、绝不被吞成标签）」。
enum MainWindowFactory {
    /// 强持有工厂建出的窗口控制器 + 它的关闭观察 token —— 否则 `open()` 返回后 ARC 立刻释放本地 window，
    /// 与 AppKit 的窗口列表 / `isReleasedWhenClosed` 语义打架，触发 `objc_release` 过度释放崩溃。
    /// 窗口关闭时移除控制器（释放窗口）并注销观察者。token 用 `let` 存进数组、从数组读取注销，
    /// 避免「var 被 @Sendable 闭包捕获后又赋值」的并发告警。
    private static var liveWindows: [(controller: NSWindowController, token: NSObjectProtocol)] = []

    /// 开一个主窗口。
    /// - asTab == true 且存在主内容窗口宿主：并入它的标签组（同一个窗口里多一个标签，零闪烁）。
    /// - 否则：独立窗口（冷启动 / 「新建窗口」/ 没有可并入的宿主时）。
    /// - openURL：非空时，新窗口出现后在其浏览器里浏览该 URL（右键「在新标签 / 新窗口打开」用）。
    /// - openSZSVirtualFolder：非空时，新窗口直接以虚拟目录浏览该 .szs（独立浮窗「在主窗口打开」用，免重验）。
    @discardableResult
    static func open(asTab: Bool, openURL: URL? = nil, openSZSVirtualFolder: SZSVirtualFolderRequest? = nil) -> NSWindow {
        // chrome 复刻 SwiftUI WindowGroup 给 NavigationSplitView 窗口的样式：`.fullSizeContentView`
        // + 透明标题栏 + unified 工具栏 —— 让侧栏材质延伸到顶、侧栏开关并入标题栏。少了 `.fullSizeContentView`
        // 侧栏会从标题栏下方才开始、标题栏区域空一大块（用户反馈「布局炸了」）。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 我们自己用 NSWindowController 管生命周期；关掉 isReleasedWhenClosed 避免和 ARC 双重释放。
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: ContentView(openURLOnAppear: openURL, openSZSVirtualFolderOnAppear: openSZSVirtualFolder)
        )
        window.identifier = MainWindow.windowIdentifier
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // `.automatic` 跟随系统「偏好标签页」设置、不强制合并；标签是靠显式 addTabbedWindow 实现的。
        window.tabbingMode = .automatic
        window.tabbingIdentifier = MainWindow.tabbingIdentifier

        // 强持有窗口控制器；窗口关闭时释放，避免泄漏 + 避免悬挂。
        let controller = NSWindowController(window: window)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // 从静态数组里找到本窗口的条目：注销观察者 + 移除控制器（→ 窗口释放）。
            // token 不被闭包捕获（从数组读），规避并发告警。
            if let index = liveWindows.firstIndex(where: { $0.controller.window === window }) {
                NotificationCenter.default.removeObserver(liveWindows[index].token)
                liveWindows.remove(at: index)
            }
        }
        liveWindows.append((controller, token))

        if asTab, let host = tabHost() {
            // 并入宿主标签组：先 frame 对齐，再 addTabbedWindow，最后才显示 → 窗口从未以独立形态出现 → 零闪烁。
            window.setFrame(host.frame, display: false)
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            // 标签组此刻已存在 → AppKit 的「显示标签页栏」菜单项也在了，给它补 ⇧⌘T 快捷键。
            bindTabBarMenuShortcut()
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// 找一个可并入的主内容窗口宿主：优先 key 窗口，否则任意可见主内容窗口。
    private static func tabHost() -> NSWindow? {
        if let key = NSApp.keyWindow, MainWindow.isMainContentWindow(key) { return key }
        return NSApp.windows.first { MainWindow.isMainContentWindow($0) && $0.isVisible }
    }

    /// 给 AppKit 自动插入的「显示标签页栏」菜单项（action 为 `toggleTabBar:`）绑定 ⇧⌘T。
    /// AppKit 默认不给它快捷键；这一项只在存在标签组后才出现，所以在首次并标签后调用。幂等：已绑过就跳过。
    private static var didBindTabBarShortcut = false
    static func bindTabBarMenuShortcut() {
        guard !didBindTabBarShortcut, let mainMenu = NSApp.mainMenu else { return }
        guard let item = findMenuItem(in: mainMenu, action: NSSelectorFromString("toggleTabBar:")) else { return }
        item.keyEquivalent = "t"
        item.keyEquivalentModifierMask = [.command, .shift]
        didBindTabBarShortcut = true
    }

    private static func findMenuItem(in menu: NSMenu, action: Selector) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = findMenuItem(in: submenu, action: action) {
                return found
            }
        }
        return nil
    }
}

/// 把 SwiftUI 视图挂到宿主 `NSWindow` 上，给它打上标签标识 —— 主要服务于普通启动时由
/// `WindowGroup` 自动建出的那个首窗（让它也能成为 `addTabbedWindow` 的宿主）。
/// 工厂建出的窗口已经在创建时设好了这些属性，这里重复设也是幂等的。
struct WindowAccessor: NSViewRepresentable {
    final class Coordinator {
        weak var observedToolbar: NSToolbar?
        var displayModeObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window, coordinator: context.coordinator)
    }

    private static func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        // 已是辅助窗口（Settings/About/Sparkle/sheet）不染标签属性 —— 它们不该并进主标签组。
        if window.parent != nil { return }
        window.tabbingMode = .automatic
        window.tabbingIdentifier = MainWindow.tabbingIdentifier
        window.identifier = MainWindow.windowIdentifier
        configureToolbarDisplay(window, coordinator: coordinator)
    }

    /// 主窗口工具栏的「图标 / 图标和文字」显示模式：
    /// - 持久化：直接观察 `displayMode` 并写进稳定 key；SwiftUI 生成的 toolbar identifier 不稳定，不能只靠
    ///   `autosavesConfiguration`；
    /// - 首次默认 = **图标和文字**（纯图标根本看不懂哪个是哪个）——
    ///   只在该 toolbar 从未保存过配置时设置，已有保存值则尊重用户的选择。
    /// SwiftUI 不暴露 NSToolbar.displayMode，所以从宿主 NSWindow 上配；toolbar 由 SwiftUI
    /// 异步挂上，updateNSView 会反复进来；用 coordinator 绑定当前 toolbar 的 KVO，避免静态持有窗口。
    private static func configureToolbarDisplay(_ window: NSWindow, coordinator: Coordinator) {
        guard let toolbar = window.toolbar else { return }
        toolbar.autosavesConfiguration = true

        if coordinator.observedToolbar !== toolbar {
            coordinator.displayModeObservation = nil
            coordinator.observedToolbar = toolbar
            coordinator.displayModeObservation = toolbar.observe(\.displayMode, options: [.new]) { toolbar, _ in
                UserDefaults.standard.set(Int(toolbar.displayMode.rawValue), forKey: toolbarDisplayModeKey)
            }
        }

        if let savedDisplayMode = savedToolbarDisplayMode {
            toolbar.displayMode = savedDisplayMode
            return
        }

        let savedConfigurationKey = "NSToolbar Configuration \(toolbar.identifier)"
        let hasAppKitSavedConfiguration = UserDefaults.standard.dictionary(forKey: savedConfigurationKey) != nil
        if hasAppKitSavedConfiguration {
            UserDefaults.standard.set(Int(toolbar.displayMode.rawValue), forKey: toolbarDisplayModeKey)
            return
        }

        toolbar.displayMode = .iconAndLabel
    }

    private static let toolbarDisplayModeKey = "mainToolbarDisplayMode"

    private static var savedToolbarDisplayMode: NSToolbar.DisplayMode? {
        guard let rawValue = UserDefaults.standard.object(forKey: toolbarDisplayModeKey) as? Int else {
            return nil
        }
        return NSToolbar.DisplayMode(rawValue: UInt(rawValue))
    }
}
