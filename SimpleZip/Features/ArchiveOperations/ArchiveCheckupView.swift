//
//  ArchiveCheckupView.swift
//  SimpleZip
//
//  0.4.4 #7:归档体检批处理报告 —— 每归档一行:能否打开 / 测试结果 / 可疑路径 / 垃圾 /
//  加密 / 缺分卷 / 只读格式 / 疑似同包。密码只走会话缓存静默试,**绝不弹窗**;
//  解不开的如实标「需要密码」。只读分析,接统一导出(F2)。
//

import AppKit
import SwiftUI

struct ArchiveCheckupRow: Identifiable, Equatable {
    enum TestOutcome: Equatable {
        case passed
        case failed(ArchiveTestFailureKind)
        case needsPassword
        case notListable
    }

    let id = UUID()
    let fileName: String
    let testOutcome: TestOutcome
    /// 列得动才有条目事实;需要密码 / 列不动为 nil。
    let facts: ArchiveCheckup.EntryFacts?
    let missingVolumeCount: Int
    let readOnlyFormat: Bool
    /// 疑似同包(结构指纹相同)的同批其他归档名;空 = 没有。
    var duplicatePeers: [String] = []
}

struct ArchiveCheckupReport: Identifiable {
    let id = UUID()
    let scopeName: String
    let rows: [ArchiveCheckupRow]

    var problemCount: Int {
        rows.filter { row in
            if case .passed = row.testOutcome {
                let facts = row.facts
                return (facts?.suspiciousPathCount ?? 0) > 0 || row.missingVolumeCount > 0
            }
            return true
        }.count
    }
}

