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
    @AppStorage(AppPreferences.Key.showArchiveKindColumn) private var showArchiveKindColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showArchiveSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showArchiveModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showArchiveMethodColumn = true

    var body: some View {
        Form {
            Section(L10n.text("settings.section.columns")) {
                Text(L10n.text("settings.columns.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.text("settings.columns.fileBrowser"))
                            .font(.headline)
                        Text(L10n.text("settings.columns.archiveBrowser"))
                            .font(.headline)
                    }

                    // 第 1~4 行：左右两侧都有可勾选项。
                    GridRow {
                        Toggle(L10n.text("column.size"), isOn: $showFileSizeColumn)
                        Toggle(L10n.text("column.kind"), isOn: $showArchiveKindColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.kind"), isOn: $showFileTypeColumn)
                        Toggle(L10n.text("column.size"), isOn: $showArchiveSizeColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.application"), isOn: $showFileApplicationColumn)
                        // 之前这里被复制粘贴成了第二次 $showArchiveSizeColumn，
                        // 与上一行重复绑定且把可见的 archive 列虚报成 5 个，已改为 Color.clear。
                        Color.clear
                    }

                    GridRow {
                        Toggle(L10n.text("column.lastOpened"), isOn: $showFileLastOpenedColumn)
                        Toggle(L10n.text("column.modified"), isOn: $showArchiveModifiedColumn)
                    }

                    // 第 5~7 行：文件浏览专属，archive 列已用完保持空白。
                    GridRow {
                        Toggle(L10n.text("column.dateAdded"), isOn: $showFileDateAddedColumn)
                        Toggle(L10n.text("column.method"), isOn: $showArchiveMethodColumn)
                    }

                    GridRow {
                        Toggle(L10n.text("column.modified"), isOn: $showFileModifiedColumn)
                        Color.clear
                    }

                    GridRow {
                        Toggle(L10n.text("column.created"), isOn: $showFileCreatedColumn)
                        Color.clear
                    }
                }
            }

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

        // 保留用户在主界面里手动调过的列顺序，预览也按这个顺序展示。
        return orderedColumns(columns, key: AppPreferences.Key.fileColumnOrder).map { column in
            ColumnPreview(title: column.title, value: filePreviewValue(for: column), preferredWidth: previewWidth(for: column))
        }
    }

    private var archiveColumnPreview: [ColumnPreview] {
        var columns: [ArchiveColumn] = [.name]
        if showArchiveKindColumn { columns.append(.kind) }
        if showArchiveSizeColumn { columns.append(.size) }
        if showArchiveModifiedColumn { columns.append(.modified) }
        if showArchiveMethodColumn { columns.append(.method) }

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
        }
    }

    private func archivePreviewValue(for column: ArchiveColumn) -> String {
        switch column {
        case .name: return "Documents/"
        case .kind: return "Folder"
        case .size: return "42 KB"
        case .modified: return "2026-05-29 10:30"
        case .method: return "Deflate"
        }
    }

    private func previewWidth(for column: FileColumn) -> CGFloat {
        switch column {
        case .name: return 170
        case .size: return 86
        case .type, .application: return 128
        case .lastOpened, .dateAdded, .modified, .created: return 136
        }
    }

    private func previewWidth(for column: ArchiveColumn) -> CGFloat {
        switch column {
        case .name: return 170
        case .kind: return 110
        case .size, .method: return 86
        case .modified: return 140
        }
    }
}
