//
//  ArchiveSpaceAnalysisView.swift
//  SimpleZip
//
//  队列 #8:归档空间分析报告 —— 「哪里占地方」:总览 / Top 大文件 / 顶层目录 / 扩展名。
//  分析引擎在 Core/ArchiveSpaceAnalysis(纯函数,已单测);这里只展示。
//  报告类弹窗:close-only,PinnedBottomBar + DialogSection 组件拼装。
//

import AppKit
import SwiftUI

/// 一次空间分析的展示载体(挂在 model 上驱动 sheet)。
struct ArchiveSpaceAnalysisReport: Identifiable {
    let id = UUID()
    let archiveName: String
    let analysis: ArchiveSpaceAnalysis
}

/// F2:接统一导出底座。Markdown 跟 UI 语言;JSON 字段名固定英文。
extension ArchiveSpaceAnalysisReport: ReportExportable {
    var reportTitle: String { "\(L10n.text("space.title")) — \(archiveName)" }
    var reportTargetPath: String? { nil }

    var reportSummaryLine: String {
        var parts = [archiveName, ByteCountFormatter.string(fromByteCount: analysis.totalBytes, countStyle: .file)]
        if let ratio = analysis.compressionRatio {
            parts.append(L10n.format("space.packed.value",
                                     ByteCountFormatter.string(fromByteCount: analysis.packedBytes, countStyle: .file),
                                     "\(Int(ratio * 100))"))
        }
        return parts.joined(separator: " · ")
    }

    func reportMarkdown(metadata: ReportMetadata?) -> String {
        func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
        func section(_ titleKey: String, _ entries: [ArchiveSpaceAnalysis.Entry], emptyName: String) -> [String] {
            guard !entries.isEmpty else { return [] }
            var lines = ["## \(L10n.text(titleKey))", ""]
            lines.append(contentsOf: entries.map { "- `\($0.name.isEmpty ? emptyName : $0.name)` — \(bytes($0.bytes))" })
            lines.append("")
            return lines
        }
        var lines: [String] = []
        lines.append("# \(L10n.text("space.title"))")
        lines.append("")
        lines.append("**\(archiveName)**")
        lines.append("")
        lines.append("- \(L10n.text("space.total")): \(bytes(analysis.totalBytes))")
        if let ratio = analysis.compressionRatio {
            lines.append("- \(L10n.text("space.packed")): \(L10n.format("space.packed.value", bytes(analysis.packedBytes), "\(Int(ratio * 100))"))")
        }
        if analysis.encryptedCount > 0 {
            lines.append("- \(L10n.text("space.encrypted")): \(L10n.format("space.count.value", "\(analysis.encryptedCount)", bytes(analysis.encryptedBytes)))")
        }
        if analysis.junkCount > 0 {
            lines.append("- \(L10n.text("space.junk")): \(L10n.format("space.count.value", "\(analysis.junkCount)", bytes(analysis.junkBytes)))")
        }
        lines.append("")
        lines.append(contentsOf: section("space.section.largest", analysis.largestFiles, emptyName: "-"))
        lines.append(contentsOf: section("space.section.directories", analysis.topLevelDirectories, emptyName: L10n.text("space.rootEntries")))
        lines.append(contentsOf: section("space.section.extensions", analysis.extensions.map {
            ArchiveSpaceAnalysis.Entry(name: $0.name.isEmpty ? "" : ".\($0.name)", bytes: $0.bytes)
        }, emptyName: L10n.text("space.noExtension")))
        var markdown = lines.joined(separator: "\n")
        if let metadata {
            markdown += ReportExport.markdownFooter(metadata) + "\n"
        }
        return markdown
    }

    private struct JSONReport: Encodable {
        struct Entry: Encodable {
            let name: String
            let bytes: Int64
        }
        let archive: String
        let totalBytes: Int64
        let packedBytes: Int64
        let fileCount: Int
        let encryptedCount: Int
        let encryptedBytes: Int64
        let junkCount: Int
        let junkBytes: Int64
        let largestFiles: [Entry]
        let topLevelDirectories: [Entry]
        let extensions: [Entry]
        let metadata: ReportMetadata?
    }

