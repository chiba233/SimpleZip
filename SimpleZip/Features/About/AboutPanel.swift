//
//  AboutPanel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation

/// 系统标准 About 面板。
///
/// 走 `NSApplication.orderFrontStandardAboutPanel`：跟随系统主题、字号、间距，
/// 关闭按钮 / 标题栏 / 居中弹窗这些行为 macOS 自己管，省得自己手画 SwiftUI 弹层。
///
/// credits 字段刻意留短（描述一句 + 作者一行）—— 内容超过面板默认高度就会出现滚动条 + 文本框边框，
/// 反而显得难看。仓库地址 / 许可证这种「链接式入口」改放在「帮助」菜单里当系统原生菜单项，
/// 既符合 macOS 习惯，又避免 credits 文本块膨胀。
enum AboutPanel {
    static let projectPage = URL(string: "https://github.com/chiba233/SimpleZip")!
    static let licensePage = URL(string: "https://github.com/chiba233/SimpleZip/blob/main/LICENSE")!

    static func show() {
        let credits = makeCredits()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "SimpleZip",
            .credits: credits,
            // 底部一行版权 —— 系统标准 About 面板默认就有这条灰色小字位。
            .init(rawValue: "Copyright"): L10n.text("about.copyright")
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    static func openProjectPage() {
        NSWorkspace.shared.open(projectPage)
    }

    static func openLicensePage() {
        NSWorkspace.shared.open(licensePage)
    }

    /// 描述 + 作者，两行；够短就不会触发系统 About 面板的 credits 滚动条。
    private static func makeCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]

        let text = L10n.text("about.description") + "\n" + L10n.text("about.author")
        return NSAttributedString(string: text, attributes: attributes)
    }
}
