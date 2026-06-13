//
//  ArchiveSalvageView.swift
//  SimpleZip
//
//  0.4.4 #8:数据救援结果报告。救援是尽力而为(7zz 兜底解坏包):
//  报告必须如实 —— 救出多少 / 哪些条目坏了 / 固定免责声明(文件可能不完整,归档本身不会被修复)。
//

import AppKit
import SwiftUI

struct ArchiveSalvageReport: Identifiable {
    let id = UUID()
    let archiveName: String
    let outcome: ArchiveSalvage.Outcome
    /// 列得动时的条目总数(算「救出 N / M」;列不动为 nil)。
    let totalEntryCount: Int?
}

struct ArchiveSalvageView: View {
    let report: ArchiveSalvageReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "bandage.fill",
                colors: [.orange, .red],
                title: L10n.text("salvage.title"),
                subtitle: report.archiveName
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        HStack(alignment: .center, spacing: 12) {
                            DialogRowLabel(L10n.text("salvage.rescued"), systemImage: "checkmark.circle.fill", tint: .green)
                            Spacer(minLength: 12)
                            Text(report.totalEntryCount.map { "\(report.outcome.rescuedFileCount) / \($0)" }
                                 ?? "\(report.outcome.rescuedFileCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(alignment: .center, spacing: 12) {
                            DialogRowLabel(L10n.text("salvage.destination"), systemImage: "folder.fill", tint: .blue)
                            Spacer(minLength: 12)
                            Text(report.outcome.destination.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if !report.outcome.failedEntryPaths.isEmpty {
                        DialogSection(L10n.format("salvage.failedSection", "\(report.outcome.failedEntryPaths.count)")) {
                            ForEach(report.outcome.failedEntryPaths.prefix(20), id: \.self) { path in
                                Label {
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                } icon: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.red)
                                }
                                .font(.callout)
                            }
                            if report.outcome.failedEntryPaths.count > 20 {
                                Text(L10n.format("security.report.more", "\(report.outcome.failedEntryPaths.count - 20)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 固定免责声明 —— 永远显示,不许藏。
                    Label(L10n.text("salvage.disclaimer"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([report.outcome.destination])
                } label: {
                    Label(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app")
                }
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
    }
}
