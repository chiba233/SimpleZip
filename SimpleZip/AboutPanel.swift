//
//  AboutPanel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation

/// 关于面板：集中管理应用介绍和项目主页入口。
enum AboutPanel {
    static let projectPage = URL(string: "https://github.com/chiba233/SimpleZip")!

    static func show() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 3

        let credits = NSAttributedString(
            string: "\(L10n.text("about.description"))\n\n\(L10n.text("about.projectPage"))\n\(projectPage.absoluteString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "SimpleZip",
            .credits: credits
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    static func openProjectPage() {
        NSWorkspace.shared.open(projectPage)
    }
}
