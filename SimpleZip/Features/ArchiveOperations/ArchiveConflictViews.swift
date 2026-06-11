//
//  ArchiveConflictViews.swift
//  SimpleZip
//
//  0.3.0 架构拆分：从 ArchiveExtractionCoordinator.swift 切出的冲突/传输摘要 SwiftUI 视图，纯移动、零行为变更。
//

import AppKit
import SwiftUI

/// 同名冲突对话框。0.4.1 视觉现代化（hero 头 + 卡片化开关 + bar 操作栏），**保留可组合的修饰开关**——
/// 「把整个文件夹替换（tar 风格）」是一个独立的**模式轴**，它和「仅内容不同时覆盖」正交，且影响所有动作
/// （连 skip 在内：tar 模式下 skip = 整体跳过，Finder 模式 = 合并里逐项处理）。所以它必须是开关、不能拆成动作按钮。
/// 三种场景共用：解压/粘贴文件冲突、文件夹冲突、创建压缩包输出冲突（kind = .archiveOutput）。
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

    @State private var replaceWholeFolder = false
    @State private var hashGate = false
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

    /// 「继续」按钮按修饰开关组合出的实际选择。
    private var continueChoice: PasteConflictChoice {
        if kind == .folderTransfer, !replaceWholeFolder {
            return hashGate ? .mergeIfDifferent : .merge
        }
        return hashGate ? .replaceIfDifferent : .replace
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

            // 可组合的修饰开关，卡片化呈现（比裸 checkbox 现代）。每个轴一行带说明。
            VStack(alignment: .leading, spacing: 12) {
                if kind == .folderTransfer {
                    conflictToggle(
                        L10n.text("conflict.toggle.replaceWholeFolder"),
                        subtitle: L10n.text("conflict.toggle.replaceWholeFolder.desc"),
                        isOn: $replaceWholeFolder
                    )
                }
                conflictToggle(
                    L10n.text("conflict.toggle.hashGate"),
                    subtitle: L10n.text("conflict.toggle.hashGate.desc"),
                    isOn: $hashGate
                )
                if allowsRememberedChoice {
                    conflictToggle(
                        L10n.text("conflict.applyToAll"),
                        subtitle: L10n.text("conflict.applyToAll.desc"),
                        isOn: $applyToAll
                    )
                }
            }
            .padding(.horizontal, 20)

            Divider().padding(.top, 16)

            HStack(spacing: 10) {
                Button(L10n.text("button.cancel")) { onChoice(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // 创建场景没有「跳过」（单一输出），但有「两者都保留」。
                if kind == .archiveOutput {
                    Button(L10n.text("conflict.action.keepBoth")) { onChoice(.keepBoth, false) }
                } else {
                    Button(L10n.text("conflict.action.skip")) { onChoice(.skip, applyToAll) }
                }
                Button(continueButtonTitle) { onChoice(continueChoice, applyToAll) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 480)
    }

    /// 「继续」按钮文案随当前组合变化，让用户一眼看出会做什么（替换 / 合并 / 仅不同时…）。
    private var continueButtonTitle: String {
        switch continueChoice {
        case .merge: return L10n.text("conflict.action.merge")
        case .mergeIfDifferent: return L10n.text("conflict.action.mergeIfDifferent")
        case .replaceIfDifferent: return L10n.text("conflict.action.replaceIfDifferent")
        default: return L10n.text("conflict.action.replace")
        }
    }

    @ViewBuilder
    private func conflictToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.on.doc.fill",
                colors: [.blue, .cyan],
                title: L10n.text("transfer.summary.title"),
                subtitle: L10n.format("transfer.summary.message", added.count, overwritten.count, skipped.count)
            )

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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 380, idealHeight: 500)
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
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "number.square.fill",
                colors: [.cyan, .blue],
                title: L10n.text("hashOverwrite.summary.title"),
                subtitle: L10n.format("hashOverwrite.summary.message", sameCount, differentCount)
            )

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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.ok"), action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 380, idealHeight: 500)
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
