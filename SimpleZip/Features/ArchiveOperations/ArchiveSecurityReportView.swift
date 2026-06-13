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

    /// #18 规则化安全评分(纯规则、不用 AI):安全发现 + 加密 / macOS 垃圾信号 → A/B/C。
    /// 本面不跑完整性测试、不查分卷,故 corrupted / missingVolumes 不参与(传默认值)。
    private var riskAssessment: ArchiveRiskScore.Assessment {
        ArchiveRiskScore.assess(
            findings: model.archiveSecurityFindings,
            encryptedCount: model.archiveItems.filter(\.isEncrypted).count,
            junkCount: model.archiveItems.filter { ArchiveJunkFiles.isJunkPath($0.name) }.count
        )
    }

    private func gradeColor(_ grade: ArchiveRiskScore.Grade) -> Color {
        switch grade {
        case .a: return .green
        case .b: return .orange
        case .c: return .red
        }
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
                    // #18:顶部规则化安全评分徽章 —— 让普通用户一眼看懂整体风险(A/B/C ↔ 低/中/高)。
                    gradeBadge(riskAssessment)

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
                    findings: model.archiveSecurityFindings,
                    assessment: riskAssessment
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

    /// 规则化评分徽章:大写字母 A/B/C(绿/橙/红)+ 低/中/高 + 「按最严重问题定级、纯规则不用 AI」说明。
    private func gradeBadge(_ assessment: ArchiveRiskScore.Assessment) -> some View {
        DialogSection {
            HStack(spacing: 14) {
                Text(assessment.grade.rawValue.uppercased())
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(gradeColor(assessment.grade), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("security.score.level.\(assessment.level.rawValue)"))
                        .font(.headline)
                        .foregroundStyle(gradeColor(assessment.grade))
                    Text(L10n.text("security.score.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
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
        let assessment: ArchiveRiskScore.Assessment

        var reportTitle: String { "\(L10n.text("security.report.title")) — \(archiveName)" }
        var reportTargetPath: String? { archivePath }

        /// 「[A] 低风险」前缀 —— 评分始终领头,导出的报告也能一眼看懂。
        private var gradePrefix: String {
            "[\(assessment.grade.rawValue.uppercased())] \(L10n.text("security.score.level.\(assessment.level.rawValue)"))"
        }

        var reportSummaryLine: String {
            guard !findings.isEmpty else {
                return "\(archiveName) — \(gradePrefix) · \(L10n.text("security.report.clean"))"
            }
            let total = findings.reduce(0) { $0 + $1.entryPaths.count }
            let kinds = findings.map { L10n.text("security.kind.\($0.kind.rawValue)") }.joined(separator: ", ")
            return "\(archiveName) — \(gradePrefix) · \(L10n.format("security.report.summary", "\(total)", kinds))"
        }

        func reportMarkdown(metadata: ReportMetadata?) -> String {
            var lines: [String] = []
            lines.append("# \(L10n.text("security.report.title"))")
            lines.append("")
            lines.append("**\(archiveName)**")
            lines.append("")
            lines.append("**\(gradePrefix)** — \(L10n.text("security.score.note"))")
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
            let grade: String
            let riskLevel: String
            let findings: [Finding]
            let metadata: ReportMetadata?
        }

        func reportJSON(metadata: ReportMetadata?) throws -> String {
            let snapshot = JSONReport(
                archive: archiveName,
                grade: assessment.grade.rawValue.uppercased(),
                riskLevel: assessment.level.rawValue,
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
