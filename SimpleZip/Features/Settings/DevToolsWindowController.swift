//
//  DevToolsWindowController.swift
//  SimpleZip
//
//  开发者工具(隐藏调试区)的独立窗口 —— 不再硬塞进「设置 → 关于」的 sheet 里(那里受限、改不动东西)。
//  形态对齐活动中心:自建沉浸式 NSWindow(fullSizeContentView + 透明标题栏),可自由拉伸。
//  入口仍隐蔽:设置 → 关于 → ⌘点版本胶囊触发(不打扰常规用户)。
//

import AppKit
import SwiftUI

@MainActor
final class DevToolsWindowController {
    static let shared = DevToolsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("devtools.title")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 680, height: 520)
        // DevToolsView() 不传 onClose → 窗口形态(满高滚动 + 不渲染底部关闭条,靠窗口自带关闭)。
        window.contentViewController = NSHostingController(rootView: DevToolsView())
        window.isReleasedWhenClosed = false
        window.level = .normal
        // 记忆用户拉伸后的宽高 / 位置(跨开关、跨重启)—— AppKit 自动存进 UserDefaults。
        // 先 center 给首次默认居中,再设 autosave;有存档时 setFrameUsingName 会覆盖回上次尺寸。
        window.center()
        window.setFrameAutosaveName("SimpleZipDevToolsWindow")
        window.setFrameUsingName("SimpleZipDevToolsWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
