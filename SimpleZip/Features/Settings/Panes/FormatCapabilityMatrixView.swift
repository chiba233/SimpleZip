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
                        Text(row.displayName)
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridColumnAlignment(.leading)
                        ForEach(kinds) { kind in
                            cell(for: row.state(for: kind))
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
