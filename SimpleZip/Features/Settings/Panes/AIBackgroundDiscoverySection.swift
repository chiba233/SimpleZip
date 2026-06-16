//
//  AIBackgroundDiscoverySection.swift
//  SimpleZip
//
//  0.4.5 #80 #89:「后台发现与索引」设置区(白皮书工程补充六)。AI 文件夹的后台自动发现 + opt-in 白名单文件
//  预索引的用户控制:活跃度、预索引开关、授权目录白名单(添加 / 推荐安全目录 / 移除)、清空索引、侧栏推荐显示。
//
//  全程 opt-in:活跃度默认 off、预索引默认 false —— 不开则后台完全不扫。只在 AI 主开关开启时显示。
//  UI 全部用设计系统组件(SettingsControlRow / SettingsToggleRow / SettingsActionRow)+ 设置区列表惯例
//  (行内 borderless 图标按钮、添加走 Menu),对齐压缩默认值区。
//

import AppKit
import SwiftUI

struct AIBackgroundDiscoverySection: View {
    @ObservedObject private var store = AIBackgroundIndexStore.shared
    @AppStorage(AppPreferences.Key.aiAllowFolderPreindex) private var folderPreindex = false
    @AppStorage(AppPreferences.Key.aiAllowContentPreread) private var contentPreread = false
    @AppStorage(AppPreferences.Key.aiSidebarShowRecommended) private var showRecommended = true
    @State private var activityLevel = AppPreferences.aiBackgroundActivityLevel
    @State private var maxRecommended = AppPreferences.aiMaxRecommendedWorkspaces
    @State private var maxRecommendedRefreshTask: Task<Void, Never>?
    @State private var showingAddOptions = false

