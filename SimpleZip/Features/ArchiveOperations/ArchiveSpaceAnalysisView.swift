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