struct ArchiveCheckupView: View {
    let report: ArchiveCheckupReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "stethoscope",
                colors: report.problemCount == 0 ? [.green, .teal] : [.orange, .yellow],
                title: L10n.text("checkup.title"),
                subtitle: L10n.format("checkup.subtitle", report.scopeName, "\(report.rows.count)")
            )

            HeightCappedScrollView(maxHeight: 640) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        ForEach(report.rows) { row in
                            checkupRow(row)
                            if row.id != report.rows.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                ReportExportControl(report: report)
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 640)
    }

    @ViewBuilder
    private func checkupRow(_ row: ArchiveCheckupRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                testBadge(row.testOutcome)
                Text(row.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            // 维度徽章行:只显示非零 / 异常项,干净包一行绿勾即可。
            HStack(spacing: 10) {
                if let facts = row.facts {
                    if facts.suspiciousPathCount > 0 {
                        badge("exclamationmark.shield.fill", "\(facts.suspiciousPathCount)", tint: .orange, help: L10n.text("checkup.badge.suspicious"))
                    }
                    if facts.junkCount > 0 {
                        badge("paintbrush.fill", "\(facts.junkCount)", tint: .pink, help: L10n.text("checkup.badge.junk"))
                    }
                    if facts.encryptedCount > 0 {
                        badge("lock.fill", "\(facts.encryptedCount)", tint: .purple, help: L10n.text("checkup.badge.encrypted"))
                    }
                }
                if row.missingVolumeCount > 0 {
                    badge("square.split.2x1", "\(row.missingVolumeCount)", tint: .red, help: L10n.text("checkup.badge.missingVolumes"))
                }
                if row.readOnlyFormat {
                    badge("pencil.slash", nil, tint: .secondary, help: L10n.text("checkup.badge.readOnly"))
                }
                if !row.duplicatePeers.isEmpty {
                    badge("doc.on.doc.fill", "\(row.duplicatePeers.count)", tint: .indigo, help: L10n.format("checkup.badge.duplicates", row.duplicatePeers.joined(separator: ", ")))
                }
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func testBadge(_ outcome: ArchiveCheckupRow.TestOutcome) -> some View {
        switch outcome {
        case .passed:
            Label(L10n.text("checkup.test.passed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
        case .failed(let kind):
            Label(L10n.text("test.failure.\(kind.rawValue)"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .needsPassword:
            Label(L10n.text("checkup.test.needsPassword"), systemImage: "key.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .notListable:
            Label(L10n.text("inspect.notListable"), systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
    }

    private func badge(_ systemImage: String, _ count: String?, tint: Color, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            if let count {
                Text(count)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .help(help)
    }
}

// MARK: - 统一导出(F2)

extension ArchiveCheckupReport: ReportExportable {
    var reportTitle: String { "\(L10n.text("checkup.title")) — \(scopeName)" }
    var reportTargetPath: String? { nil }

    var reportSummaryLine: String {
        "\(scopeName) — " + L10n.format("checkup.summary", "\(rows.count)", "\(problemCount)")
    }

    func reportMarkdown(metadata: ReportMetadata?) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.text("checkup.title"))")
        lines.append("")
        lines.append("**\(scopeName)** — " + L10n.format("checkup.summary", "\(rows.count)", "\(problemCount)"))
        lines.append("")
        for row in rows {
            let mark: String
            switch row.testOutcome {
            case .passed: mark = "✓"
            case .failed: mark = "✗"
            case .needsPassword, .notListable: mark = "?"
            }
            var parts: [String] = []
            if case .failed(let kind) = row.testOutcome { parts.append(L10n.text("test.failure.\(kind.rawValue)")) }
            if case .needsPassword = row.testOutcome { parts.append(L10n.text("checkup.test.needsPassword")) }
            if let facts = row.facts {
                if facts.suspiciousPathCount > 0 { parts.append("\(L10n.text("checkup.badge.suspicious")): \(facts.suspiciousPathCount)") }
                if facts.junkCount > 0 { parts.append("\(L10n.text("checkup.badge.junk")): \(facts.junkCount)") }
                if facts.encryptedCount > 0 { parts.append("\(L10n.text("checkup.badge.encrypted")): \(facts.encryptedCount)") }
            }
            if row.missingVolumeCount > 0 { parts.append("\(L10n.text("checkup.badge.missingVolumes")): \(row.missingVolumeCount)") }
            if row.readOnlyFormat { parts.append(L10n.text("checkup.badge.readOnly")) }
            if !row.duplicatePeers.isEmpty { parts.append(L10n.format("checkup.badge.duplicates", row.duplicatePeers.joined(separator: ", "))) }
            lines.append("- \(mark) `\(row.fileName)`" + (parts.isEmpty ? "" : " — " + parts.joined(separator: " · ")))
        }
        lines.append("")
        var markdown = lines.joined(separator: "\n")
        if let metadata {
            markdown += ReportExport.markdownFooter(metadata) + "\n"
        }
        return markdown
    }

    private struct JSONReport: Encodable {
        struct Row: Encodable {
            let file: String
            let test: String
            let suspiciousPathCount: Int?
            let junkCount: Int?
            let encryptedCount: Int?
            let missingVolumeCount: Int
            let readOnlyFormat: Bool
            let duplicatePeers: [String]
        }
        let scope: String
        let rows: [Row]
        let metadata: ReportMetadata?
    }

    func reportJSON(metadata: ReportMetadata?) throws -> String {
        let snapshot = JSONReport(
            scope: scopeName,
            rows: rows.map { row in
                let test: String
                switch row.testOutcome {
                case .passed: test = "passed"
                case .failed(let kind): test = "failed:\(kind.rawValue)"
                case .needsPassword: test = "needsPassword"
                case .notListable: test = "notListable"
                }
                return JSONReport.Row(
                    file: row.fileName,
                    test: test,
                    suspiciousPathCount: row.facts?.suspiciousPathCount,
                    junkCount: row.facts?.junkCount,
                    encryptedCount: row.facts?.encryptedCount,
                    missingVolumeCount: row.missingVolumeCount,
                    readOnlyFormat: row.readOnlyFormat,
                    duplicatePeers: row.duplicatePeers
                )
            },
            metadata: metadata
        )
        return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
    }
}
