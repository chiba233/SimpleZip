//
//  ArchiveDiffView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/10.
//
//  #111 Archive Diff —— 比较结果弹窗。引擎在 Core/ArchiveDiff.swift（纯逻辑、已单测），
//  这里只做展示：仅在 A / 仅在 B / 有差异（逐字段 before→after）/ 相同计数。
//  布局沿用 HashResultsView 的弹窗体例（标题 + 复制 + 确定，卡片列表）。
//

import AppKit
import SwiftUI

/// 一次归档比较的展示模型。`leftName` / `rightName` 用文件名标注方向 —— 比较任意两个包
/// 没有天然的「旧 / 新」，所以 UI 全部用「仅在 xxx 中」这种中性措辞，不说「新增 / 删除」。
struct ArchiveDiffReport: Identifiable {
    let id = UUID()
    let leftName: String
    let rightName: String
    let result: ArchiveDiffResult
}

struct ArchiveDiffView: View {
    let report: ArchiveDiffReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("diff.title"))
                        .font(.title2.weight(.semibold))
                    Text("\(report.leftName) ↔ \(report.rightName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(L10n.text("button.copyAll")) {
                    copyReport()
                }

                Button(L10n.text("button.ok")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            summaryLine

            if report.result.hasDifferences {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        diffSection(
                            title: L10n.format("diff.onlyIn", report.leftName),
                            systemImage: "minus.circle",
                            tint: .red,
                            items: report.result.removed
                        )
                        diffSection(
                            title: L10n.format("diff.onlyIn", report.rightName),
                            systemImage: "plus.circle",
                            tint: .green,
                            items: report.result.added
                        )
                        changedSection
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 300)
            } else {
                // 没有差异时不渲染空列表，给一个明确的「完全一致」状态。
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text(L10n.format("diff.identical", report.result.unchanged.count))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
    }

    private var summaryLine: some View {
        HStack(spacing: 14) {
            Label("\(report.result.removed.count)", systemImage: "minus.circle")
                .foregroundStyle(.red)
                .help(L10n.format("diff.onlyIn", report.leftName))
            Label("\(report.result.added.count)", systemImage: "plus.circle")
                .foregroundStyle(.green)
                .help(L10n.format("diff.onlyIn", report.rightName))
            Label("\(report.result.changed.count)", systemImage: "arrow.left.arrow.right.circle")
                .foregroundStyle(.orange)
                .help(L10n.text("diff.changed"))
            Label(L10n.format("diff.unchangedCount", report.result.unchanged.count), systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func diffSection(title: String, systemImage: String, tint: Color, items: [ArchiveItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(title, systemImage: systemImage, tint: tint, count: items.count)
                ForEach(items) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(ArchiveDiff.normalizedPath(item.name))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(item.sizeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }

    @ViewBuilder
    private var changedSection: some View {
        if !report.result.changed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(L10n.text("diff.changed"), systemImage: "arrow.left.arrow.right.circle", tint: .orange, count: report.result.changed.count)
                ForEach(report.result.changed, id: \.path) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: change.after.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(change.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(Self.changeDescription(change))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, tint: Color, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 一条修改的逐字段摘要：「大小 1.2 MB → 1.4 MB · CRC A1B2 → C3D4 · …」。
    /// 也被「复制报告」复用，保证看到的和拷走的一致。
    static func changeDescription(_ change: ArchiveEntryChange) -> String {
        var parts: [String] = []
        // 按固定顺序输出，保证同一结果文案稳定。
        if change.fields.contains(.type) {
            parts.append(L10n.text("diff.field.type"))
        }
        if change.fields.contains(.size) {
            parts.append(L10n.format("diff.field.size", change.before.sizeText, change.after.sizeText))
        }
        if change.fields.contains(.crc) {
            parts.append(L10n.format("diff.field.crc", change.before.crc, change.after.crc))
        }
        if change.fields.contains(.modified) {
            parts.append(L10n.format("diff.field.modified", change.before.modifiedText, change.after.modifiedText))
        }
        if change.fields.contains(.encryption) {
            parts.append(L10n.text(change.after.isEncrypted ? "diff.field.becameEncrypted" : "diff.field.becameUnencrypted"))
        }
        return parts.joined(separator: " · ")
    }

    private func copyReport() {
        var lines: [String] = []
        lines.append("\(L10n.text("diff.title")): \(report.leftName) ↔ \(report.rightName)")
        if !report.result.removed.isEmpty {
            lines.append("")
            lines.append("\(L10n.format("diff.onlyIn", report.leftName)) (\(report.result.removed.count)):")
            lines.append(contentsOf: report.result.removed.map { "  - \(ArchiveDiff.normalizedPath($0.name))" })
        }
        if !report.result.added.isEmpty {
            lines.append("")
            lines.append("\(L10n.format("diff.onlyIn", report.rightName)) (\(report.result.added.count)):")
            lines.append(contentsOf: report.result.added.map { "  + \(ArchiveDiff.normalizedPath($0.name))" })
        }
        if !report.result.changed.isEmpty {
            lines.append("")
            lines.append("\(L10n.text("diff.changed")) (\(report.result.changed.count)):")
            lines.append(contentsOf: report.result.changed.map { "  ~ \($0.path): \(Self.changeDescription($0))" })
        }
        lines.append("")
        lines.append(L10n.format("diff.unchangedCount", report.result.unchanged.count))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
