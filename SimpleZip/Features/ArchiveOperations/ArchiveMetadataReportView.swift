//
//  ArchiveMetadataReportView.swift
//  SimpleZip
//
//  0.4.4 #13:归档元数据报告 —— 归档级属性(l -slt 头部块,Core/ArchiveProperties 解析)+
//  条目聚合(方法分布 / 加密 / AppleDouble 痕迹 / 属性分布)+ 安全发现计数。
//  只读展示;报告类弹窗 close-only,接统一导出(F2)。
//

import AppKit
import SwiftUI

/// 一次元数据报告的展示载体(挂 model 驱动 sheet)。
struct ArchiveMetadataReport: Identifiable, Codable {
    let id = UUID()
    /// Codable 排除 `id`(带初值的 let 不能解码)—— 0.4.4 报告随任务历史持久化用。
    private enum CodingKeys: String, CodingKey {
        case archiveName, archivePath, properties, aggregate, headerComment, securityFindingCount
    }
    let archiveName: String
    let archivePath: String
    /// 头部块属性(7zz 没报 / 列不动时为 nil —— 聚合部分照常显示)。
    let properties: ArchiveProperties?
    let aggregate: ArchiveMetadataAggregate
    /// 归档级注释(空 = 无)。
    let headerComment: String
    /// 打开时安全报告的可疑条目计数(编码风险/路径问题;详情看安全报告)。
    let securityFindingCount: Int
}

