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
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "text.bubble.fill",
                colors: [.blue, .cyan],
                title: L10n.text("archive.comment.editorTitle"),
                subtitle: archiveName
            )

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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1))
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
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            HStack {
                Button(L10n.text("button.cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                // 一键清除：只在包里已有注释时出现（清空草稿再保存的快捷径）。
                if !model.archiveHeaderComment.isEmpty {
                    Button(L10n.text("archive.comment.clear"), role: .destructive) {
                        model.saveArchiveComment("")
                        close()
                    }
                }
                Spacer()
                Button(L10n.text("button.save")) {
                    model.saveArchiveComment(draft)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(overLimit || draft == model.archiveHeaderComment)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 480)
        .onAppear { draft = model.archiveHeaderComment }
    }

    private func close() {
        model.showsArchiveCommentEditor = false
    }
}
