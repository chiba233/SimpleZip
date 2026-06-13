//
//  ColumnsPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 列开关 + 实时预览。
///
/// 左右两列分别对应「普通文件浏览」和「压缩包内浏览」的可选列。
/// 文件浏览有 7 个可选列、压缩包浏览有 4 个，所以右侧只有前 4 行有 toggle，
/// 剩下用 Color.clear 占位保持网格对齐。
struct ColumnsPane: View {
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showFileSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showFileTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileApplicationColumn) private var showFileApplicationColumn = true
    @AppStorage(AppPreferences.Key.showFileLastOpenedColumn) private var showFileLastOpenedColumn = true
    @AppStorage(AppPreferences.Key.showFileDateAddedColumn) private var showFileDateAddedColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showFileModifiedColumn = true
    @AppStorage(AppPreferences.Key.showFileCreatedColumn) private var showFileCreatedColumn = true
    @AppStorage(AppPreferences.Key.showFileSymlinkColumn) private var showFileSymlinkColumn = false
    @AppStorage(AppPreferences.Key.showFilePermissionsColumn) private var showFilePermissionsColumn = false
    @AppStorage(AppPreferences.Key.showFileOwnerColumn) private var showFileOwnerColumn = false
    @AppStorage(AppPreferences.Key.showArchiveKindColumn) private var showArchiveKindColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showArchiveSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showArchiveModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showArchiveMethodColumn = true
    @AppStorage(AppPreferences.Key.showArchivePathColumn) private var showArchivePathColumn = false
    @AppStorage(AppPreferences.Key.showArchiveEncryptedColumn) private var showArchiveEncryptedColumn = false
    @AppStorage(AppPreferences.Key.showArchivePackedSizeColumn) private var showArchivePackedSizeColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCrcColumn) private var showArchiveCrcColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCreatedColumn) private var showArchiveCreatedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveAttributesColumn) private var showArchiveAttributesColumn = false
    @AppStorage(AppPreferences.Key.showArchiveAccessedColumn) private var showArchiveAccessedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveHostOSColumn) private var showArchiveHostOSColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCharacteristicsColumn) private var showArchiveCharacteristicsColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCommentColumn) private var showArchiveCommentColumn = false
    @AppStorage(AppPreferences.Key.showArchiveSymlinkColumn) private var showArchiveSymlinkColumn = false
    // 分组（视图分组）—— 这里是「全局默认值」，不是总开关；按文件夹范围下可右键单独覆盖。
    @AppStorage(AppPreferences.Key.fileGroupingScope) private var fileGroupingScopeRaw = BrowserGrouping.GroupingScope.global.rawValue
    @AppStorage(AppPreferences.Key.fileGroupBy) private var fileGroupByRaw = BrowserGrouping.GroupBy.none.rawValue
    @AppStorage(AppPreferences.Key.archiveGroupBy) private var archiveGroupByRaw = BrowserGrouping.GroupBy.none.rawValue
    // 列表显示密度（文件 / 压缩包浏览共用）。
    @AppStorage(AppPreferences.Key.rowDensity) private var rowDensityRaw = FileBrowserOutline.RowDensity.standard.rawValue

    // #20 从「浏览器」搬来的呈现类选项(key 一个不改):「列出什么归浏览器、怎么呈现归视图」。
    // showHiddenFiles 本体留在浏览器,这里只读同一 key 做跨 pane 置灰。
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.hiddenGroupCollapseMode) private var hiddenGroupCollapseModeRaw = FileBrowserOutline.CollapseMode.alwaysCollapsed.rawValue
    @AppStorage(AppPreferences.Key.hiddenWithGrouping) private var hiddenWithGroupingRaw = BrowserGrouping.HiddenWithGrouping.separateGroup.rawValue
    @AppStorage(AppPreferences.Key.folderInlineExpansion) private var folderInlineExpansion = true
    @AppStorage(AppPreferences.Key.rememberFolderExpansion) private var rememberFolderExpansion = true
    @AppStorage(AppPreferences.Key.rememberVolumeSetExpansion) private var rememberVolumeSetExpansion = true
    @AppStorage(AppPreferences.Key.hiddenSuffixesEnabled) private var hiddenSuffixesEnabled = true

    @State private var showsHiddenSuffixDrawer = false
    // 推荐后缀 / 自定义后缀的真源是 AppPreferences 的辅助方法（带去重 / 归一），
    // 这里只保留 @State 镜像，再用 onChange 写回真源 + 广播通知(随 #20 从浏览器 pane 整体搬来)。
    @State private var hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
    @State private var hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
    @State private var hiddenSuffixInput = ""

    var body: some View {
        Form {
            Section(L10n.text("settings.section.display")) {
                SettingsControlRow(
                    title: L10n.text("settings.rowDensity"),
                    description: L10n.text("settings.rowDensity.description"),
                    systemImage: "text.justify.left", iconTint: .blue
                ) {
                    Picker("", selection: $rowDensityRaw) {
                        ForEach(FileBrowserOutline.RowDensity.allCases, id: \.self) { density in
                            Text(density.title).tag(density.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                }
                .settingsAnchor("view.rowDensity")
                // #20 搬来:隐藏文件组折叠策略 —— 呈现行为,归视图。只在显示隐藏文件时有意义,
                // 关掉时置灰但可见(跨 pane 读同一 showHiddenFiles key)。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenGroupCollapse"),
                    description: L10n.text("settings.hiddenGroupCollapse.description"),
                    systemImage: "arrow.down.right.and.arrow.up.left", iconTint: .purple
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
                .settingsAnchor("view.hiddenGroupCollapse")
            }

            // 0.4.3 用户拍板重写:分组也折叠化,逻辑说人话 ——
            // 「分组方式」一个 picker + 「按文件夹单独记忆」一个开关,替代原「分组范围 + 全局默认分组方式」
            // 两个互相指涉的下拉(用户原话:个人都看不懂)。存储不变(scope/groupBy 同 key)。
            Section(L10n.text("settings.section.grouping")) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsControlRow(
                            title: L10n.text("settings.grouping.groupBy"),
                            description: L10n.text("settings.grouping.groupBy.file.description"),
                            systemImage: "square.grid.3x1.below.line.grid.1x2"
                        ) {
                            Picker("", selection: $fileGroupByRaw) {
                                ForEach(BrowserGrouping.GroupBy.allCases, id: \.self) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                        }
                        SettingsToggleRow(
                            title: L10n.text("settings.grouping.perFolder"),
                            description: L10n.text("settings.grouping.perFolder.description"),
                            systemImage: "folder.badge.gearshape",
                            isOn: Binding(
                                get: { fileGroupingScopeRaw == BrowserGrouping.GroupingScope.perFolder.rawValue },
                                set: { fileGroupingScopeRaw = ($0 ? BrowserGrouping.GroupingScope.perFolder : .global).rawValue }
                            )
                        )
                    }
                    .padding(.leading, 34)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowIcon(systemImage: "folder", tint: .blue)
                        Text(L10n.text("settings.columns.fileBrowser")).font(.headline)
                    }
                }

                // 压缩包浏览(无「按文件夹」—— 档案内路径不持久,只有一个全局分组方式)。
                DisclosureGroup {
                    SettingsControlRow(
                        title: L10n.text("settings.grouping.groupBy"),
                        description: L10n.text("settings.grouping.groupBy.archive.description"),
                        systemImage: "square.grid.3x1.below.line.grid.1x2"
                    ) {
                        Picker("", selection: $archiveGroupByRaw) {
                            ForEach(BrowserGrouping.GroupBy.allCases, id: \.self) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                    }
                    .padding(.leading, 34)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowIcon(systemImage: "archivebox", tint: .orange)
                        Text(L10n.text("settings.columns.archiveBrowser")).font(.headline)
                    }
                }

                // #20 搬来:分组时隐藏文件单列 / 融入 —— 它本就是 groupBy 的修饰选项,并进分组区。
                SettingsControlRow(
                    title: L10n.text("settings.hiddenWithGrouping"),
                    description: L10n.text("settings.hiddenWithGrouping.description"),
                    systemImage: "square.grid.2x2", iconTint: .teal
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
                .settingsAnchor("view.hiddenWithGrouping")
            }

            // #20 搬来:展开与记忆整组(原位展开 + 两个展开记忆)—— 呈现行为,归视图。
            Section(L10n.text("settings.browser.group.expansion")) {
                SettingsToggleRow(
                    title: L10n.text("settings.folderInlineExpansion"),
                    description: L10n.text("settings.folderInlineExpansion.description"),
                    systemImage: "chevron.down.square", iconTint: .indigo,
                    isOn: $folderInlineExpansion
                )
                .settingsAnchor("view.folderInlineExpansion")
                // 展开记忆：刷新（FSEvents / 手动 / 排序分组）后恢复展开状态。文件夹记忆依赖原位展开,关掉时变灰。
                SettingsToggleRow(
                    title: L10n.text("settings.rememberFolderExpansion"),
                    description: L10n.text("settings.rememberFolderExpansion.description"),
                    systemImage: "arrow.clockwise.square", iconTint: .green,
                    isOn: $rememberFolderExpansion
                )
                .disabled(!folderInlineExpansion)
                .settingsAnchor("view.rememberFolderExpansion")
                SettingsToggleRow(
                    title: L10n.text("settings.rememberVolumeSetExpansion"),
                    description: L10n.text("settings.rememberVolumeSetExpansion.description"),
                    systemImage: "square.stack.3d.down.right", iconTint: .brown,
                    isOn: $rememberVolumeSetExpansion
                )
                .settingsAnchor("view.rememberVolumeSetExpansion")
            }

            // #20 搬来:隐藏后缀名(只改显示名,不改列出什么)—— 归视图,独立「显示名」区。
            Section(L10n.text("settings.view.group.displayName")) {
                hiddenSuffixHeader
                if showsHiddenSuffixDrawer {
                    hiddenSuffixDrawer
                }
            }

            Section(L10n.text("settings.section.columns")) {
                Text(L10n.text("settings.columns.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 0.4.3 用户拍板:两块列开关改**折叠组**(默认收起)—— 页面不再被几十个 toggle 撑高,
                // 标签 = 彩色瓦片 + 标题,与「分组」区的小标题同一套一级图标制度。
                DisclosureGroup {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            Toggle(L10n.text("column.size"), isOn: $showFileSizeColumn)
                            Toggle(L10n.text("column.kind"), isOn: $showFileTypeColumn)
                        }
                        GridRow {
                            Toggle(L10n.text("column.application"), isOn: $showFileApplicationColumn)
                            Toggle(L10n.text("column.lastOpened"), isOn: $showFileLastOpenedColumn)
                        }
                        GridRow {
                            Toggle(L10n.text("column.dateAdded"), isOn: $showFileDateAddedColumn)
                            Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                        }
                        GridRow {
                            Toggle(L10n.text("column.created"), isOn: $showFileCreatedColumn)
                            Toggle(L10n.text("column.symlink"), isOn: $showFileSymlinkColumn)
                        }
                        GridRow {
                            Toggle(L10n.text("column.permissions"), isOn: $showFilePermissionsColumn)
                            Toggle(L10n.text("column.owner"), isOn: $showFileOwnerColumn)
                        }
                    }
                    .padding(.leading, 34)
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowIcon(systemImage: "folder", tint: .blue)
                        Text(L10n.text("settings.columns.fileBrowser")).font(.headline)
                    }
                }
                .settingsAnchor("view.fileColumns")

                DisclosureGroup {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Toggle(L10n.text("column.kind"), isOn: $showArchiveKindColumn)
                                Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.path"), isOn: $showArchivePathColumn)
                                Toggle(L10n.text("column.packedSize"), isOn: $showArchivePackedSizeColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.modified"), isOn: $showArchiveModifiedColumn)
                                Toggle(L10n.text("column.created"), isOn: $showArchiveCreatedColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.method"), isOn: $showArchiveMethodColumn)
                                Toggle(L10n.text("column.crc"), isOn: $showArchiveCrcColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.attributes"), isOn: $showArchiveAttributesColumn)
                                Toggle(L10n.text("column.encrypted"), isOn: $showArchiveEncryptedColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.accessed"), isOn: $showArchiveAccessedColumn)
                                Toggle(L10n.text("column.hostOS"), isOn: $showArchiveHostOSColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.characteristics"), isOn: $showArchiveCharacteristicsColumn)
                                Toggle(L10n.text("column.symlink"), isOn: $showArchiveSymlinkColumn)
                            }
                            GridRow {
                                Toggle(L10n.text("column.comment"), isOn: $showArchiveCommentColumn)
                            }
                    }
                    .padding(.leading, 34)
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowIcon(systemImage: "archivebox", tint: .orange)
                        Text(L10n.text("settings.columns.archiveBrowser")).font(.headline)
                    }
                }
                .settingsAnchor("view.archiveColumns")
            }

            // 预览紧跟在列开关后面（用户反馈：列设置和预览分开导致没法一屏边调边看）;
            // 列+预览整块按用户拍板挪到视图页最后,常改的呈现选项在上。
            Section(L10n.text("settings.columns.preview")) {
                VStack(alignment: .leading, spacing: 14) {
                    ColumnsPreviewTable(
                        title: L10n.text("settings.columns.fileBrowser"),
                        columns: fileColumnPreview
                    )
                    ColumnsPreviewTable(
                        title: L10n.text("settings.columns.archiveBrowser"),
                        columns: archiveColumnPreview
                    )
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .settingsScrollAnchors()
        .onAppear {
            // 进入面板时把真源拉一次，避免之前在别处改过造成不一致。
            hiddenRecommendedSuffixes = AppPreferences.hiddenRecommendedSuffixes
            hiddenCustomSuffixes = AppPreferences.hiddenCustomSuffixes
        }
        // #20:搬来的行保留浏览器刷新广播 —— 这些选项一改主窗口要立刻重列目录
        // (ColumnsPane 原生行靠 @AppStorage 直接驱动表格,无需广播;搬来的行依赖 ContentView 的监听)。
        .onChange(of: hiddenGroupCollapseModeRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: hiddenWithGroupingRaw) { _ in notifyBrowserRefresh() }
        .onChange(of: folderInlineExpansion) { _ in notifyBrowserRefresh() }
        .onChange(of: rememberFolderExpansion) { _ in notifyBrowserRefresh() }
        .onChange(of: rememberVolumeSetExpansion) { _ in notifyBrowserRefresh() }
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
        // 视图 pane 的 4 个折叠组(文件浏览列 / 压缩包列 …)整行可点展开。
        .disclosureGroupStyle(.wholeRow)
    }

    // MARK: - 隐藏后缀名(#20 自浏览器 pane 整体搬来)

    /// 隐藏后缀的「总开关 + 展开抽屉」一行。
    ///
    /// 之所以没用 `SettingsToggleRow`：这一行不仅有 toggle，还要带一个抽屉展开按钮，
    /// 描述与开关之间还要塞一个 chevron，跟通用模板有差异。
    private var hiddenSuffixHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(systemImage: "textformat", tint: .pink)

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

    // MARK: - 预览数据

    private var fileColumnPreview: [ColumnPreview] {
        var columns: [FileColumn] = [.name]
        if showFileSizeColumn { columns.append(.size) }
        if showFileTypeColumn { columns.append(.type) }
        if showFileApplicationColumn { columns.append(.application) }
        if showFileLastOpenedColumn { columns.append(.lastOpened) }
        if showFileDateAddedColumn { columns.append(.dateAdded) }
        if showFileModifiedColumn { columns.append(.modified) }
        if showFileCreatedColumn { columns.append(.created) }
        if showFileSymlinkColumn { columns.append(.symlink) }
        if showFilePermissionsColumn { columns.append(.permissions) }
        if showFileOwnerColumn { columns.append(.owner) }

        // 保留用户在主界面里手动调过的列顺序，预览也按这个顺序展示。
        return orderedColumns(columns, key: AppPreferences.Key.fileColumnOrder).map { column in
            ColumnPreview(title: column.title, value: filePreviewValue(for: column), preferredWidth: previewWidth(for: column))
        }
    }

    private var archiveColumnPreview: [ColumnPreview] {
        var columns: [ArchiveColumn] = [.name]
        if showArchivePathColumn { columns.append(.path) }
        if showArchiveKindColumn { columns.append(.kind) }
        if showArchiveSizeColumn { columns.append(.size) }
        if showArchivePackedSizeColumn { columns.append(.packedSize) }
        if showArchiveModifiedColumn { columns.append(.modified) }
        if showArchiveCreatedColumn { columns.append(.created) }
        if showArchiveMethodColumn { columns.append(.method) }
        if showArchiveCrcColumn { columns.append(.crc) }
        if showArchiveAttributesColumn { columns.append(.attributes) }
        if showArchiveAccessedColumn { columns.append(.accessed) }
        if showArchiveHostOSColumn { columns.append(.hostOS) }
        if showArchiveCharacteristicsColumn { columns.append(.characteristics) }
        if showArchiveSymlinkColumn { columns.append(.symlink) }
        if showArchiveCommentColumn { columns.append(.comment) }
        if showArchiveEncryptedColumn { columns.append(.encrypted) }

        return orderedColumns(columns, key: AppPreferences.Key.archiveColumnOrder).map { column in
            ColumnPreview(title: column.title, value: archivePreviewValue(for: column), preferredWidth: previewWidth(for: column))
        }
    }

    private func filePreviewValue(for column: FileColumn) -> String {
        switch column {
        case .name: return "Project.zip"
        case .size: return "12.4 MB"
        case .type: return "ZIP Archive"
        case .application: return "SimpleZip"
        case .lastOpened: return "May 29, 2026"
        case .dateAdded: return "May 28, 2026"
        case .modified: return "May 27, 2026"
        case .created: return "May 20, 2026"
        case .symlink: return "../target.txt"
        case .permissions: return "-rw-r--r--"
        case .owner: return "yumeka"
        }
    }

    private func archivePreviewValue(for column: ArchiveColumn) -> String {
        switch column {
        case .name: return "report.pdf"
        case .path: return "Documents/report.pdf"
        case .kind: return "PDF"
        case .size: return "1.2 MB"
        case .packedSize: return "880 KB"
        case .modified: return "2026-05-29 10:30"
        case .created: return "2026-05-20 09:15"
        case .method: return "LZMA2"
        case .crc: return "12AB34CD"
        case .attributes: return "A"
        case .encrypted: return "🔒"
        case .accessed: return "2026-05-30 14:02"
        case .hostOS: return "Unix"
        case .characteristics: return "Archive"
        case .symlink: return "../target.txt"
        case .comment: return "Final build"
        }
    }

    private func previewWidth(for column: FileColumn) -> CGFloat {
        switch column {
        case .name: return 170
        case .size: return 86
        case .type, .application: return 128
        case .lastOpened, .dateAdded, .modified, .created: return 136
        case .symlink: return 160
        case .permissions: return 110
        case .owner: return 90
        }
    }

    private func previewWidth(for column: ArchiveColumn) -> CGFloat {
        switch column {
        case .name: return 170
        case .path: return 160
        case .kind: return 110
        case .size, .packedSize, .method: return 86
        case .modified, .created: return 140
        case .crc: return 96
        case .attributes: return 90
        case .encrypted: return 56
        case .accessed: return 140
        case .hostOS: return 80
        case .characteristics: return 110
        case .symlink: return 160
        case .comment: return 150
        }
    }
}
