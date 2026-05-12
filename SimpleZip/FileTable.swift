//
//  FileTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import AppKit
import SwiftUI

/// 普通文件夹模式下的文件列表，使用自绘表格以兼容 macOS 13 的动态列显示。
struct FileTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showModifiedColumn = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.fileItems) { item in
                        row(for: item)
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerText(L10n.text("column.name"))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(visibleColumns) { column in
                headerText(column.title)
                    .frame(width: column.width, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(for item: FileItem) -> some View {
        let isSelected = model.selection.contains(item.id)

        return HStack(spacing: 0) {
            Label(item.name, systemImage: item.isDirectory ? "folder.fill" : (ArchiveService.isSupportedArchive(item.url) ? "doc.zipper" : "doc"))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(visibleColumns) { column in
                Text(column.value(for: item))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: column.width, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture {
            select(item)
        }
        .onTapGesture(count: 2) {
            model.open(item)
        }
        .contextMenu {
            Button(L10n.text("button.open")) {
                selectForAction(item)
                model.open(item)
            }
            Button(L10n.text("button.addToArchive")) {
                selectForAction(item)
                model.createArchive()
            }
            Button(L10n.text("button.extractHere")) {
                selectForAction(item)
                model.extractArchive()
            }
            Button(L10n.text("button.test")) {
                selectForAction(item)
                model.testArchive()
            }
            Button(L10n.text("button.hash")) {
                selectForAction(item)
                model.calculateHash()
            }
            Divider()
            Button(L10n.text("button.revealInFinder")) {
                selectForAction(item)
                model.revealInFinder()
            }
        }
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func select(_ item: FileItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
        } else {
            model.selection = [item.id]
        }
    }

    private func selectForAction(_ item: FileItem) {
        if !model.selection.contains(item.id) {
            model.selection = [item.id]
        }
    }

    private var visibleColumns: [FileOptionalColumn] {
        var columns: [FileOptionalColumn] = []
        if showSizeColumn { columns.append(.size) }
        if showTypeColumn { columns.append(.type) }
        if showModifiedColumn { columns.append(.modified) }
        return columns
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum FileOptionalColumn: String, Identifiable {
    case size
    case type
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size:
            return L10n.text("column.size")
        case .type:
            return L10n.text("column.type")
        case .modified:
            return L10n.text("column.modified")
        }
    }

    var width: CGFloat {
        switch self {
        case .size:
            return 110
        case .type:
            return 180
        case .modified:
            return 160
        }
    }

    func value(for item: FileItem) -> String {
        switch self {
        case .size:
            return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        case .type:
            return item.typeDescription
        case .modified:
            return item.modified.map(FileTable.dateFormatter.string(from:)) ?? ""
        }
    }
}
