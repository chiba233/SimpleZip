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
        case megabytes
        case gigabytes

        var id: String { rawValue }
        var title: String { self == .megabytes ? "MB" : "GB" }
        var multiplier: Int64 { self == .megabytes ? 1_000_000 : 1_000_000_000 }
    }

    @State private var sizeValue = 100
    @State private var sizeUnit = SizeUnit.megabytes

    private var volumeSizeBytes: Int64 {
        Int64(max(0, sizeValue)) * sizeUnit.multiplier
    }

    private var estimatedPartCount: Int {
        guard volumeSizeBytes > 0 else { return 0 }
        return max(1, Int((request.fileSize + volumeSizeBytes - 1) / volumeSizeBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("split.title", request.url.lastPathComponent))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Form {
                HStack {
                    Text(L10n.text("split.size.label"))
                    Spacer()
                    TextField("", value: $sizeValue, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $sizeUnit) {
                        ForEach(SizeUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                // 预估片数：总大小 / 卷大小,给个直觉,避免「1MB 拆 8GB 文件」这种误操作无感发生。
                Text(L10n.format("split.estimate", ByteCountFormatter.string(fromByteCount: request.fileSize, countStyle: .file), estimatedPartCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("split.button")) {
                    apply(volumeSizeBytes)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(volumeSizeBytes <= 0)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
