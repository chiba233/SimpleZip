//
//  LocationBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  0.3.3 UI 现代化：原 TopBar 的两行自绘工具条（大按钮行 + 导航行）瘦身成单行地址栏。
//  动作 / 导航按钮全部迁入 ContentView 的原生 `.toolbar`（标题栏内，系统自动应用当代材质、
//  自动 overflow）；这里只剩 Finder 式路径栏：可编辑、带补全 popover。
//

import SwiftUI
import AppKit

/// 标题栏下方的单行地址栏：显示 / 编辑当前位置，输入时弹补全。
struct LocationBar: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var pathText = ""
    @State private var locationCompletions: [LocationCompletion] = []
    @State private var isShowingLocationCompletions = false
    @State private var isPathFieldFocused = false
    @State private var selectedLocationCompletionIndex: Int?

    var body: some View {
        locationField
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .onAppear {
                pathText = model.editableLocationText
            }
            .onChange(of: model.locationText) { _ in
                pathText = model.editableLocationText
                hideLocationCompletions()
            }
            .onChange(of: pathText) { _ in
                showLocationCompletionsForTyping()
            }
            .onChange(of: isPathFieldFocused) { focused in
                if !focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if !isPathFieldFocused {
                            hideLocationCompletions()
                        }
                    }
                }
            }
    }

    /// 地址栏前导小图标：归档模式给 zipper、其他给文件夹 —— 一眼区分「在浏览什么」。
    private var locationIconName: String {
        if case .archive = model.mode { return "doc.zipper" }
        return "folder"
    }

    private var locationField: some View {
        HStack(spacing: 0) {
            Image(systemName: locationIconName)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .padding(.leading, 9)

            LocationKeyboardTextField(
                text: $pathText,
                isFocused: $isPathFieldFocused,
                onSubmit: openLocationFromField,
                onMoveSelection: moveLocationCompletionSelection,
                onCompleteSelection: completeSelectedLocationCompletion,
                onCancel: hideLocationCompletions,
                onRequestSuggestions: showLocationCompletions
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)
                .padding(.trailing, 8)
                .padding(.vertical, 5)

            Divider()
                .frame(height: 16)

            Button(action: toggleLocationCompletions) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 26)
            .help(L10n.text("help.locationCompletions"))
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor))
        )
        .popover(isPresented: $isShowingLocationCompletions, arrowEdge: .top) {
            LocationCompletionMenu(
                completions: locationCompletions,
                selectedIndex: selectedLocationCompletionIndex,
                select: selectLocationCompletion
            )
            .padding(6)
            .frame(width: 520, height: LocationCompletionMenu.height(for: locationCompletions.count))
        }
    }

    private func openLocationFromField() {
        if let completion = selectedLocationCompletion {
            selectLocationCompletion(completion)
            return
        }
        model.openLocationText(pathText)
        pathText = model.editableLocationText
        hideLocationCompletions()
    }

    private func selectLocationCompletion(_ completion: LocationCompletion) {
        isPathFieldFocused = false
        hideLocationCompletions()
        pathText = completion.path
        model.openFolder(completion.url)
        pathText = model.editableLocationText
    }

    private func toggleLocationCompletions() {
        if isShowingLocationCompletions {
            hideLocationCompletions()
        } else {
            showLocationCompletions()
        }
    }

    private func showLocationCompletionsForTyping() {
        guard isPathFieldFocused else { return }
        showLocationCompletions()
    }

    private func showLocationCompletions() {
        locationCompletions = model.locationCompletions(for: pathText)
        isShowingLocationCompletions = !locationCompletions.isEmpty
        if let selectedLocationCompletionIndex, selectedLocationCompletionIndex >= locationCompletions.count {
            self.selectedLocationCompletionIndex = nil
        }
    }

    private func hideLocationCompletions() {
        isShowingLocationCompletions = false
        locationCompletions = []
        selectedLocationCompletionIndex = nil
    }

    private func moveLocationCompletionSelection(_ delta: Int) {
        if !isShowingLocationCompletions || locationCompletions.isEmpty {
            showLocationCompletions()
        }
        guard !locationCompletions.isEmpty else { return }
        let currentIndex = selectedLocationCompletionIndex ?? (delta > 0 ? -1 : locationCompletions.count)
        selectedLocationCompletionIndex = (currentIndex + delta + locationCompletions.count) % locationCompletions.count
        isShowingLocationCompletions = true
    }

    private func completeSelectedLocationCompletion() {
        if !isShowingLocationCompletions || locationCompletions.isEmpty {
            showLocationCompletions()
            if !locationCompletions.isEmpty, selectedLocationCompletionIndex == nil {
                selectedLocationCompletionIndex = 0
            }
            return
        }

        if selectedLocationCompletionIndex == nil {
            selectedLocationCompletionIndex = 0
            return
        }

        guard let completion = selectedLocationCompletion ?? locationCompletions.first else { return }
        pathText = completion.path.hasSuffix("/") ? completion.path : completion.path + "/"
        selectedLocationCompletionIndex = nil
        showLocationCompletions()
    }

    private var selectedLocationCompletion: LocationCompletion? {
        guard let selectedLocationCompletionIndex,
              locationCompletions.indices.contains(selectedLocationCompletionIndex)
        else {
            return nil
        }
        return locationCompletions[selectedLocationCompletionIndex]
    }
}

