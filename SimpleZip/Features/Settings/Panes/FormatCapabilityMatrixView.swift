//
//  FormatCapabilityMatrixView.swift
//  SimpleZip
//
//  设置 → 压缩里的「格式能力对照表」。纯展示，数据来自 Core 的 `FormatCapabilityMatrix`。
//  目的：让用户（和我们自己）一眼看清各容器格式支持哪些操作，减少「为什么 TAR 不能加密」这类困惑。
//

import SwiftUI

struct FormatCapabilityMatrixView: View {
    private let rows = FormatCapabilityMatrix.rows
    private let kinds = FormatCapabilityKind.allCases

    /// 0.4.2 #14：点格式名展开「后端 + 为什么能 / 不能」详情卡。nil = 全收起。
    @State private var expandedFormatID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.text("settings.formatMatrix.format"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(kinds) { kind in
                        Text(header(for: kind))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(kinds.count + 1)
                ForEach(rows) { row in
                    GridRow {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedFormatID = expandedFormatID == row.id ? nil : row.id
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(expandedFormatID == row.id ? 90 : 0))
                                Text(row.displayName)
                                    .font(.caption.weight(.medium))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("settings.formatMatrix.rowHelp"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                        ForEach(kinds) { kind in
                            cell(for: row.state(for: kind))
                        }
                    }
                    if expandedFormatID == row.id {
                        GridRow {
                            formatDetailCard(row)
                                .gridCellColumns(kinds.count + 1)
                        }
                    }
                }
            }

            Text(L10n.text("settings.formatMatrix.conditionalNote"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 展开的格式详情：处理后端 + 能力边界的「为什么」。文案按格式 id 走 L10n（一格式一段）。
    private func formatDetailCard(_ row: FormatCapabilityRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("settings.formatMatrix.backend.\(row.id)"), systemImage: "gearshape.2")
                .font(.caption.weight(.medium))
            Text(L10n.text("settings.formatMatrix.detail.\(row.id)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func cell(for state: CapabilityState) -> some View {
        switch state {
        case .yes:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
        case .conditional:
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                Text("*").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.orange)
        case .no:
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func header(for kind: FormatCapabilityKind) -> String {
        switch kind {
        case .create: return L10n.text("settings.formatMatrix.col.create")
        case .extract: return L10n.text("settings.formatMatrix.col.extract")
        case .editEntries: return L10n.text("settings.formatMatrix.col.edit")
        case .encrypt: return L10n.text("settings.formatMatrix.col.encrypt")
        case .headerEncrypt: return L10n.text("settings.formatMatrix.col.header")
        case .splitVolumes: return L10n.text("settings.formatMatrix.col.split")
        case .test: return L10n.text("settings.formatMatrix.col.test")
        case .comment: return L10n.text("settings.formatMatrix.col.comment")
        }
    }
}
