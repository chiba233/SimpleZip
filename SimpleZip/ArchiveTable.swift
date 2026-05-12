//
//  ArchiveTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 压缩包模式下的内容列表，目前用于查看归档内文件。
struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        Table(model.archiveItems, selection: $model.selectedArchiveRows) {
            TableColumn(L10n.text("column.name")) { item in
                Label(item.name, systemImage: "doc")
                    .lineLimit(1)
            }
            .width(min: 300, ideal: 520)

            TableColumn(L10n.text("column.size")) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
            }
            .width(120)

            TableColumn(L10n.text("column.modified")) { item in
                Text(item.modifiedText)
                    .foregroundStyle(.secondary)
            }
            .width(180)

            TableColumn(L10n.text("column.method")) { item in
                Text(item.method)
                    .foregroundStyle(.secondary)
            }
            .width(120)
        }
        .overlay {
            if model.archiveItems.isEmpty && model.isWorking {
                ProgressView(L10n.text("status.readingArchive"))
                    .padding()
            }
        }
    }
}
