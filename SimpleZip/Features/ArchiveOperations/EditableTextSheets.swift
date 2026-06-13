//
//  EditableTextSheets.swift
//  SimpleZip
//
//  0.4.4 · Writing Tools(#8):把原来「直接复制到剪贴板」/「NSAlert+NSTextField」的文本入口换成
//  SwiftUI 文本控件 —— TextEditor / TextField 在 macOS 15.1+ 自动吃 Writing Tools(改写 / 校对 / 缩写),
//  AppKit 的 NSTextField 吃不到。两个轻量可复用 sheet:多行可编辑结果 + 单行命名输入。
//

import AppKit
import SwiftUI

/// 多行可编辑文本结果(如发布说明)。DialogHero(自带 padding,别再外套)+ 可编辑 TextEditor + 复制 / 关闭。
struct EditableTextSheet: View {
    let title: String
    let subtitle: String
    let systemImage: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var copied = false

    init(title: String, subtitle: String, systemImage: String, initialText: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(systemImage: systemImage, colors: [.blue, .indigo], title: title, subtitle: subtitle)

            Divider()

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 200, maxHeight: 420)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18))
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            PinnedBottomBar {
                Button(action: copy) {
                    Label(copied ? L10n.text("diagnostics.copied") : L10n.text("button.copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button { dismiss() } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 620)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// 单行命名输入(替换预设保存 / 重命名的 NSAlert+NSTextField)。紧凑:标题 + 说明 + TextField + 保存 / 取消。
/// 故意不用大 DialogHero —— 命名是轻量操作,大 hero 反而臃肿。
struct NameInputSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(title: String, message: String, initialName: String, confirmTitle: String, onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(confirm)

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
