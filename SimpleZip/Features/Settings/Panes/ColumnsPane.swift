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
            }

            // 预览紧跟在列开关后面 —— 这样勾选 / 取消列时下方预览立即可见，无需滚过「分组」一大段
            // 才看到效果（用户反馈：列设置和预览分开导致没法一屏边调边看）。
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

            Section(L10n.text("settings.section.grouping")) {
                Text(L10n.text("settings.grouping.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 文件浏览
                HStack(spacing: 12) {
                    SettingsRowIcon(systemImage: "folder", tint: .blue)
                    Text(L10n.text("settings.columns.fileBrowser")).font(.headline)
                }
                SettingsControlRow(
                    title: L10n.text("settings.grouping.scope"),
                    description: L10n.text("settings.grouping.scope.description"),
                    systemImage: "slider.horizontal.3"
                ) {
                    Picker("", selection: $fileGroupingScopeRaw) {
                        ForEach(BrowserGrouping.GroupingScope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                }
                SettingsControlRow(
                    title: L10n.text("settings.grouping.fileDefault"),
                    description: L10n.text("settings.grouping.fileDefault.description"),
                    systemImage: "folder"
                ) {
                    Picker("", selection: $fileGroupByRaw) {
                        ForEach(BrowserGrouping.GroupBy.allCases, id: \.self) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                }

                // 压缩包浏览（无「按文件夹」—— 档案内路径不持久，只全局）
                HStack(spacing: 12) {
                    SettingsRowIcon(systemImage: "archivebox", tint: .orange)
                    Text(L10n.text("settings.columns.archiveBrowser")).font(.headline)
                }
                .padding(.top, 6)
                SettingsControlRow(
                    title: L10n.text("settings.grouping.default"),
                    description: L10n.text("settings.grouping.default.description"),
                    systemImage: "archivebox"
                ) {
                    Picker("", selection: $archiveGroupByRaw) {
                        ForEach(BrowserGrouping.GroupBy.allCases, id: \.self) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize().frame(minWidth: 200, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
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
