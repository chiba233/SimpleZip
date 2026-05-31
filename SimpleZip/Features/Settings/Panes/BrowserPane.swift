//
//  BrowserPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 浏览器偏好：是否显示隐藏文件 / 符号链接、是否跟随 Finder 结构、隐藏后缀名管理。
///
/// 这些选项一旦改变都会让主窗口立即重新列目录，所以每个 toggle 都要广播
/// `browserPreferencesChanged` 通知 —— 由 ContentView 接收并刷新文件列表。
struct BrowserPane: View {
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.hiddenDetectionMode) private var hiddenDetectionModeRaw = FileBrowserOutline.HiddenDetectionMode.dotfilesOnly.rawValue
    @AppStorage(AppPreferences.Key.hiddenGroupCollapseMode) private var hiddenGroupCollapseModeRaw = FileBrowserOutline.CollapseMode.alwaysCollapsed.rawValue
    @AppStorage(AppPreferences.Key.hiddenWithGrouping) private var hiddenWithGroupingRaw = BrowserGrouping.HiddenWithGrouping.foldIntoGroups.rawValue
    @AppStorage(AppPreferences.Key.showSymbolicLinks) private var showSymbolicLinks = true
    @AppStorage(AppPreferences.Key.followFinderStructure) private var followFinderStructure = false
    @AppStorage(AppPreferences.Key.hiddenSuffixesEnabled) private var hiddenSuffixesEnabled = true

    @State private var showsHiddenSuffixDrawer = false
    // 推荐后缀 / 自定义后缀这两个数组的真源是 AppPreferences 的辅助方法（带去重 / 归一），
    // 所以这里只保留 @State 镜像，再用 onChange 写回真源 + 广播通知。
    @State private var hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
    @State private var hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
    @State private var hiddenSuffixInput = ""

    var body: some View {
        Form {
            Section(L10n.text("settings.section.browser")) {
                SettingsToggleRow(
                    title: L10n.text("settings.showHiddenFiles"),
                    description: L10n.text("settings.showHiddenFiles.description"),
                    isOn: $showHiddenFiles
                )
                // 「什么算隐藏文件」判定方式：仅 dotfile（Unix）vs 再算上 macOS UF_HIDDEN 标志。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenDetection"),
                    description: L10n.text("settings.hiddenDetection.description")
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

                // 隐藏文件折叠记忆策略 —— 只在显示隐藏文件时才有意义，所以关掉时整行变灰但仍可见，
                // 让用户知道这个选项存在。改了之后从下一次进文件夹起生效。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenGroupCollapse"),
                    description: L10n.text("settings.hiddenGroupCollapse.description")
                ) {
                    Picker("", selection: $hiddenGroupCollapseModeRaw) {
                        ForEach(FileBrowserOutline.CollapseMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }
                .disabled(!showHiddenFiles)

                // 开启「按种类」分类 + 显示隐藏文件时，隐藏文件融进各分类组、还是单列一个隐藏组。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenWithGrouping"),
                    description: L10n.text("settings.hiddenWithGrouping.description")
                ) {
                    Picker("", selection: $hiddenWithGroupingRaw) {
                        ForEach(BrowserGrouping.HiddenWithGrouping.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }
                .disabled(!showHiddenFiles)

                SettingsToggleRow(
                    title: L10n.text("settings.showSymbolicLinks"),
                    description: L10n.text("settings.showSymbolicLinks.description"),
                    isOn: $showSymbolicLinks
                )
                SettingsToggleRow(
                    title: L10n.text("settings.followFinderStructure"),
                    description: L10n.text("settings.followFinderStructure.description"),
                    isOn: $followFinderStructure
                )

                hiddenSuffixHeader

                if showsHiddenSuffixDrawer {
                    hiddenSuffixDrawer
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onAppear {
            // 进入面板时把真源拉一次，避免之前在别的 pane 里改过造成不一致。
            hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
            hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
        }
        .onChange(of: showHiddenFiles) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenDetectionModeRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenGroupCollapseModeRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: showSymbolicLinks) { _ in notifyBrowserRefresh() }
        .onChange(of: followFinderStructure) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenSuffixesEnabled) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenRecommendedSuffixes) { newValue in
            AppPreferences.setHiddenRecommendedSuffixes(newValue)
            // 回填规范化后的值（去重 / 大小写归一），保持 UI 与真源一致。
            hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
            notifyBrowserRefresh()
        }
        .onChange(of: hiddenCustomSuffixes) { newValue in
            AppPreferences.setHiddenCustomSuffixes(newValue)
            hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
            notifyBrowserRefresh()
        }
    }

    /// 隐藏后缀的「总开关 + 展开抽屉」一行。
    ///
    /// 之所以没用 `SettingsToggleRow`：这一行不仅有 toggle，还要带一个抽屉展开按钮，
    /// 描述与开关之间还要塞一个 chevron，跟通用模板有差异。
    private var hiddenSuffixHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("settings.hiddenSuffixesEnabled"))
                    .font(.callout)
                Text(L10n.text("settings.hiddenSuffixesEnabled.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsHiddenSuffixDrawer.toggle()
                }
            } label: {
                Image(systemName: showsHiddenSuffixDrawer ? "chevron.down" : "chevron.right")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("settings.hiddenSuffixes"))
            Toggle("", isOn: $hiddenSuffixesEnabled)
                .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private var hiddenSuffixDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("settings.hiddenSuffixes.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            recommendedSuffixGroup
            customSuffixGroup
        }
        .padding(.top, 6)
        .padding(.leading, 20)
        // 关掉总开关时整个抽屉变灰但仍可见，让用户知道这里的设置「记着但暂时不生效」。
        .disabled(!hiddenSuffixesEnabled)
    }

    private var recommendedSuffixGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("settings.hiddenSuffixes.recommended"))
                .font(.headline)
            ForEach(AppPreferences.recommendedHiddenSuffixes, id: \.self) { suffix in
                let normalizedSuffix = AppPreferences.normalizedHiddenSuffix(suffix)
                Toggle(
                    ".\(suffix)",
                    isOn: Binding(
                        get: { hiddenRecommendedSuffixes.contains { AppPreferences.normalizedHiddenSuffix($0) == normalizedSuffix } },
                        set: { shouldHide in
                            if shouldHide {
                                hiddenRecommendedSuffixes.append(suffix)
                            } else {
                                hiddenRecommendedSuffixes.removeAll { $0.caseInsensitiveCompare(suffix) == .orderedSame }
                            }
                        }
                    )
                )
            }
        }
    }

    private var customSuffixGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("settings.hiddenSuffixes.custom"))
                .font(.headline)

            if hiddenCustomSuffixes.isEmpty {
                Text(L10n.text("settings.hiddenSuffixes.customEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hiddenCustomSuffixes, id: \.self) { suffix in
                    HStack {
                        Text(".\(suffix)")
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            hiddenCustomSuffixes.removeAll { $0 == suffix }
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 24, alignment: .center)
                        .help(L10n.text("settings.hiddenSuffixes.remove"))
                    }
                    .frame(minHeight: 24)
                }
            }

            customSuffixInputRow
        }
    }

    private var customSuffixInputRow: some View {
        HStack {
            let normalizedSuffix = AppPreferences.normalizedHiddenSuffix(hiddenSuffixInput)
            // 避免重复添加：自定义 + 推荐列表里已有的都拦下。
            let blockedSuffixes = Set((hiddenCustomSuffixes + hiddenRecommendedSuffixes).map { $0.lowercased() })
            Text(".")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: $hiddenSuffixInput,
                prompt: Text(L10n.text("settings.hiddenSuffixes.customPlaceholder"))
                    .foregroundColor(.secondary)
            )
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
            Button {
                hiddenCustomSuffixes.append(normalizedSuffix)
                hiddenSuffixInput = ""
            } label: {
                Label(L10n.text("button.add"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(normalizedSuffix.isEmpty || blockedSuffixes.contains(normalizedSuffix))
        }
        .controlSize(.small)
    }

    private func notifyBrowserRefresh() {
        NotificationCenter.default.post(name: .browserPreferencesChanged, object: nil)
    }
}
