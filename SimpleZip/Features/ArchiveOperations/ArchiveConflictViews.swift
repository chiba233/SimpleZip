//
//  ArchiveConflictViews.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ArchiveExtractionCoordinator.swift 切出的冲突/传输摘要 SwiftUI 视图，纯移动、零行为变更。
//

import AppKit
import SwiftUI

/// 同名冲突对话框的内容视图。两个正交的轴各一个开关 + 「应用到全部」，动作按钮三个一行。
struct ConflictResolutionView: View {
    let fileName: String
    let isDirectory: Bool
    let allowsRememberedChoice: Bool
    let onChoice: (PasteConflictChoice, Bool) -> Void

    @State private var replaceWholeFolder = false
    @State private var hashGate = false
    @State private var applyToAll = false

    private var continueChoice: PasteConflictChoice {
        if isDirectory, !replaceWholeFolder {
            return hashGate ? .mergeIfDifferent : .merge
        }
        return hashGate ? .replaceIfDifferent : .replace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.format("confirm.pasteConflict.title", fileName))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(L10n.text(isDirectory ? "confirm.folderConflict.message" : "confirm.pasteConflict.message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if isDirectory {
                    Toggle(L10n.text("conflict.replaceWholeFolder"), isOn: $replaceWholeFolder)
                }
                Toggle(L10n.text("conflict.hashGate"), isOn: $hashGate)
                if allowsRememberedChoice {
                    Toggle(L10n.text("conflict.applyToAll"), isOn: $applyToAll)
                }
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                Button(L10n.text("button.cancel")) { onChoice(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("conflict.skip")) { onChoice(.skip, applyToAll) }
                Button(L10n.text("button.continue")) { onChoice(continueChoice, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}

/// 文件操作结束汇总：沿用原哈希汇总的列对齐表格样式（文件 | 原文件哈希 | 试图覆盖文件哈希），
/// 加上「已新增」段（新增项无哈希，只列文件名）。每段可折叠，避免长列表炸开。
struct TransferSummaryView: View {
    let entries: [TransferLogEntry]
    let hashByName: [String: HashOverwriteResult]
    let close: () -> Void

    private var added: [TransferLogEntry] { entries.filter { $0.action == .added } }
    private var overwritten: [TransferLogEntry] { entries.filter { $0.action == .overwritten } }
    private var skipped: [TransferLogEntry] { entries.filter { $0.action == .skipped } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("transfer.summary.title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L10n.format("transfer.summary.message", added.count, overwritten.count, skipped.count))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !added.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.added"), entries: added, hashByName: [:], showsHashColumns: false)
                    }
                    if !overwritten.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.overwritten"), entries: overwritten, hashByName: hashByName, showsHashColumns: true)
                    }
                    if !skipped.isEmpty {
                        TransferSummaryGroup(title: L10n.text("transfer.section.skipped"), entries: skipped, hashByName: hashByName, showsHashColumns: true)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
            }

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }
}

/// 传输汇总里的一个分组（已新增 / 已覆盖 / 已跳过）。可折叠；带哈希列时显示三列表格，否则只列文件名。
private struct TransferSummaryGroup: View {
    let title: String
    let entries: [TransferLogEntry]
    let hashByName: [String: HashOverwriteResult]
    let showsHashColumns: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.format("hashOverwrite.summary.section.title", title, entries.count))
                        .font(.callout)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if showsHashColumns {
                    HStack(spacing: 12) {
                        Text(L10n.text("hashOverwrite.summary.column.file"))
                            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                        Text(L10n.text("hashOverwrite.summary.column.existingHash"))
                            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                        Text(L10n.text("hashOverwrite.summary.column.incomingHash"))
                            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.08))
                }

                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    TransferSummaryRow(entry: entry, hash: hashByName[entry.name], showsHashColumns: showsHashColumns)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                }
            }
        }
    }
}

private struct TransferSummaryRow: View {
    let entry: TransferLogEntry
    let hash: HashOverwriteResult?
    let showsHashColumns: Bool

    private var displayName: String {
        entry.isDirectory ? L10n.format("transfer.folderName", entry.name) : entry.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.name)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            if showsHashColumns {
                Text(hash?.targetHash ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hash?.targetHash ?? "")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                Text(hash?.sourceHash ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hash?.sourceHash ?? "")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct HashOverwriteSummaryView: View {
    let results: [HashOverwriteResult]
    let sameCount: Int
    let differentCount: Int
    let close: () -> Void

    private var replacedResults: [HashOverwriteResult] {
        results.filter { !$0.isSame }
    }

    private var skippedResults: [HashOverwriteResult] {
        results.filter(\.isSame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("hashOverwrite.summary.title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L10n.format("hashOverwrite.summary.message", sameCount, differentCount))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !replacedResults.isEmpty {
                            HashOverwriteSummaryGroup(
                                title: L10n.text("hashOverwrite.summary.section.replaced"),
                                count: differentCount,
                                results: replacedResults
                            )
                        }
                        if !skippedResults.isEmpty {
                            HashOverwriteSummaryGroup(
                                title: L10n.text("hashOverwrite.summary.section.skipped"),
                                count: sameCount,
                                results: skippedResults
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25))
            }

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 480)
    }
}

private struct HashOverwriteSummaryGroup: View {
    let title: String
    let count: Int
    let results: [HashOverwriteResult]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.format("hashOverwrite.summary.section.title", title, count))
                        .font(.callout)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor))

                HStack(spacing: 12) {
                    Text(L10n.text("hashOverwrite.summary.column.file"))
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("hashOverwrite.summary.column.existingHash"))
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("hashOverwrite.summary.column.incomingHash"))
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08))
            }

            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                HashOverwriteSummaryRow(result: result)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
            }
        }
    }
}

private struct HashOverwriteSummaryRow: View {
    let result: HashOverwriteResult

    var body: some View {
        HStack(spacing: 12) {
            Text(result.targetURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.targetURL.path)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(result.targetHash)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.targetHash)
                .foregroundStyle(.secondary)
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            Text(result.sourceHash)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(result.sourceHash)
                .foregroundStyle(.secondary)
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

enum OverwriteComparableSnapshot: Equatable {
    case regularFile(sha256: String)
    case symbolicLink(destination: String)
    case directory(fingerprint: String)
    case other(kind: String)

    var displayValue: String {
        switch self {
        case .regularFile(let sha256):
            return sha256
        case .symbolicLink(let destination):
            return "symbolic link -> \(destination)"
        case .directory(let fingerprint):
            return "directory fingerprint \(fingerprint)"
        case .other(let kind):
            return kind
        }
    }
}

struct HashProgressPanel {
    let panel: NSPanel
    let label: NSTextField
    let progressIndicator: NSProgressIndicator
}
