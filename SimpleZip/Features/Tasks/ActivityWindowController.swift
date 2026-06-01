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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("tasks.window.title")
        window.contentViewController = NSHostingController(rootView: ActivityView(taskCenter: .shared, windowState: windowState))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
