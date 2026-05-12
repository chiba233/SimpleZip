//
//  ArchiveTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 压缩包模式下的内容列表，支持选择条目后执行局部解压。
struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showMethodColumn = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.archiveItems) { item in
                            row(for: item)
                            Divider()
                        }
                    }
                }
            }

            if model.archiveItems.isEmpty && model.isWorking {
                ProgressView(L10n.text("status.readingArchive"))
                    .padding()
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

    private func row(for item: ArchiveItem) -> some View {
        let isSelected = model.selectedArchiveRows.contains(item.id)

        return HStack(spacing: 0) {
            Label(item.name, systemImage: "doc")
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
        .contextMenu {
            Button(L10n.text("button.extractSelected")) {
                selectForAction(item)
                model.extractSelectedArchiveItems()
            }
            Button(L10n.text("button.extract")) {
                model.extractArchive()
            }
            Button(L10n.text("button.test")) {
                model.testArchive()
            }
            Button(L10n.text("button.hash")) {
                model.calculateHash()
            }
            Divider()
            Button(L10n.text("button.revealInFinder")) {
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

    private func select(_ item: ArchiveItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedArchiveRows.contains(item.id) {
                model.selectedArchiveRows.remove(item.id)
            } else {
                model.selectedArchiveRows.insert(item.id)
            }
        } else {
            model.selectedArchiveRows = [item.id]
        }
    }

    private func selectForAction(_ item: ArchiveItem) {
        if !model.selectedArchiveRows.contains(item.id) {
            model.selectedArchiveRows = [item.id]
        }
    }

    private var visibleColumns: [ArchiveOptionalColumn] {
        var columns: [ArchiveOptionalColumn] = []
        if showSizeColumn { columns.append(.size) }
        if showModifiedColumn { columns.append(.modified) }
        if showMethodColumn { columns.append(.method) }
        return columns
    }
}

private enum ArchiveOptionalColumn: String, Identifiable {
    case size
    case modified
    case method

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size:
            return L10n.text("column.size")
        case .modified:
            return L10n.text("column.modified")
        case .method:
            return L10n.text("column.method")
        }
    }

    var width: CGFloat {
        switch self {
        case .size:
            return 120
        case .modified:
            return 180
        case .method:
            return 120
        }
    }

    func value(for item: ArchiveItem) -> String {
        switch self {
        case .size:
            return item.sizeText
        case .modified:
            return item.modifiedText
        case .method:
            return item.method
        }
    }
}
