//
//  TopBar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// 顶部工具栏：提供添加、解压、测试、哈希、打开和定位等常用操作。
struct TopBar: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var pathText = ""
    @State private var locationCompletions: [LocationCompletion] = []
    @State private var isShowingLocationCompletions = false
    @State private var isPathFieldFocused = false
    @State private var selectedLocationCompletionIndex: Int?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ToolButton(title: L10n.text("button.add"), systemImage: "plus.square.on.square", action: model.createArchive)
                ToolButton(title: L10n.text("button.extract"), systemImage: "arrow.down.doc", action: model.extractFromCurrentContext)
                ToolButton(title: L10n.text("button.test"), systemImage: "checkmark.seal", action: model.testArchive)
                ToolButton(title: L10n.text("button.hash"), systemImage: "number.square", action: { model.calculateHash() })
                ToolButton(title: L10n.text("button.open"), systemImage: "folder.badge.gearshape", action: model.chooseFolder)
                ToolButton(title: L10n.text("button.reveal"), systemImage: "arrow.up.forward.app", action: model.revealInFinder)

                Spacer()

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .disabled(!model.canGoBack)
                .help(L10n.text("help.goBack"))

                Button(action: model.goForward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .disabled(!model.canGoForward)
                .help(L10n.text("help.goForward"))

                Button(action: model.goUp) {
                    Image(systemName: "chevron.up")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .disabled(!model.canGoUp)
                .help(L10n.text("help.goUp"))
                
                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .help(L10n.text("help.refresh"))

                locationField
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var locationField: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 6)

            Divider()
                .frame(height: 18)

            Button(action: toggleLocationCompletions) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help(L10n.text("help.locationCompletions"))
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
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
                return handleKeyCommand(.submit)
            case #selector(NSResponder.moveUp(_:)):
                return handleKeyCommand(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                return handleKeyCommand(.moveDown)
            case #selector(NSResponder.insertTab(_:)):
                return handleKeyCommand(.complete)
            case #selector(NSResponder.cancelOperation(_:)):
                return handleKeyCommand(.cancel)
            default:
                return false
            }
        }

        func handleKeyCommand(_ command: LocationTextKeyCommand) -> Bool {
            switch command {
            case .submit:
                parent.onSubmit()
            case .moveUp:
                parent.onMoveSelection(-1)
            case .moveDown:
                parent.onMoveSelection(1)
            case .complete:
                parent.onCompleteSelection()
            case .cancel:
                parent.onCancel()
            }
            return true
        }
    }
}

private enum LocationTextKeyCommand {
    case submit
    case moveUp
    case moveDown
    case complete
    case cancel
}

private final class KeyboardTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
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
                    .frame(height: 20)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 72, height: 54)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
    }
}
