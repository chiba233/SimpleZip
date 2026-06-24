//
//  FileSplitSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  右键「拆分…」的小确认 sheet：选每卷大小（数值 + 单位），引擎在 Core/FileSplitCombine
//  （字节级切分，对齐官方 7-Zip 的 Split 语义）。体例对齐 FilePermissionsEditorSheet。
//

import SwiftUI

/// 「拆分文件」待确认请求。`fileSize` 用来在 sheet 里显示「将拆成 ~N 片」预估。
struct FileSplitRequest: Identifiable {
    let id = UUID()
    let url: URL
    let fileSize: Int64
}

struct FileSplitSheet: View {
    let request: FileSplitRequest
    let apply: (Int64) -> Void
    let cancel: () -> Void

    private enum SizeUnit: String, CaseIterable, Identifiable {
        case kilobytes
        case megabytes
        case gigabytes

        var id: String { rawValue }
        var title: String {
            switch self {
            case .kilobytes: return "KB"
            case .megabytes: return "MB"
            case .gigabytes: return "GB"
            }
        }
        var multiplier: Double {
            switch self {
            case .kilobytes: return 1_000
            case .megabytes: return 1_000_000
            case .gigabytes: return 1_000_000_000
            }
        }
    }

    // 0.4.2 数值支持小数（1.5 GB / 4.7 GB 刻 DVD 这类都是真实需求）+ 补 KB 档。
    @State private var sizeValue = 100.0
    @State private var sizeUnit = SizeUnit.megabytes

    private var volumeSizeBytes: Int64 {
        let bytes = max(0, sizeValue) * sizeUnit.multiplier
        guard bytes.isFinite, bytes < 9e18 else { return 0 }
        return Int64(bytes)
    }

    private var estimatedPartCount: Int {
        guard volumeSizeBytes > 0 else { return 0 }
        return max(1, Int((request.fileSize + volumeSizeBytes - 1) / volumeSizeBytes))
    }

    var body: some View {
        // design system:统一走 TaskDialogShell 骨架。
        TaskDialogShell(
            heroSystemImage: "scissors",
            heroColors: [.orange, .red],
            title: L10n.text("split.heroTitle"),
            subtitle: request.url.lastPathComponent,
            width: 440,
            confirmTitle: L10n.text("split.button"),
            confirmSystemImage: "scissors",
            confirmDisabled: volumeSizeBytes <= 0,
            confirm: { apply(volumeSizeBytes) },
            cancel: cancel
        ) {
                DialogSection {
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("", value: $sizeValue, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                                .dialogFieldEmphasis()
                            Picker("", selection: $sizeUnit) {
                                ForEach(SizeUnit.allCases) { unit in
                                    Text(unit.title).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    } label: {
                        DialogRowLabel(L10n.text("split.size.label"), systemImage: "square.split.2x1.fill", tint: .orange)
                    }

                    // 预估片数：总大小 / 卷大小,给个直觉,避免「1MB 拆 8GB 文件」这种误操作无感发生。
                    Label(
                        L10n.format("split.estimate", ByteCountFormatter.string(fromByteCount: request.fileSize, countStyle: .file), estimatedPartCount),
                        systemImage: "number.square.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
        }
    }
}
