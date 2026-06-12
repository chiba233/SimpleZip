//
//  ArchiveCommentEditorView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2：ZIP 归档级注释编辑 sheet。入口 = 注释横幅的铅笔按钮 / 归档空白区右键。
//  写入走 `ArchiveBrowserModel.saveArchiveComment`（Core EOCD 原生改写 + 原子替换）。
//

import SwiftUI

struct ArchiveCommentEditorView: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var draft = ""

    /// ZIP 注释字段上限（UTF-8 字节）。超限禁用保存。
    private var draftByteCount: Int { draft.utf8.count }
    private var overLimit: Bool { draftByteCount > ZipArchiveComment.maxCommentBytes }

    private var archiveName: String {
        if case .archive(let url) = model.mode { return url.lastPathComponent }
        return ""
    }

    var body: some View {
        // design system:统一走 TaskDialogShell 骨架;底栏左侧 = 「清除注释」捷径。
        TaskDialogShell(
            heroSystemImage: "text.bubble.fill",
            heroColors: [.blue, .cyan],
            title: L10n.text("archive.comment.editorTitle"),
            subtitle: archiveName,
            width: 480,
            confirmTitle: L10n.text("button.save"),
            confirmSystemImage: "text.bubble",
            confirmDisabled: overLimit || draft == model.archiveHeaderComment,
            confirm: {
                model.saveArchiveComment(draft)
                close()
            },
            cancel: close,
            content: {
            DialogSection {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        // 输入区描边与 dialogFieldEmphasis 同档(0.22)——0.1 在白卡上几乎隐形。
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.22))
                    )
                HStack {
                    Text(L10n.text("archive.comment.editorHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(draftByteCount) / \(ZipArchiveComment.maxCommentBytes)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(overLimit ? Color.red : Color.secondary)
                }
            }
            },
            footerLeading: {
                // 一键清除：只在包里已有注释时出现（清空草稿再保存的快捷径）。
                if !model.archiveHeaderComment.isEmpty {
                    Button(role: .destructive) {
                        model.saveArchiveComment("")
                        close()
                    } label: {
                        Label(L10n.text("archive.comment.clear"), systemImage: "trash")
                    }
                }
            }
        )
        .onAppear { draft = model.archiveHeaderComment }
    }

    private func close() {
        model.showsArchiveCommentEditor = false
    }
}
