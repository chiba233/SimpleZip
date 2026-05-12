//
//  FileTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import SwiftUI

/// 普通文件夹模式下的文件列表，支持双击打开和右键菜单。
struct FileTable: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        Table(model.fileItems, selection: $model.selection) {
            TableColumn(L10n.text("column.name")) { item in
                Label(item.name, systemImage: item.isDirectory ? "folder.fill" : (ArchiveService.isSupportedArchive(item.url) ? "doc.zipper" : "doc"))
                    .lineLimit(1)
            }
            .width(min: 280, ideal: 420)

            TableColumn(L10n.text("column.size")) { item in
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn(L10n.text("column.type")) { item in
                Text(item.typeDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)

            TableColumn(L10n.text("column.modified")) { item in
                Text(item.modified.map(Self.dateFormatter.string(from:)) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(160)
        }
        .onSubmit {
            if let first = model.selectedFileItems.first {
                model.open(first)
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { _ in
            Button(L10n.text("button.open")) {
                if let first = model.selectedFileItems.first {
                    model.open(first)
                }
            }
            Button(L10n.text("button.addToArchive")) {
                model.createArchive()
            }
            Button(L10n.text("button.extractHere")) {
                model.extractArchive()
            }
            Divider()
            Button(L10n.text("button.revealInFinder")) {
                model.revealInFinder()
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = model.fileItems.first(where: { $0.id == id }) {
                model.open(item)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
