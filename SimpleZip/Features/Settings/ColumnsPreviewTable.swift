//
//  ColumnsPreviewTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

struct ColumnPreview: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    /// 列在内容充足时的理想宽度。
    /// 内容不够宽时按比例缩放，过窄时再压到 `minimumContentWidth`，避免文本完全消失。
    let preferredWidth: CGFloat
}

/// 列预览表格：根据用户勾选的列做一个迷你示例表，自适应可用宽度。
///
/// 用 GeometryReader 自己算每列宽，而不是用 SwiftUI Grid，是因为：
/// 1) 需要在「列太多放不下」时按比例压缩各列，而不是横向滚动；
/// 2) 第一列（名称）要保留更高的最小宽度，单纯 Grid 难表达这种权重差异。
struct ColumnsPreviewTable: View {
    let title: String
    let columns: [ColumnPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            GeometryReader { proxy in
                let cellHorizontalPadding: CGFloat = 12
                let availableContentWidth = max(0, proxy.size.width - cellHorizontalPadding * CGFloat(columns.count))
                let preferredContentWidth = columns.reduce(CGFloat.zero) { $0 + $1.preferredWidth }
                // 第一列（名称）82pt 兜底，其它列 42pt：保证再窄也能看到几个字。
                let minimumContentWidths = columns.indices.map { $0 == 0 ? CGFloat(82) : CGFloat(42) }
                let minimumContentWidth = minimumContentWidths.reduce(CGFloat.zero, +)
                let contentWidths = columns.indices.map { index in
                    if preferredContentWidth <= availableContentWidth {
                        return columns[index].preferredWidth
                    }
                    if minimumContentWidth >= availableContentWidth {
                        return minimumContentWidths[index] * availableContentWidth / max(minimumContentWidth, 1)
                    }
                    // 在「比理想窄、但还没到底线」之间线性插值，让所有列按相同比例缩。
                    let flexibleWidth = max(preferredContentWidth - minimumContentWidth, 1)
                    let compressionRatio = (availableContentWidth - minimumContentWidth) / flexibleWidth
                    return minimumContentWidths[index] + (columns[index].preferredWidth - minimumContentWidths[index]) * compressionRatio
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns.indices, id: \.self) { index in
                            previewCell(columns[index].title, width: contentWidths[index], isHeader: true)
                        }
                    }
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(columns.indices, id: \.self) { index in
                            previewCell(columns[index].value, width: contentWidths[index], isHeader: false)
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
            }
            .frame(height: 68)
        }
    }

    private func previewCell(_ text: String, width: CGFloat, isHeader: Bool) -> some View {
        Text(text)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: isHeader ? 28 : 34, alignment: .center)
            .background(isHeader ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .overlay(alignment: .trailing) {
                Divider()
            }
    }
}
