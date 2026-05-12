//
//  TopBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 顶部工具栏：提供添加、解压、测试、哈希、打开和定位等常用操作。
struct TopBar: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var pathText = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ToolButton(title: L10n.text("button.add"), systemImage: "plus.square.on.square", action: model.createArchive)
                ToolButton(title: L10n.text("button.extract"), systemImage: "arrow.down.doc", action: model.extractArchive)
                ToolButton(title: L10n.text("button.test"), systemImage: "checkmark.seal", action: model.testArchive)
                ToolButton(title: L10n.text("button.hash"), systemImage: "number.square", action: { model.calculateHash() })
                ToolButton(title: L10n.text("button.open"), systemImage: "folder.badge.gearshape", action: model.chooseFolder)
                ToolButton(title: L10n.text("button.reveal"), systemImage: "arrow.up.forward.app", action: model.revealInFinder)

                Spacer()

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("help.refresh"))
            }

            HStack(spacing: 6) {
                Button(action: model.goUp) {
                    Image(systemName: "chevron.up")
                        .frame(width: 18, height: 18)
                }
                .frame(height: 30)
                .disabled(!model.canGoUp)
                .help(L10n.text("help.goUp"))

                TextField("", text: $pathText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                    .onSubmit {
                        model.openLocationText(pathText)
                        pathText = model.editableLocationText
                    }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            pathText = model.editableLocationText
        }
        .onChange(of: model.locationText) { _ in
            pathText = model.editableLocationText
        }
    }
}

/// 工具栏大按钮，模仿传统压缩软件的图标加文字入口。
struct ToolButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 19))
                Text(title)
                    .font(.caption)
            }
            .frame(width: 66, height: 52)
        }
        .buttonStyle(.bordered)
        .help(title)
    }
}
