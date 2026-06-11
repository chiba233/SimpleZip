//
//  ReleaseInspectionView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #15：发布包检查报告。检查在 model（runReleaseInspection：list → 条目侧统计(Core) →
//  完整性测试 → SHA-256），这里只展示：每项检查一行 ✓/⚠/✗，SHA-256 可复制，整份报告可复制纯文本。
//

import AppKit
import SwiftUI

struct ReleaseInspectionView: View {
    let report: ArchiveBrowserModel.ReleaseInspectionReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "checklist",
                colors: [.teal, .green],
                title: L10n.text("inspect.title"),
                subtitle: report.archiveURL.lastPathComponent
            )

            HeightCappedScrollView(maxHeight: 520) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        testRow
                        if let stats = report.stats {
                            row(ok: true,
                                text: L10n.format(
                                    "inspect.entries",
                                    "\(stats.fileCount)", "\(stats.folderCount)",
                                    ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
                                ),
                                neutral: true)
                        } else {
                            row(ok: false, text: L10n.text("inspect.notListable"))
                        }
                    }

                    if let stats = report.stats {
                        DialogSection(L10n.text("inspect.section.hygiene")) {
                            countRow(count: report.securityFindings.reduce(0) { $0 + $1.entryPaths.count }, key: "inspect.suspiciousPaths")
                            countRow(count: stats.junkCount, key: "inspect.junk")
                            countRow(count: stats.emptyDirectoryCount, key: "inspect.emptyDirs")
                            countRow(count: stats.executableCount, key: "inspect.executables", informational: true)
                            countRow(count: stats.symlinkCount, key: "inspect.symlinks", informational: true)
                            row(ok: true, text: L10n.text(report.hasComment ? "inspect.comment.present" : "inspect.comment.none"), neutral: true)
                        }
                    }

                    if let sha256 = report.sha256 {
                        DialogSection(L10n.text("inspect.section.checksum")) {
                            HStack(spacing: 8) {
                                Text(sha256)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(sha256, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.text("button.copyAll"))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button(L10n.text("button.copyAll")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                }
                Spacer()
                Button(L10n.text("button.ok")) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 540)
    }

    @ViewBuilder
    private var testRow: some View {
        switch report.testPassed {
        case .some(true):
            row(ok: true, text: L10n.text("inspect.test.passed"))
        case .some(false):
            VStack(alignment: .leading, spacing: 2) {
                row(ok: false, text: L10n.text("inspect.test.failed"))
                if let message = report.testFailureMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 22)
                }
            }
        case .none:
            row(ok: false, text: L10n.text("inspect.test.skipped"), neutral: true)
        }
    }

    /// 计数行：0 = 绿 ✓「无 …」；>0 = 橙 ⚠（informational = 灰 i，如可执行 / symlink 本身不算问题）。
    @ViewBuilder
    private func countRow(count: Int, key: String, informational: Bool = false) -> some View {
        if count == 0 {
            row(ok: true, text: L10n.format("\(key).none", ""))
        } else {
            Label(L10n.format("\(key).some", "\(count)"), systemImage: informational ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(informational ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private func row(ok: Bool, text: String, neutral: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: neutral ? "info.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(neutral ? Color.secondary : (ok ? Color.green : Color.red))
        }
        .font(.callout)
    }

    /// 纯文本报告（复制给 release note / issue）。
    private var plainTextSummary: String {
        var lines = ["\(L10n.text("inspect.title")): \(report.archiveURL.lastPathComponent)"]
        switch report.testPassed {
        case .some(true): lines.append("✓ \(L10n.text("inspect.test.passed"))")
        case .some(false): lines.append("✗ \(L10n.text("inspect.test.failed")) — \(report.testFailureMessage ?? "")")
        case .none: lines.append("- \(L10n.text("inspect.test.skipped"))")
        }
        if let stats = report.stats {
            lines.append(L10n.format("inspect.entries", "\(stats.fileCount)", "\(stats.folderCount)",
                                     ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)))
            let suspicious = report.securityFindings.reduce(0) { $0 + $1.entryPaths.count }
            lines.append("\(L10n.format("inspect.suspiciousPaths.some", "\(suspicious)"))")
            lines.append("\(L10n.format("inspect.junk.some", "\(stats.junkCount)"))")
            lines.append("\(L10n.format("inspect.emptyDirs.some", "\(stats.emptyDirectoryCount)"))")
            lines.append("\(L10n.format("inspect.executables.some", "\(stats.executableCount)"))")
            lines.append("\(L10n.format("inspect.symlinks.some", "\(stats.symlinkCount)"))")
        } else {
            lines.append(L10n.text("inspect.notListable"))
        }
        if let sha256 = report.sha256 {
            lines.append("SHA-256: \(sha256)")
        }
        return lines.joined(separator: "\n")
    }
}