    var body: some View {
        Group {
            // 后台发现 + opt-in 预索引开关。
            Section(L10n.text("settings.ai.background.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.ai.background.activityLevel"),
                    description: L10n.text("settings.ai.background.activityLevel.desc"),
                    systemImage: "bolt.badge.clock", iconTint: .purple
                ) {
                    Picker("", selection: $activityLevel) {
                        ForEach(AIBackgroundActivityLevel.allCases, id: \.self) { level in
                            Text(levelTitle(level)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: activityLevel) { newValue in
                        AppPreferences.aiBackgroundActivityLevel = newValue
                        if newValue == .off { AIBackgroundIndexer.shared.cancel() }
                        else { AIBackgroundIndexer.shared.runIfEnabled() }
                    }
                }

                SettingsToggleRow(
                    title: L10n.text("settings.ai.background.folderPreindex"),
                    description: L10n.text("settings.ai.background.folderPreindex.desc"),
                    systemImage: "folder.badge.gearshape", iconTint: .purple,
                    isOn: $folderPreindex
                )
                .onChange(of: folderPreindex) { on in
                    if on { AIBackgroundIndexer.shared.runIfEnabled() }
                    else if !contentPreread { AIBackgroundIndexer.shared.cancel() }
                }

                // 更高隐私等级:预读文件与压缩包**内容**(独立 opt-in,与上面只元数据的预索引分开)。
                SettingsToggleRow(
                    title: L10n.text("settings.ai.background.contentPreread"),
                    description: L10n.text("settings.ai.background.contentPreread.desc"),
                    systemImage: "doc.text.magnifyingglass", iconTint: .purple,
                    isOn: $contentPreread
                )
                .onChange(of: contentPreread) { on in
                    if on { AIBackgroundIndexer.shared.runIfEnabled() }
                    else if !folderPreindex { AIBackgroundIndexer.shared.cancel() }
                }

                SettingsToggleRow(
                    title: L10n.text("settings.ai.background.showRecommended"),
                    description: L10n.text("settings.ai.background.showRecommended.desc"),
                    systemImage: "sparkles.rectangle.stack", iconTint: .purple,
                    isOn: $showRecommended
                )

                // 系统自动生成的推荐数量上限(用户:别一次冒一堆)。值用独立 Text 右对齐 + Stepper("",…)
                // labelsHidden(对齐 AutomationPane 缓存上限那行;数字进 Stepper label 会跑左边 + 触发重复递增)。
                SettingsControlRow(
                    title: L10n.text("settings.ai.background.maxRecommended"),
                    description: L10n.text("settings.ai.background.maxRecommended.desc"),
                    systemImage: "number.square", iconTint: .purple
                ) {
                    HStack(spacing: 8) {
                        Text("\(maxRecommended)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Stepper("", value: $maxRecommended, in: 1...8)
                            .labelsHidden()
                    }
                    .onChange(of: maxRecommended) { v in
                        AppPreferences.aiMaxRecommendedWorkspaces = v
                        // 不在按钮按下期间同步跑重型 discovery(会让行重建、手势反复触发);
                        // 等 Stepper 手势安静下来后只重算最后一次。
                        maxRecommendedRefreshTask?.cancel()
                        maxRecommendedRefreshTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }
                            AIWorkspaceDiscoveryCoordinator.shared.refresh()
                        }
                    }
                }
            }
            .settingsAnchor("ai.background")

            // 授权目录白名单 + 清空文件预索引。
            Section(L10n.text("settings.ai.background.whitelist")) {
                ForEach(store.scopes) { scope in
                    folderRow(scope)
                }
                if store.scopes.isEmpty {
                    Text(L10n.text("settings.ai.background.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 添加目录:浏览 + 推荐安全目录(白皮书:Downloads / Desktop / Documents,用户确认才加)。
                // 设计规范 §4:Menu 不当按钮用 → **一个普通按钮 + confirmationDialog 选目标**(范本=GPG 导入)。
                Button {
                    showingAddOptions = true
                } label: {
                    Label(L10n.text("settings.ai.background.addFolder"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .confirmationDialog(L10n.text("settings.ai.background.addFolder"),
                                    isPresented: $showingAddOptions, titleVisibility: .visible) {
                    Button(L10n.text("settings.ai.background.browse")) { addFolders() }
                    ForEach(suggestedDirectories(), id: \.path) { url in
                        Button(url.lastPathComponent) {
                            store.addScope(directory: url, origin: .suggestedSafeDirectory)
                            AIBackgroundIndexer.shared.runIfEnabled()
                        }
                    }
                    Button(L10n.text("button.cancel"), role: .cancel) {}
                }

                SettingsActionRow(
                    title: L10n.text("settings.ai.background.clearIndex"),
                    description: L10n.text("settings.ai.background.clearIndex.desc"),
                    systemImage: "trash", iconTint: .red,
                    buttonTitle: L10n.text("settings.ai.background.clearIndex.button"),
                    role: .destructive,
                    isDisabled: store.fileIndex.isEmpty,
                    action: { store.clearFileIndex() })
            }
        }
        .onDisappear {
            maxRecommendedRefreshTask?.cancel()
            maxRecommendedRefreshTask = nil
        }
    }

    // MARK: - 子视图 / 工具

    /// 一条授权目录:路径 + 行内移除(borderless 图标按钮,对齐压缩默认值区行)。
    private func folderRow(_ scope: AIArchivePrefetchScope) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(displayPath(scope.directoryPath))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Button {
                store.removeScope(scope.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("settings.ai.background.remove"))
        }
        .padding(.vertical, 2)
    }

    private func levelTitle(_ level: AIBackgroundActivityLevel) -> String {
        switch level {
        case .off: return L10n.text("settings.ai.background.level.off")
        case .powerSaver: return L10n.text("settings.ai.background.level.powerSaver")
        case .balanced: return L10n.text("settings.ai.background.level.balanced")
        case .aggressive: return L10n.text("settings.ai.background.level.aggressive")
        }
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("settings.ai.background.addFolder")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addScope(directory: url, origin: .userAdded) }
        AIBackgroundIndexer.shared.runIfEnabled()
    }

    /// 推荐安全目录(Downloads / Desktop / Documents)中尚未加入白名单且存在的。
    private func suggestedDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Desktop", "Documents"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !store.contains(directory: $0) }
    }
}
