//
//  SettingsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  0.3.3 UI 现代化：手画的 HStack 侧栏（自定义按钮 + 自管开关）重绘成原生
//  NavigationSplitView + List(selection:) —— 系统设置同款：原生选中态、原生侧栏开关、
//  系统材质（macOS 26 上自动玻璃化），少掉一整套自绘 chrome。
//

import SwiftUI

/// 设置窗口的主容器：原生侧栏 + 当前选中的 pane。
///
/// 真正的偏好项都放在 `Panes/` 下，每个 pane 自己拥有它需要的 `@AppStorage`。
/// 这里只关心：当前选中哪个 pane、以及外部跳转（健康面板的修复按钮直接切 pane）。
struct SettingsView: View {
    @State private var selectedPane: SettingsPane? = .general

    var body: some View {
        // 弃用 NavigationSplitView：macOS 上它的把手照样能把侧栏拖塌（constant(.all) 拦不住）、
        // 持久化旧宽度还会压过钉宽声明（用户连报两次）。普通 HStack + frame(width:) 绝对定宽 ——
        // 物理上没有把手、没有折叠、没有持久化；侧栏毛玻璃用 SidebarBackdrop 补回。
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 12)
                ForEach(SettingsPane.allCases) { pane in
                    CenteredSidebarRow(
                        title: pane.title,
                        systemImage: pane.systemImage,
                        color: pane.iconColor,
                        isSelected: selectedPane == pane
                    ) {
                        selectedPane = pane
                    }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            // 自适应宽（同活动中心）：取最宽 pane 名的内容宽度，任何语言都不截断。
            .frame(minWidth: 200)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .background(SidebarBackdrop().ignoresSafeArea())

            Divider()
                .ignoresSafeArea()

            selectedPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 有理想尺寸但可以拉，遵循 macOS 原生 Settings 风格（写死尺寸会被长翻译撑爆）。
        .frame(
            minWidth: 880, idealWidth: 980, maxWidth: .infinity,
            minHeight: 660, idealHeight: 780, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("settings.title"))
    }

    /// 健康面板需要可写的 selectedPane（修复按钮跳对应 pane）；List 的 selection 是 Optional，
    /// 这里折回非 Optional binding —— 清空选择时落回「通用」。
    private var selectedPaneBinding: Binding<SettingsPane> {
        Binding(
            get: { selectedPane ?? .general },
            set: { selectedPane = $0 }
        )
    }

    @ViewBuilder
    private var selectedPaneView: some View {
        switch selectedPane ?? .general {
        case .general:
            GeneralPane()
        case .archive:
            ArchivePane()
        case .browser:
            BrowserPane()
        case .view:
            ColumnsPane()
        case .fileAssociations:
            FileAssociationsPane()
        case .gpg:
            GPGPane()
        case .health:
            HealthPane(selectedPane: selectedPaneBinding)
        case .backup:
            BackupPane()
        }
    }
}
