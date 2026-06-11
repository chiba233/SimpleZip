//
//  BatchRenameSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #11：归档内批量重命名。变换引擎在 Core（BatchRename.plan，纯逻辑已单测），
//  这里只做参数输入 + 实时预览（旧名 → 新名，冲突标红并被执行排除）。
//  执行 = model.performBatchRename → 一次 7zz `rn` 多对 + 原子替换（绝不改一半）。
//

import SwiftUI

struct BatchRenameSheet: View {
    let request: ArchiveBrowserModel.BatchRenameRequest
    let confirm: ([BatchRenameChange]) -> Void
    let cancel: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case replace, prefix, suffix, lowercase, uppercase, sequence
        var id: String { rawValue }
        var title: String { L10n.text("batchRename.mode.\(rawValue)") }
    }

    @State private var mode: Mode = .replace
    @State private var findText = ""
    @State private var replacementText = ""
    @State private var affixText = ""
    @State private var sequenceBase = ""
    @State private var sequenceStart = 1
    @State private var sequenceDigits = 3

    private var operation: BatchRenameOperation {
        switch mode {
        case .replace: return .replaceText(find: findText, replacement: replacementText)
        case .prefix: return .addPrefix(affixText)
        case .suffix: return .addSuffix(affixText)
        case .lowercase: return .lowercased
        case .uppercase: return .uppercased
        case .sequence: return .sequence(baseName: sequenceBase, start: sequenceStart, digits: sequenceDigits)
        }
    }

    private var changes: [BatchRenameChange] {
        BatchRename.plan(paths: request.items.map(\.name), operation: operation, allEntryPaths: request.allEntryPaths)
    }

    private var validCount: Int { changes.filter { !$0.isConflicting }.count }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "pencil.line",
                colors: [.indigo, .purple],
                title: L10n.text("batchRename.title"),
                subtitle: L10n.format("batchRename.subtitle", "\(request.items.count)", request.archiveURL.lastPathComponent)
            )

            HeightCappedScrollView(maxHeight: 480) {
                VStack(alignment: .leading, spacing: 14) {
                    DialogSection {
                        LabeledContent {
                            Picker("", selection: $mode) {
                                ForEach(Mode.allCases) { candidate in
                                    Text(candidate.title).tag(candidate)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            DialogRowLabel(L10n.text("batchRename.mode"), systemImage: "wand.and.stars", tint: .indigo)
                        }
                        modeFields
                    }

                    DialogSection(L10n.text("batchRename.preview")) {
                        if changes.isEmpty {
                            Text(L10n.text("batchRename.preview.empty"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(changes) { change in
                                    HStack(spacing: 6) {
                                        Image(systemName: change.isConflicting ? "exclamationmark.triangle.fill" : "arrow.right")
                                            .font(.caption)
                                            .foregroundStyle(change.isConflicting ? Color.red : Color.secondary)
                                        Text(change.fromLeaf)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("→")
                                            .foregroundStyle(.secondary)
                                        Text(change.toLeaf)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .foregroundStyle(change.isConflicting ? Color.red : Color.primary)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.callout)
                                    .help("\(change.fromPath) → \(change.toPath)")
                                }
                                if changes.contains(where: \.isConflicting) {
                                    Text(L10n.text("batchRename.preview.conflictNote"))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    confirm(changes)
                } label: {
                    Label(L10n.format("batchRename.confirm", "\(validCount)"), systemImage: "pencil.line")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 560)
    }

    @ViewBuilder
    private var modeFields: some View {
        switch mode {
        case .replace:
            parameterField("batchRename.find", systemImage: "magnifyingglass", text: $findText)
            parameterField("batchRename.replaceWith", systemImage: "arrow.right", text: $replacementText)
        case .prefix:
            parameterField("batchRename.prefixText", systemImage: "text.insert", text: $affixText)
        case .suffix:
            VStack(alignment: .leading, spacing: 4) {
                parameterField("batchRename.suffixText", systemImage: "text.append", text: $affixText)
                Text(L10n.text("batchRename.suffixHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .lowercase, .uppercase:
            EmptyView()
        case .sequence:
            parameterField("batchRename.sequenceBase", systemImage: "character.cursor.ibeam", text: $sequenceBase)
            LabeledContent {
                Stepper(value: $sequenceStart, in: 0...9999) {
                    Text("\(sequenceStart)").monospacedDigit()
                }
                .fixedSize()
            } label: {
                DialogRowLabel(L10n.text("batchRename.sequenceStart"), systemImage: "number", tint: .indigo)
            }
            LabeledContent {
                Stepper(value: $sequenceDigits, in: 1...6) {
                    Text("\(sequenceDigits)").monospacedDigit()
                }
                .fixedSize()
            } label: {
                DialogRowLabel(L10n.text("batchRename.sequenceDigits"), systemImage: "number.square", tint: .indigo)
            }
        }
    }

    /// 参数输入行：彩色瓦片标签 + 描边增强的输入框（同色 = 同属重命名参数一族）。
    private func parameterField(_ key: String, systemImage: String, text: Binding<String>) -> some View {
        LabeledContent {
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .dialogFieldEmphasis()
                .frame(maxWidth: 260)
        } label: {
            DialogRowLabel(L10n.text(key), systemImage: systemImage, tint: .indigo)
        }
    }
}
