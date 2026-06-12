//
//  DuplicateArchivesView.swift
//  SimpleZip
//
//  队列 #10:疑似重复归档报告。分组在 Core(ArchiveDuplicateScan:指纹一致=结构相同,
//  条目数+总大小一致=疑似,已单测),这里只展示:每组一张卡(置信徽标 + 文件列表 + 元信息),
//  跳过的不可读归档点名,整份可复制纯文本。与 DuplicateFilesView 同一套骨架。
//

import AppKit
import SwiftUI

struct DuplicateArchivesView: View {
    let report: ArchiveBrowserModel.DuplicateArchivesReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.on.doc.fill",
                colors: [.indigo, .blue],
                title: L10n.text("dupArchives.title"),
                subtitle: report.folderName
            )

            HeightCappedScrollView(maxHeight: 460) {
                VStack(alignment: .leading, spacing: 12) {
                    if report.groups.isEmpty {
                        Label(L10n.format("dupArchives.none", "\(report.scannedCount)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Text(L10n.format("dupArchives.summary", "\(report.groups.count)", "\(report.scannedCount)"))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        ForEach(report.groups) { group in
                            DialogSection {
                                HStack {
                                    switch group.confidence {
                                    case .identicalStructure:
                                        Label(L10n.text("dupArchives.identical"), systemImage: "equal.circle.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    case .sameCountAndSize:
                                        Label(L10n.text("dupArchives.similar"), systemImage: "questionmark.circle")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    Text(L10n.format(
                                        "dupArchives.group.meta",
                                        "\(group.entryCount)",
                                        ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file)
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                ForEach(group.urls, id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if !report.skippedNames.isEmpty {
                        Label(L10n.format("dupArchives.skipped", "\(report.skippedNames.count)", report.skippedNames.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                } label: {
                    Label(L10n.text("button.copyAll"), systemImage: "doc.on.doc")
                }
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
        .frame(width: 520)
    }

    private var plainTextSummary: String {
        var lines = ["\(L10n.text("dupArchives.title")): \(report.folderName)"]
        if report.groups.isEmpty {
            lines.append(L10n.format("dupArchives.none", "\(report.scannedCount)"))
        } else {
            lines.append(L10n.format("dupArchives.summary", "\(report.groups.count)", "\(report.scannedCount)"))
            for group in report.groups {
                lines.append("")
                let label = group.confidence == .identicalStructure
                    ? L10n.text("dupArchives.identical")
                    : L10n.text("dupArchives.similar")
                lines.append("— \(label) · " + L10n.format(
                    "dupArchives.group.meta",
                    "\(group.entryCount)",
                    ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file)
                ))
                lines.append(contentsOf: group.urls.map { "  \($0.lastPathComponent)" })
            }
        }
        if !report.skippedNames.isEmpty {
            lines.append(L10n.format("dupArchives.skipped", "\(report.skippedNames.count)", report.skippedNames.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }
}
