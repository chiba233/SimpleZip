//
//  BrowserPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 浏览器偏好:决定**列出什么**的选项(显示隐藏文件 + 判定方式 / 符号链接 / Finder 结构)。
/// #20 重新归类:呈现类选项(隐藏组折叠 / 分组去向 / 展开与记忆 / 隐藏后缀显示名)搬去「视图」页,
/// 口径 =「列出什么(内容)归浏览器、怎么呈现归视图」。
///
/// 这些选项一旦改变都会让主窗口立即重新列目录,所以每个控件都要广播
/// `browserPreferencesChanged` 通知 —— 由 ContentView 接收并刷新文件列表。
struct BrowserPane: View {
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.hiddenDetectionMode) private var hiddenDetectionModeRaw = FileBrowserOutline.HiddenDetectionMode.dotfilesOnly.rawValue
    @AppStorage(AppPreferences.Key.showSymbolicLinks) private var showSymbolicLinks = true
    @AppStorage(AppPreferences.Key.followFinderStructure) private var followFinderStructure = false

    var body: some View {
        Form {
            Section(L10n.text("settings.browser.group.hidden")) {
                SettingsToggleRow(
                    title: L10n.text("settings.showHiddenFiles"),
                    description: L10n.text("settings.showHiddenFiles.description"),
                    systemImage: "eye.slash", iconTint: .gray,
                    isOn: $showHiddenFiles
                )
                // 「什么算隐藏文件」判定方式:仅 dotfile(Unix)vs 再算上 macOS UF_HIDDEN 标志。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenDetection"),
                    description: L10n.text("settings.hiddenDetection.description"),
                    systemImage: "list.bullet", iconTint: .blue
                ) {
                    Picker("", selection: $hiddenDetectionModeRaw) {
                        ForEach(FileBrowserOutline.HiddenDetectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }
                .disabled(!showHiddenFiles)
            }

            // 显示与结构:符号链接 + Finder 结构跟随。
            Section(L10n.text("settings.browser.group.display")) {
                SettingsToggleRow(
                    title: L10n.text("settings.showSymbolicLinks"),
                    description: L10n.text("settings.showSymbolicLinks.description"),
                    systemImage: "link", iconTint: .orange,
                    isOn: $showSymbolicLinks
                )
                SettingsToggleRow(
                    title: L10n.text("settings.followFinderStructure"),
                    description: L10n.text("settings.followFinderStructure.description"),
                    systemImage: "sidebar.leading", iconTint: .cyan,
                    isOn: $followFinderStructure
                )
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onChange(of: showHiddenFiles) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenDetectionModeRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: showSymbolicLinks) { _ in notifyBrowserRefresh() }
        .onChange(of: followFinderStructure) { _ in notifyBrowserRefresh() }
    }

    private func notifyBrowserRefresh() {
        NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
    }
}
