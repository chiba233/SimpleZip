//
//  ActivityWindowController.swift
//  SimpleZip
//

import AppKit
import SwiftUI

@MainActor
final class ActivityWindowController {
    static let shared = ActivityWindowController()

    private var window: NSWindow?
    private let windowState = ActivityWindowState()

    func show(category: OperationTask.Category? = nil) {
        if let category {
            windowState.select(category: category)
        }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("tasks.window.title")
        window.minSize = NSSize(width: 760, height: 560)
        window.contentViewController = NSHostingController(rootView: ActivityView(taskCenter: .shared, windowState: windowState))
        window.isReleasedWhenClosed = false
        // 普通窗口层级：打开/被点时来到前台，但之后可以被主窗口等正常盖住。
        // 之前用 `.floating` 让它**任何情况下都钉在最上层**（甚至盖住别的 App），不合理 —— 它是个任务列表窗口，不是 HUD。
        window.level = .normal
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
