//
//  HashResultsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 哈希结果弹窗，提供完整结果查看和复制。
struct HashResultsView: View {
    let report: HashReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                // 0.4.1：title 左加大彩色图标瓦片，跟其它对话框 hero 统一。
                Image(systemName: "number.square.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("hash.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.format("hash.summary", report.fileCount, ByteCountFormatter.string(fromByteCount: report.totalSize, countStyle: .file)))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.text("button.copyAll")) {
                    copyAllResults()
                }

                Button(L10n.text("button.ok")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(report.results) { result in
                        HashResultCard(report: report, result: result)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 340)
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 620)
    }

    private func copyAllResults() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
    }
}

/// 单个文件的哈希结果卡片。`internal` 以便活动中心详情直接复用同一套格式化 UI（不要重画）。
struct HashResultCard: View {
    let report: HashReport
    let result: FileHashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.displayName, systemImage: "doc")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }

            Text(result.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(report.algorithms) { algorithm in
                    if let value = result.value(for: algorithm) {
                        HashRow(name: algorithm.title, value: value)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

private struct HashRow: View {
    let name: String
    let value: String

    var body: some View {
        GridRow {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
        }
    }
}
