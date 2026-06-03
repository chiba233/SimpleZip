//
//  SidebarToggleButton.swift
//  SimpleZip
//
//  0.3.0 去重：设置窗口（SettingsView）和活动中心（ActivityView）各自手写过一个一模一样的
//  「折叠/展开侧栏」工具栏按钮（同 image 字号 / 同 20×20 frame / borderless / controlSize.small），
//  唯一差别是 `.help` 提示文案。抽成共享 View，help 文案由调用方传入，零行为变更。
//
//  注：#94 的另一半（CollapsibleSidebarShell —— 侧栏宽度 / `.background(.bar)` / 收起动画的同构外壳）
//  涉及行为，按「先抽按钮」的最小范围暂不一并处理。
//

import SwiftUI

/// 工具栏里的「折叠/展开侧栏」按钮。`systemImage` 用 `sidebar.leading` / `sidebar.left` 等，
/// `help` 是 hover 提示文案（各窗口不同）。
struct SidebarToggleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(help)
    }
}