struct ArchiveMetadataReportView: View {
    let report: ArchiveMetadataReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "info.square.fill",
                colors: [.indigo, .purple],
                title: L10n.text("metadata.title"),
                subtitle: report.archiveName
            )

            HeightCappedScrollView(maxHeight: 620) {
                VStack(alignment: .leading, spacing: 12) {
                    if let properties = report.properties {
                        DialogSection(L10n.text("metadata.section.archive")) {
                            if let type = properties.type {
                                infoRow(L10n.text("metadata.type"), value: type, systemImage: "shippingbox.fill", tint: .brown)
                            }
                            if let physical = properties.physicalSizeBytes {
                                infoRow(L10n.text("metadata.physicalSize"), value: bytes(physical), systemImage: "scalemass.fill", tint: .blue)
                            }
                            if let headers = properties.headersSizeBytes {
                                infoRow(L10n.text("metadata.headersSize"), value: bytes(headers), systemImage: "list.bullet.rectangle.fill", tint: .teal)
                            }
                            if let method = properties.method {
                                infoRow(L10n.text("metadata.method"), value: method, systemImage: "cpu.fill", tint: .indigo)
                            }
                            if let solid = properties.solid {
                                infoRow(L10n.text("metadata.solid"), value: solid ? L10n.text("metadata.yes") : L10n.text("metadata.no"), systemImage: "square.stack.3d.up.fill", tint: .purple)
                            }
                            if let blocks = properties.blocks {
                                infoRow(L10n.text("metadata.blocks"), value: "\(blocks)", systemImage: "square.grid.2x2.fill", tint: .cyan)
                            }
                            if let volumes = properties.volumes {
                                infoRow(L10n.text("metadata.volumes"), value: "\(volumes)", systemImage: "square.split.2x1.fill", tint: .orange)
                            }
                            if !report.headerComment.isEmpty {
                                infoRow(L10n.text("metadata.comment"), value: report.headerComment, systemImage: "text.bubble.fill", tint: .pink)
                            }
                        }
                    }

                    DialogSection(L10n.text("metadata.section.entries")) {
                        infoRow(L10n.text("metadata.entryCount"),
                                value: L10n.format("metadata.entries", "\(report.aggregate.fileCount)", "\(report.aggregate.folderCount)"),
                                systemImage: "number.square.fill", tint: .teal)
                        if report.aggregate.encryptedCount > 0 {
                            infoRow(L10n.text("metadata.encrypted"), value: "\(report.aggregate.encryptedCount)", systemImage: "lock.fill", tint: .orange)
                        }
                        if report.aggregate.appleDoubleCount > 0 {
                            infoRow(L10n.text("metadata.appleDouble"), value: "\(report.aggregate.appleDoubleCount)", systemImage: "doc.badge.gearshape", tint: .pink)
                        }
                        if report.securityFindingCount > 0 {
                            infoRow(L10n.text("metadata.securityFindings"), value: "\(report.securityFindingCount)", systemImage: "exclamationmark.shield.fill", tint: .red)
                        }
                    }

                    if !report.aggregate.methodDistribution.isEmpty {
                        DialogSection(L10n.text("metadata.section.methods")) {
                            ForEach(report.aggregate.methodDistribution, id: \.method) { share in
                                HStack {
                                    Text(share.method)
                                        .font(.callout.monospaced())
                                    Spacer()
                                    Text("\(share.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !report.aggregate.topAttributes.isEmpty {
                        DialogSection(L10n.text("metadata.section.attributes")) {
                            ForEach(report.aggregate.topAttributes, id: \.method) { share in
                                HStack {
                                    Text(share.method)
                                        .font(.callout.monospaced())
                                    Spacer()
                                    Text("\(share.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
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
                ReportExportControl(report: report)
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

    private func infoRow(_ label: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DialogRowLabel(label, systemImage: systemImage, tint: tint)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - 统一导出(F2)

extension ArchiveMetadataReport: ReportExportable {
    var reportTitle: String { "\(L10n.text("metadata.title")) — \(archiveName)" }
    var reportTargetPath: String? { archivePath }

    var reportSummaryLine: String {
        var parts = [archiveName]
        if let type = properties?.type { parts.append(type) }
        parts.append(L10n.format("metadata.entries", "\(aggregate.fileCount)", "\(aggregate.folderCount)"))
        if aggregate.encryptedCount > 0 {
            parts.append(L10n.format("space.count.value", "\(aggregate.encryptedCount)", L10n.text("metadata.encrypted")))
        }
        return parts.joined(separator: " · ")
    }

    func reportMarkdown(metadata: ReportMetadata?) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.text("metadata.title"))")
        lines.append("")
        lines.append("**\(archiveName)**")
        lines.append("")
        if let properties {
            if let type = properties.type { lines.append("- \(L10n.text("metadata.type")): \(type)") }
            if let physical = properties.physicalSizeBytes { lines.append("- \(L10n.text("metadata.physicalSize")): \(physical)") }
            if let headers = properties.headersSizeBytes { lines.append("- \(L10n.text("metadata.headersSize")): \(headers)") }
            if let method = properties.method { lines.append("- \(L10n.text("metadata.method")): `\(method)`") }
            if let solid = properties.solid { lines.append("- \(L10n.text("metadata.solid")): \(solid ? L10n.text("metadata.yes") : L10n.text("metadata.no"))") }
            if let blocks = properties.blocks { lines.append("- \(L10n.text("metadata.blocks")): \(blocks)") }
            if let volumes = properties.volumes { lines.append("- \(L10n.text("metadata.volumes")): \(volumes)") }
        }
        lines.append("- \(L10n.text("metadata.entryCount")): \(aggregate.fileCount) / \(aggregate.folderCount)")
        if aggregate.encryptedCount > 0 { lines.append("- \(L10n.text("metadata.encrypted")): \(aggregate.encryptedCount)") }
        if aggregate.appleDoubleCount > 0 { lines.append("- \(L10n.text("metadata.appleDouble")): \(aggregate.appleDoubleCount)") }
        if securityFindingCount > 0 { lines.append("- \(L10n.text("metadata.securityFindings")): \(securityFindingCount)") }
        if !aggregate.methodDistribution.isEmpty {
            lines.append("")
            lines.append("## \(L10n.text("metadata.section.methods"))")
            lines.append("")
            lines.append(contentsOf: aggregate.methodDistribution.map { "- `\($0.method)` — \($0.count)" })
        }
        lines.append("")
        var markdown = lines.joined(separator: "\n")
        if let metadata {
            markdown += ReportExport.markdownFooter(metadata) + "\n"
        }
        return markdown
    }

    private struct JSONReport: Encodable {
        struct Share: Encodable {
            let value: String
            let count: Int
        }
        let archive: String
        let type: String?
        let physicalSizeBytes: Int64?
        let headersSizeBytes: Int64?
        let method: String?
        let solid: Bool?
        let blocks: Int?
        let volumes: Int?
        let fileCount: Int
        let folderCount: Int
        let encryptedCount: Int
        let appleDoubleCount: Int
        let securityFindingCount: Int
        let methodDistribution: [Share]
        let topAttributes: [Share]
        let metadata: ReportMetadata?
    }

    func reportJSON(metadata: ReportMetadata?) throws -> String {
        let snapshot = JSONReport(
            archive: archiveName,
            type: properties?.type,
            physicalSizeBytes: properties?.physicalSizeBytes,
            headersSizeBytes: properties?.headersSizeBytes,
            method: properties?.method,
            solid: properties?.solid,
            blocks: properties?.blocks,
            volumes: properties?.volumes,
            fileCount: aggregate.fileCount,
            folderCount: aggregate.folderCount,
            encryptedCount: aggregate.encryptedCount,
            appleDoubleCount: aggregate.appleDoubleCount,
            securityFindingCount: securityFindingCount,
            methodDistribution: aggregate.methodDistribution.map { JSONReport.Share(value: $0.method, count: $0.count) },
            topAttributes: aggregate.topAttributes.map { JSONReport.Share(value: $0.method, count: $0.count) },
            metadata: metadata
        )
        return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
    }
}
