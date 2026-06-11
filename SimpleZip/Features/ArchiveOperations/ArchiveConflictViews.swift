//
//  ArchiveConflictViews.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ArchiveExtractionCoordinator.swift 切出的冲突/传输摘要 SwiftUI 视图，纯移动、零行为变更。
//

import AppKit
import SwiftUI

/// 同名冲突对话框。0.4.1 重做：放弃「俩开关改写继续按钮」的隐晦设计，改成**每个处理方式一行明确的动作按钮**
/// （图标 + 标题 + 一句说明），用户一眼看懂、一点到位；「应用到全部」作底部 toggle。
/// 三种场景共用：解压/粘贴的文件冲突、文件夹冲突、以及创建压缩包的输出冲突（kind = .create）。
struct ConflictResolutionView: View {
    enum Kind {
        case fileTransfer       // 解压 / 粘贴：文件 vs 文件
        case folderTransfer     // 解压 / 粘贴：文件夹 vs 文件夹（可合并）
        case archiveOutput      // 创建压缩包：新产物 vs 已有文件（可「两者都保留」）
    }

    let fileName: String
    let kind: Kind
    let allowsRememberedChoice: Bool
    let onChoice: (PasteConflictChoice, Bool) -> Void

    @State private var applyToAll = false

    init(fileName: String, isDirectory: Bool, allowsRememberedChoice: Bool, onChoice: @escaping (PasteConflictChoice, Bool) -> Void) {
        self.fileName = fileName
        self.kind = isDirectory ? .folderTransfer : .fileTransfer
        self.allowsRememberedChoice = allowsRememberedChoice
        self.onChoice = onChoice
    }

    init(fileName: String, kind: Kind, allowsRememberedChoice: Bool, onChoice: @escaping (PasteConflictChoice, Bool) -> Void) {
        self.fileName = fileName
        self.kind = kind
        self.allowsRememberedChoice = allowsRememberedChoice
        self.onChoice = onChoice
    }

    /// 该场景下可选的处理方式（按推荐顺序）。每项 = (选择, 图标, 标题, 说明)。
    private var actions: [(choice: PasteConflictChoice, icon: String, title: String, subtitle: String)] {
        switch kind {
        case .fileTransfer:
            return [
                (.replace, "arrow.2.squarepath", L10n.text("conflict.action.replace"), L10n.text("conflict.action.replace.desc")),
                (.replaceIfDifferent, "doc.badge.gearshape", L10n.text("conflict.action.replaceIfDifferent"), L10n.text("conflict.action.replaceIfDifferent.desc")),
                (.skip, "arrow.uturn.forward", L10n.text("conflict.action.skip"), L10n.text("conflict.action.skip.desc")),
            ]
        case .folderTransfer:
            return [
                (.merge, "arrow.triangle.merge", L10n.text("conflict.action.merge"), L10n.text("conflict.action.merge.desc")),
                (.mergeIfDifferent, "arrow.triangle.merge", L10n.text("conflict.action.mergeIfDifferent"), L10n.text("conflict.action.mergeIfDifferent.desc")),
                (.replace, "folder.badge.minus", L10n.text("conflict.action.replaceFolder"), L10n.text("conflict.action.replaceFolder.desc")),
                (.skip, "arrow.uturn.forward", L10n.text("conflict.action.skip"), L10n.text("conflict.action.skip.desc")),
            ]
        case .archiveOutput:
            return [
                (.replace, "arrow.2.squarepath", L10n.text("conflict.action.replace"), L10n.text("conflict.action.replace.desc")),
                (.replaceIfDifferent, "doc.badge.gearshape", L10n.text("conflict.action.replaceIfDifferent"), L10n.text("conflict.action.replaceIfDifferent.desc")),
                (.keepBoth, "plus.square.on.square", L10n.text("conflict.action.keepBoth"), L10n.text("conflict.action.keepBoth.desc")),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // hero：橙黄警告瓦片 + 文件名 + 说明。
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("conflict.title", fileName))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(L10n.text("conflict.message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // 「应用到本次操作的其余冲突」—— 必须放在动作按钮**之上**：每个动作（含 skip，对文件夹是整体跳过）
            // 一点即生效并关闭对话框，所以这个修饰开关要先于动作可设。仅在可能有多个冲突时显示（allowsRememberedChoice）。
            if allowsRememberedChoice {
                Toggle(L10n.text("conflict.applyToAll"), isOn: $applyToAll)
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button {
                        onChoice(action.choice, applyToAll)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: action.icon)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.title).font(.body.weight(.medium))
                                Text(action.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(index == 0 ? .defaultAction : nil)
                }
            }
            .padding(.horizontal, 20)

            Divider().padding(.top, 14)

            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { onChoice(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 460)
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
