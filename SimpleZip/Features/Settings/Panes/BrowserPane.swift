//
//  BrowserPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 浏览器偏好:决定**列出什么**的选项(显示隐藏文件 + 判定方式 / 符号链接 / Finder 结构)。
/// #20 重新归类:呈现类选项(隐藏组折叠 / 分组去向 / 展开与记忆 / 隐藏后缀显示名)搬去「视图」页,
/// 口径 =「列出什么(内容)归浏览器、怎么呈现归视图」。
///
/// 这些选项一旦改变都会让主窗口立即重新列目录,所以每个控件都要广播
/// `browserPreferencesChanged` 通知 —— 由 ContentView 接收并刷新文件列表。
struct BrowserPane: View {
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = true
    @AppStorage(AppPreferences.Key.hiddenDetectionMode) private var hiddenDetectionModeRaw = FileBrowserOutline.HiddenDetectionMode.dotfilesOnly.rawValue
    @AppStorage(AppPreferences.Key.showSymbolicLinks) private var showSymbolicLinks = true
    @AppStorage(AppPreferences.Key.finderFavoritesSyncEnabled) private var finderFavoritesSyncEnabled = false
    @AppStorage(AppPreferences.Key.followFinderStructure) private var followFinderStructure = false
    @State private var finderFavoritesAccessError: String?

    var body: some View {
        Form {
            Section(L10n.text("settings.browser.group.hidden")) {
                SettingsToggleRow(
                    title: L10n.text("settings.showHiddenFiles"),
                    description: L10n.text("settings.showHiddenFiles.description"),
                    systemImage: "eye.slash", iconTint: .gray,
                    isOn: $showHiddenFiles
                )
                .settingsAnchor("browser.showHidden")
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
                .settingsAnchor("browser.hiddenDetection")
            }

            // 显示与结构:符号链接 + Finder 结构跟随。
            Section(L10n.text("settings.browser.group.display")) {
                SettingsToggleRow(
                    title: L10n.text("settings.showSymbolicLinks"),
                    description: L10n.text("settings.showSymbolicLinks.description"),
                    systemImage: "link", iconTint: .orange,
                    isOn: $showSymbolicLinks
                )
                .settingsAnchor("browser.showSymlinks")
                SettingsControlRow(
                    title: L10n.text("settings.finderFavoritesSync"),
                    description: L10n.text("settings.finderFavoritesSync.description"),
                    systemImage: "star", iconTint: .yellow
                ) {
                    HStack(spacing: 8) {
                        if finderFavoritesSyncEnabled {
                            Button(L10n.text("settings.finderFavoritesSync.authorize")) {
                                requestFinderFavoritesAccess(disableOnCancel: false)
                            }
                        }
                        Toggle("", isOn: Binding(
                            get: { finderFavoritesSyncEnabled },
                            set: setFinderFavoritesSyncEnabled
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .settingsAnchor("browser.finderFavoritesSync")
                if let finderFavoritesAccessError {
                    Text(finderFavoritesAccessError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 40)
                }
                SettingsToggleRow(
                    title: L10n.text("settings.followFinderStructure"),
                    description: L10n.text("settings.followFinderStructure.description"),
                    systemImage: "sidebar.leading", iconTint: .cyan,
                    isOn: $followFinderStructure
                )
                .settingsAnchor("browser.followFinder")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .settingsScrollAnchors()
        .onChange(of: showHiddenFiles) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenDetectionModeRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: showSymbolicLinks) { _ in notifyBrowserRefresh() }
        .onChange(of: followFinderStructure) { _ in notifyBrowserRefresh() }
    }

    private func notifyBrowserRefresh() {
        NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
    }

    private func setFinderFavoritesSyncEnabled(_ enabled: Bool) {
        finderFavoritesAccessError = nil
        guard enabled else {
            AppPreferences.clearFinderFavoritesDirectoryBookmark()
            finderFavoritesSyncEnabled = false
            notifyBrowserRefresh()
            return
        }
        if AppPreferences.hasFinderFavoritesDirectoryBookmark {
            finderFavoritesSyncEnabled = true
            notifyBrowserRefresh()
        } else {
            requestFinderFavoritesAccess(disableOnCancel: true)
        }
    }

    private func requestFinderFavoritesAccess(disableOnCancel: Bool) {
        finderFavoritesAccessError = nil
        let panel = NSOpenPanel()
        panel.title = L10n.text("settings.finderFavoritesSync.panel.title")
        panel.message = L10n.text("settings.finderFavoritesSync.panel.message")
        panel.prompt = L10n.text("settings.finderFavoritesSync.authorize")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            if disableOnCancel {
                finderFavoritesSyncEnabled = false
            }
            return
        }
        guard FinderFavoritesReader.sharedFileListDirectory(from: selectedURL) != nil else {
            finderFavoritesAccessError = L10n.text("settings.finderFavoritesSync.invalidFolder")
            AppPreferences.clearFinderFavoritesDirectoryBookmark()
            finderFavoritesSyncEnabled = false
            notifyBrowserRefresh()
            return
        }
        do {
            let bookmark = try selectedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            AppPreferences.storeFinderFavoritesDirectoryBookmark(bookmark)
            finderFavoritesSyncEnabled = true
            notifyBrowserRefresh()
        } catch {
            finderFavoritesAccessError = L10n.text("settings.finderFavoritesSync.permissionDenied")
            AppPreferences.clearFinderFavoritesDirectoryBookmark()
            finderFavoritesSyncEnabled = false
            notifyBrowserRefresh()
        }
    }
}
