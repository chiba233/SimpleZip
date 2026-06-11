//
//  AboutPanel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation

/// 项目外链集合（仓库 / 许可证 / 提交 Bug）—— 帮助菜单与「设置 → 关于」共用。
/// 0.4.2 起系统标准 About 面板下岗（菜单栏「关于」重定向到 设置 → 关于），`show()` 已删。
enum AboutPanel {
    static let projectPage = URL(string: "https://github.com/chiba233/SimpleZip")!
    static let licensePage = URL(string: "https://github.com/chiba233/SimpleZip/blob/main/LICENSE")!
    static let newIssuePage = URL(string: "https://github.com/chiba233/SimpleZip/issues/new")!

    static func openProjectPage() {
        NSWorkspace.shared.open(projectPage)
    }

    static func openLicensePage() {
        NSWorkspace.shared.open(licensePage)
    }

    /// 帮助菜单「提交 Bug」—— 打开 GitHub 新建 issue 页面。
    static func openNewIssuePage() {
        NSWorkspace.shared.open(newIssuePage)
    }

}
