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

/// 侧栏底色：原生 NSVisualEffectView 的 .sidebar 材质（毛玻璃透窗）。
/// 设置 / 活动中心弃用 NavigationSplitView 后（它在 macOS 上既挡不住把手拖塌、也压不过
/// 持久化旧宽度），侧栏改普通 HStack 绝对定宽 —— 材质用这个 representable 补回来。
struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 上下居中侧栏的自绘行：彩色瓦片 + 标题 + 可选计数，自绘选中 / hover 高亮。
/// 原生 List(.sidebar) 做不到「项目整体垂直居中」（用户点名要的布局），
/// 所以行为自绘、外层仍放在 NavigationSplitView 的侧栏列里吃系统材质。
struct CenteredSidebarRow: View {
    let title: String
    let systemImage: String
    let color: Color
    var badge: Int = 0
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                    // 标题优先吃宽度：就算列宽被异常压缩，截断也先发生在留白而不是文字上。
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                            : isHovering
                                ? AnyShapeStyle(Color.primary.opacity(0.07))
                                : AnyShapeStyle(Color.clear)
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help(title)
    }
}

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