    func reportJSON(metadata: ReportMetadata?) throws -> String {
        func entries(_ source: [ArchiveSpaceAnalysis.Entry]) -> [JSONReport.Entry] {
            source.map { JSONReport.Entry(name: $0.name, bytes: $0.bytes) }
        }
        let snapshot = JSONReport(
            archive: archiveName,
            totalBytes: analysis.totalBytes,
            packedBytes: analysis.packedBytes,
            fileCount: analysis.fileCount,
            encryptedCount: analysis.encryptedCount,
            encryptedBytes: analysis.encryptedBytes,
            junkCount: analysis.junkCount,
            junkBytes: analysis.junkBytes,
            largestFiles: entries(analysis.largestFiles),
            topLevelDirectories: entries(analysis.topLevelDirectories),
            extensions: entries(analysis.extensions),
            metadata: metadata
        )
        return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
    }
}

struct ArchiveSpaceAnalysisView: View {
    let report: ArchiveSpaceAnalysisReport
    let onClose: () -> Void

    private var analysis: ArchiveSpaceAnalysis { report.analysis }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "chart.pie.fill",
                colors: [.orange, .yellow],
                title: L10n.text("space.title"),
                subtitle: report.archiveName
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        overviewRow(L10n.text("space.total"),
                                    value: bytes(analysis.totalBytes), systemImage: "doc.fill", tint: .blue)
                        if let ratio = analysis.compressionRatio {
                            overviewRow(L10n.text("space.packed"),
                                        value: L10n.format("space.packed.value", bytes(analysis.packedBytes), "\(Int(ratio * 100))"),
                                        systemImage: "arrow.down.right.circle.fill", tint: .green)
                        }
                        if analysis.encryptedCount > 0 {
                            overviewRow(L10n.text("space.encrypted"),
                                        value: L10n.format("space.count.value", "\(analysis.encryptedCount)", bytes(analysis.encryptedBytes)),
                                        systemImage: "lock.fill", tint: .purple)
                        }
                        if analysis.junkCount > 0 {
                            overviewRow(L10n.text("space.junk"),
                                        value: L10n.format("space.count.value", "\(analysis.junkCount)", bytes(analysis.junkBytes)),
                                        systemImage: "paintbrush.fill", tint: .pink)
                        }
                    }

                    if !analysis.largestFiles.isEmpty {
                        DialogSection(L10n.text("space.section.largest")) {
                            barRows(analysis.largestFiles, tint: .blue)
                        }
                    }
                    if !analysis.topLevelDirectories.isEmpty {
                        DialogSection(L10n.text("space.section.directories")) {
                            barRows(analysis.topLevelDirectories.map {
                                ArchiveSpaceAnalysis.Entry(name: $0.name.isEmpty ? L10n.text("space.rootEntries") : $0.name, bytes: $0.bytes)
                            }, tint: .indigo)
                        }
                    }
                    if !analysis.extensions.isEmpty {
                        DialogSection(L10n.text("space.section.extensions")) {
                            barRows(analysis.extensions.map {
                                ArchiveSpaceAnalysis.Entry(name: $0.name.isEmpty ? L10n.text("space.noExtension") : ".\($0.name)", bytes: $0.bytes)
                            }, tint: .teal)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                // F2:统一导出(摘要 / GitHub Issue / Markdown / JSON)。
                ReportExportControl(report: report)
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
        .frame(width: 560)
    }

    private func overviewRow(_ title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DialogRowLabel(title, systemImage: systemImage, tint: tint)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    /// 占比条形行:名字 + 比例条 + 大小(右对齐)。条宽按本组最大值归一,直觉对比。
    @ViewBuilder
    private func barRows(_ entries: [ArchiveSpaceAnalysis.Entry], tint: Color) -> some View {
        let maxBytes = entries.map(\.bytes).max() ?? 1
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            HStack(spacing: 10) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 220, alignment: .leading)
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint.opacity(0.55))
                        .frame(width: max(3, proxy.size.width * CGFloat(entry.bytes) / CGFloat(max(maxBytes, 1))))
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 8)
                Text(bytes(entry.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
