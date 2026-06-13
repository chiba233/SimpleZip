//
//  ReleaseDirectoryAuditView.swift
//  SimpleZip
//
//  0.4.4 #11:发布目录完整性检查报告。纯逻辑在 Core/ReleaseDirectoryAudit(可测);
//  异步部分(哈希核对 / .szs 清单 / 隔离验签)在 model 任务里跑,结果拼成本报告。
//  只读 —— 检查从不改目录里的任何文件;验签用临时 GNUPGHOME,不碰用户钥匙环。
//

import AppKit
import SwiftUI

/// 一条检查结论。message 已本地化(任务里构建);detailItems = 涉及的文件名清单。
struct ReleaseDirectoryAuditFinding: Identifiable, Equatable {
    enum Severity: Equatable {
        case pass
        case info
        case warning
        case failure
    }

    let id = UUID()
    let severity: Severity
    let message: String
    var detailItems: [String] = []
}

/// 一次目录检查的展示载体(挂 model 驱动 sheet)。
struct ReleaseDirectoryAuditReport: Identifiable {
    let id = UUID()
    let directoryURL: URL
    let findings: [ReleaseDirectoryAuditFinding]

    var worstSeverity: ReleaseDirectoryAuditFinding.Severity {
        if findings.contains(where: { $0.severity == .failure }) { return .failure }
        if findings.contains(where: { $0.severity == .warning }) { return .warning }
        return .pass
    }
}

struct ReleaseDirectoryAuditView: View {
    let report: ReleaseDirectoryAuditReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: report.worstSeverity == .pass ? "checkmark.seal.fill" : "folder.badge.questionmark",
                colors: report.worstSeverity == .failure ? [.red, .orange]
                    : report.worstSeverity == .warning ? [.orange, .yellow] : [.green, .teal],
                title: L10n.text("dirAudit.title"),
                subtitle: report.directoryURL.lastPathComponent
            )

            HeightCappedScrollView(maxHeight: 640) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        ForEach(report.findings) { finding in
                            findingRow(finding)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                ReportExportControl(report: report)
                // AI 白话解释发布目录检查(是否构成完整可验证发布 + 每个警告/失败影响哪些文件)。
                AIAssistButton(
                    label: L10n.text("ai.explainAudit"),
                    systemImage: "sparkles",
                    sheetTitle: L10n.text("ai.explainAudit.title"),
                    sheetSubtitle: report.directoryURL.lastPathComponent
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let built = AIReportAssistant.directoryAuditExplanationPrompt(for: report)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                // #55:从目录实况起草 VERIFY.md + 缺失项建议(只起草,产出可编辑由用户审阅自取)。
                AIAssistButton(
                    label: L10n.text("ai.draftVerify"),
                    systemImage: "doc.badge.gearshape",
                    sheetTitle: L10n.text("ai.draftVerify.title"),
                    sheetSubtitle: report.directoryURL.lastPathComponent
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let built = AIReportAssistant.verifyDraftPrompt(for: report)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 620)
    }

    @ViewBuilder
    private func findingRow(_ finding: ReleaseDirectoryAuditFinding) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(finding.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                switch finding.severity {
                case .pass:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .info:
                    Image(systemName: "info.circle").foregroundStyle(Color.secondary)
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
            .font(.callout)
            if !finding.detailItems.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(finding.detailItems.prefix(12), id: \.self) { item in
                        Text(item)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if finding.detailItems.count > 12 {
                        Text(L10n.format("security.report.more", "\(finding.detailItems.count - 12)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}

// MARK: - 统一导出(F2)

extension ReleaseDirectoryAuditReport: ReportExportable {
    var reportTitle: String { "\(L10n.text("dirAudit.title")) — \(directoryURL.lastPathComponent)" }
    var reportTargetPath: String? { directoryURL.path }

    var reportSummaryLine: String {
        let warnings = findings.filter { $0.severity == .warning }.count
        let failures = findings.filter { $0.severity == .failure }.count
        return "\(directoryURL.lastPathComponent) — " + L10n.format("dirAudit.summary", "\(failures)", "\(warnings)")
    }

    func reportMarkdown(metadata: ReportMetadata?) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.text("dirAudit.title"))")
        lines.append("")
        lines.append("**\(directoryURL.path)**")
        lines.append("")
        for finding in findings {
            let mark: String
            switch finding.severity {
            case .pass: mark = "✓"
            case .info: mark = "ℹ︎"
            case .warning: mark = "⚠"
            case .failure: mark = "✗"
            }
            lines.append("- \(mark) \(finding.message)")
            lines.append(contentsOf: finding.detailItems.map { "    - `\($0)`" })
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
            let severity: String
            let message: String
            let items: [String]
        }
        let directory: String
        let findings: [Finding]
        let metadata: ReportMetadata?
    }

    func reportJSON(metadata: ReportMetadata?) throws -> String {
        let snapshot = JSONReport(
            directory: directoryURL.path,
            findings: findings.map { finding in
                let severity: String
                switch finding.severity {
                case .pass: severity = "pass"
                case .info: severity = "info"
                case .warning: severity = "warning"
                case .failure: severity = "failure"
                }
                return JSONReport.Finding(severity: severity, message: finding.message, items: finding.detailItems)
            },
            metadata: metadata
        )
        return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
    }
}
