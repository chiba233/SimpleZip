//
//  ArchiveSecurityReportView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #7：归档路径安全报告 sheet。打开归档后台分析（Core ArchiveSecurityReport）出
//  可疑条目时，列表上方出橙色横幅 →「查看报告」弹本视图。**只告知**：解压 / 打开时的
//  既有安全确认（路径逃逸 / 符号链接 / 可执行内容）不受此报告影响、照常拦截。
//

import SwiftUI

struct ArchiveSecurityReportView: View {
    @ObservedObject var model: ArchiveBrowserModel

    /// 每类最多列这么多条目，其余折成「+N 项」—— 报告要能一眼扫完，不是堆日志。
    private static let maxPathsPerFinding = 12

    private var archiveName: String {
        if case .archive(let url) = model.mode { return url.lastPathComponent }
        return ""
    }

    /// 干净包也能看报告（菜单项随归档打开常亮）：有发现 = 橙色警示态,没发现 = 绿色全清态。
    private var hasFindings: Bool {
        !model.archiveSecurityFindings.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: hasFindings ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                colors: hasFindings ? [.orange, .red] : [.green, .mint],
                title: L10n.text("security.report.title"),
                subtitle: archiveName
            )

            HeightCappedScrollView(maxHeight: 620) {
                VStack(alignment: .leading, spacing: 12) {
                    if hasFindings {
                        Text(L10n.text("security.report.note"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(model.archiveSecurityFindings) { finding in
                            findingSection(finding)
                        }
                    } else {
                        allClearSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                // F2:统一导出。UI 每类截 12 条,导出给全量路径。
                ReportExportControl(report: ArchiveSecurityExportReport(
                    archiveName: archiveName,
                    archivePath: { if case .archive(let url) = model.mode { return url.path } else { return nil } }(),
                    findings: model.archiveSecurityFindings
                ))
                Spacer()
                Button {
                    model.showsArchiveSecurityReport = false
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
    }

    private var allClearSection: some View {
        DialogSection {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("security.report.clean"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text(L10n.text("security.report.clean.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// F2:导出包装 —— 安全发现挂在 model 上没有独立报告类型,这里拼一个值类型给统一导出用。
    struct ArchiveSecurityExportReport: ReportExportable {
        let archiveName: String
        let archivePath: String?
        let findings: [ArchiveSecurityFinding]

        var reportTitle: String { "\(L10n.text("security.report.title")) — \(archiveName)" }
        var reportTargetPath: String? { archivePath }

        var reportSummaryLine: String {
            guard !findings.isEmpty else {
                return "\(archiveName) — \(L10n.text("security.report.clean"))"
            }
            let total = findings.reduce(0) { $0 + $1.entryPaths.count }
            let kinds = findings.map { L10n.text("security.kind.\($0.kind.rawValue)") }.joined(separator: ", ")
            return "\(archiveName) — \(L10n.format("security.report.summary", "\(total)", kinds))"
        }

        func reportMarkdown(metadata: ReportMetadata?) -> String {
            var lines: [String] = []
            lines.append("# \(L10n.text("security.report.title"))")
            lines.append("")
            lines.append("**\(archiveName)**")
            lines.append("")
            if findings.isEmpty {
                lines.append("✓ \(L10n.text("security.report.clean"))")
            } else {
                for finding in findings {
                    lines.append("## \(L10n.text("security.kind.\(finding.kind.rawValue)")) (\(finding.entryPaths.count))")
                    lines.append("")
                    lines.append(L10n.text("security.kind.\(finding.kind.rawValue).desc"))
                    lines.append("")
                    lines.append(contentsOf: finding.entryPaths.map { "- `\($0)`" })
                    lines.append("")
                }
            }
            lines.append("")
            var markdown = lines.joined(separator: "\n")
            if let metadata {
                markdown += ReportExport.markdownFooter(metadata) + "\n"
            }
            return markdown
        }

        private struct JSONReport: Encodable {
            struct Finding: Encodable {
                let kind: String
                let count: Int
                let paths: [String]
            }
            let archive: String
            let findings: [Finding]
            let metadata: ReportMetadata?
        }

        func reportJSON(metadata: ReportMetadata?) throws -> String {
            let snapshot = JSONReport(
                archive: archiveName,
                findings: findings.map {
                    JSONReport.Finding(kind: $0.kind.rawValue, count: $0.entryPaths.count, paths: $0.entryPaths)
                },
                metadata: metadata
            )
            return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
        }
    }

    @ViewBuilder
    private func findingSection(_ finding: ArchiveSecurityFinding) -> some View {
        DialogSection {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        L10n.text("security.kind.\(finding.kind.rawValue)"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    Spacer()
                    Text("\(finding.entryPaths.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(L10n.text("security.kind.\(finding.kind.rawValue).desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.entryPaths.prefix(Self.maxPathsPerFinding), id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                    }
                    if finding.entryPaths.count > Self.maxPathsPerFinding {
                        Text(L10n.format("security.report.more", "\(finding.entryPaths.count - Self.maxPathsPerFinding)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
