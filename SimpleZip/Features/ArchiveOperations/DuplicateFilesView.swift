//
//  DuplicateFilesView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #24：归档内重复文件报告。检测在 Core（ArchiveDuplicates，大小 + CRC 配组、已单测），
//  这里只展示：每组一张卡（大小 / CRC / 路径列表），头部汇总浪费空间，整份可复制纯文本。
//

import AppKit
import SwiftUI

/// 一次重复检测的展示模型（sheet item）。
struct DuplicateFilesReport: Identifiable {
    let id = UUID()
    let archiveName: String
    let groups: [DuplicateFileGroup]

    var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    var plainTextSummary: String {
        var lines = ["\(L10n.text("duplicates.title")): \(archiveName)"]
        lines.append(L10n.format(
            "duplicates.summary",
            "\(groups.count)",
            ByteCountFormatter.string(fromByteCount: totalWastedBytes, countStyle: .file)
        ))
        for group in groups {
            lines.append("")
            lines.append("— \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file)) · CRC \(group.crc)")
            lines.append(contentsOf: group.paths.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

struct DuplicateFilesView: View {
    let report: DuplicateFilesReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.on.doc.fill",
                colors: [.orange, .yellow],
                title: L10n.text("duplicates.title"),
                subtitle: report.archiveName
            )

            HeightCappedScrollView(maxHeight: 460) {
                VStack(alignment: .leading, spacing: 12) {
                    if report.groups.isEmpty {
                        Label(L10n.text("duplicates.none"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Text(L10n.format(
                            "duplicates.summary",
                            "\(report.groups.count)",
                            ByteCountFormatter.string(fromByteCount: report.totalWastedBytes, countStyle: .file)
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        ForEach(report.groups) { group in
                            DialogSection {
                                HStack {
                                    Label(
                                        ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file),
                                        systemImage: "doc.on.doc"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    Text("CRC \(group.crc)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(L10n.format("duplicates.groupWaste", ByteCountFormatter.string(fromByteCount: group.wastedBytes, countStyle: .file)))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(group.paths, id: \.self) { path in
                                        Text(path)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                            .help(path)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
                } label: {
                    Label(L10n.text("button.copyAll"), systemImage: "doc.on.doc")
                }
                .disabled(report.groups.isEmpty)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 540)
    }
}
