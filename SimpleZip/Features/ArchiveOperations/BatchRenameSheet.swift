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
                        Picker(L10n.text("batchRename.mode"), selection: $mode) {
                            ForEach(Mode.allCases) { candidate in
                                Text(candidate.title).tag(candidate)
                            }
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
                Button(L10n.text("button.cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.format("batchRename.confirm", "\(validCount)")) {
                    confirm(changes)
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
            LabeledContent(L10n.text("batchRename.find")) {
                TextField("", text: $findText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            LabeledContent(L10n.text("batchRename.replaceWith")) {
                TextField("", text: $replacementText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
        case .prefix:
            LabeledContent(L10n.text("batchRename.prefixText")) {
                TextField("", text: $affixText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
        case .suffix:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(L10n.text("batchRename.suffixText")) {
                    TextField("", text: $affixText).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
                Text(L10n.text("batchRename.suffixHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .lowercase, .uppercase:
            EmptyView()
        case .sequence:
            LabeledContent(L10n.text("batchRename.sequenceBase")) {
                TextField("", text: $sequenceBase).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            LabeledContent(L10n.text("batchRename.sequenceStart")) {
                Stepper(value: $sequenceStart, in: 0...9999) {
                    Text("\(sequenceStart)").monospacedDigit()
                }
                .fixedSize()
            }
            LabeledContent(L10n.text("batchRename.sequenceDigits")) {
                Stepper(value: $sequenceDigits, in: 1...6) {
                    Text("\(sequenceDigits)").monospacedDigit()
                }
                .fixedSize()
            }
        }
    }
}
