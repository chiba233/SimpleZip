//
//  SettingsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 设置窗口的主容器：左侧栏 + 当前选中的 pane。
///
/// 真正的偏好项都放在 `Panes/` 下，每个 pane 自己拥有它需要的 `@AppStorage`。
/// 这里只关心：当前选中哪个 pane、侧栏的展开/收起、以及外部跳转（点表头打开 Columns 面板）。
struct SettingsView: View {
    @State private var selectedPane = SettingsPane.general
    @State private var isSettingsSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSettingsSidebarVisible {
                settingsSidebar
                Divider()
            }

            ZStack(alignment: .topLeading) {
                selectedPaneView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isSettingsSidebarVisible {
                    // 侧栏收起后，左上角悬浮一个展开按钮，避免完全失去入口。
                    sidebarToggleButton(systemImage: "sidebar.leading") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isSettingsSidebarVisible = true
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.top, 10)
                }
            }
        }
        // 旧版本写死了 820×560，长翻译会撑爆 Picker、用户也没法横向拉宽。
        // 改成「有理想尺寸但可以拉」，遵循 macOS 原生 Settings 风格。
        .frame(
            minWidth: 720, idealWidth: 820, maxWidth: .infinity,
            minHeight: 600, idealHeight: 720, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("settings.title"))
    }

    @ViewBuilder
    private var selectedPaneView: some View {
        switch selectedPane {
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
            // 把 selectedPane 的 binding 透出来 —— Health 面板上每条修复按钮可以直接切到对应 pane。
            HealthPane(selectedPane: $selectedPane)
        case .backup:
            BackupPane()
        }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                sidebarToggleButton(systemImage: "sidebar.left") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isSettingsSidebarVisible = false
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsPaneSidebarButton(
                        pane: pane,
                        isSelected: selectedPane == pane
                    ) {
                        selectedPane = pane
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        // 侧栏给一个偏好宽度但允许窗口拉大时整体跟着 main pane 长 —— 侧栏本身保持窄。
        .frame(width: 178)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.bar)
    }

    private func sidebarToggleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(L10n.text("settings.title"))
    }
}
