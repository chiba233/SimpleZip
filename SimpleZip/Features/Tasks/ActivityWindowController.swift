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

    func show(category: OperationTask.Category? = nil, locateTaskID: UUID? = nil, pane: ActivityPane? = nil) {
        // #31:Spotlight 直接指定分页(settings / workspace)—— 没带 category 时按 pane 切。
        if let pane {
            windowState.selectedPane = pane
        }
        if let category {
            windowState.select(category: category)
        }
        // #29:深链 / Spotlight 跳转带的「定位到这条任务」—— 切到它所在分类并请求滚动高亮。
        if let locateTaskID, let category {
            windowState.locate(taskID: locateTaskID, category: category)
        } else if let locateTaskID {
            windowState.locateTaskID = locateTaskID
        }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // 沉浸式标题栏（用户报：设置沉浸、活动中心不沉浸）：设置走 SwiftUI Settings 场景自动配好，
        // 这里是自建 NSWindow —— 之前的 .utilityWindow 老式标题栏 + 不透内容是不沉浸的根源。
        // fullSizeContentView + 透明标题栏 + 隐藏标题文本（标题保留给 Mission Control / 辅助功能），
        // 侧栏毛玻璃就能一直铺到窗口顶。
        let window = NSWindow(
            // 0.4.5:默认尺寸拉大(用户「现在太小了」)。无 frameAutosave,这就是每次新开的默认大小;用户拉伸在会话内保留。
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("tasks.window.title")
        // 0.4.2 用户点名:活动中心要有标题文本(与其他窗口一致)。
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
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