private struct LocationCompletionMenu: View {
    let completions: [LocationCompletion]
    let selectedIndex: Int?
    let select: (LocationCompletion) -> Void
    private static let rowHeight: CGFloat = 48
    private static let maximumVisibleRows = 10
    private static let footerHeight: CGFloat = 31
    private static let verticalPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(completions.enumerated()), id: \.offset) { index, completion in
                            Button {
                                select(completion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(completion.displayName)
                                            .lineLimit(1)
                                        Text(completion.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: Self.rowHeight)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.16) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .overlay(alignment: .bottom) {
                                if index != completions.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .scrollIndicators(completions.count > Self.maximumVisibleRows ? .visible : .hidden)
                .onChange(of: selectedIndex) { index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }

            Divider()

            Text(L10n.format("locationCompletion.count", completions.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor))
        )
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)
    }

    static func height(for count: Int) -> CGFloat {
        listHeight(for: count) + footerHeight + verticalPadding
    }

    private var listHeight: CGFloat {
        Self.listHeight(for: completions.count)
    }

    private static func listHeight(for count: Int) -> CGFloat {
        CGFloat(min(max(count, 1), maximumVisibleRows)) * rowHeight
    }
}

private struct LocationKeyboardTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Void
    let onCompleteSelection: () -> Void
    let onCancel: () -> Void
    let onRequestSuggestions: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> KeyboardTextField {
        let textField = KeyboardTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.cell?.isScrollable = true
        return textField
    }

    func updateNSView(_ textField: KeyboardTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LocationKeyboardTextField

        init(_ parent: LocationKeyboardTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            parent.onRequestSuggestions()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.isFocused = true
            parent.text = textField.stringValue
            parent.onRequestSuggestions()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
            case #selector(NSResponder.insertTab(_:)):
                parent.onCompleteSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

private final class KeyboardTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // **必须先判 `currentEditor() != nil`** —— 即「地址栏正在编辑」。
        // 旧版本无脑接管所有 Cmd+C/V/X/A/Z，currentEditor 为 nil 时 `.copy(nil)` 是 no-op
        // 但仍返回 `true` → 整个 main window 的 Cmd+C/V/X 被吞掉但什么都没做。
        // SwiftUI Commands / NSTableView 都收不到事件 = 「快捷键全失效」的根因。
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let editor = currentEditor()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            editor.selectAll(nil)
            return true
        case "c":
            editor.copy(nil)
            return true
        case "x":
            editor.cut(nil)
            return true
        case "v":
            editor.paste(nil)
            return true
        case "z":
            if flags.contains(.shift) {
                editor.undoManager?.redo()
            } else {
                editor.undoManager?.undo()
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
