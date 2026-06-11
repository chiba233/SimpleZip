//
//  ConvertArchiveSheet.swift
//  SimpleZip
//
//  #112 批量格式转换的确认 sheet。复用 DialogChrome 体例 + ArchiveCreateFormat 枚举,
//  不另造格式模型。转换引擎在 Core/ArchiveConversion（extract → repack,已实测无单步转换命令）。
//

import AppKit
import SwiftUI

/// 「转换格式」待确认请求。一次可批量转换多个归档（同一目标格式）。
struct ConvertArchiveRequest: Identifiable {
    let id = UUID()
    /// 要转换的源归档（已过滤为支持的归档类型）。
    let sourceURLs: [URL]
    /// 目标格式（默认 7z）。
    var targetFormat: ArchiveCreateFormat = .sevenZip
    /// 压缩级别。
    var compressionLevel: CompressionLevel = .normal
    /// 输出归档的可选密码（留空 = 不加密）。
    var password: String = ""
}

struct ConvertArchiveSheet: View {
    @State var request: ConvertArchiveRequest
    let confirm: (ConvertArchiveRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "arrow.triangle.2.circlepath",
                colors: [.purple, .blue],
                title: L10n.text("convert.title"),
                subtitle: L10n.format("convert.subtitle", "\(request.sourceURLs.count)")
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection(L10n.text("convert.section.target")) {
                        LabeledContent {
                            Picker("", selection: $request.targetFormat) {
                                ForEach(ArchiveCreateFormat.allCases) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            Label(L10n.text("archive.format"), systemImage: "shippingbox.fill")
                        }

                        if request.targetFormat.supportsCompressionLevel {
                            LabeledContent {
                                Picker("", selection: $request.compressionLevel) {
                                    ForEach(CompressionLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            } label: {
                                Label(L10n.text("archive.compressionLevel"), systemImage: "gauge.with.dots.needle.67percent")
                            }
                        }

                        if request.targetFormat.supportsPassword {
                            LabeledContent {
                                SecureField(L10n.text("convert.password.placeholder"), text: $request.password)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)
                            } label: {
                                Label(L10n.text("archive.password"), systemImage: "key.fill")
                            }
                        }

                        Label(L10n.text("convert.note"), systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 0.4.2 #13：保真度报告 —— 目标格式保留 / 丢失哪些语义，选格式时实时切换。
                    DialogSection(L10n.text("convert.section.fidelity")) {
                        fidelityRows(request.targetFormat.conversionFidelity)
                        Label(L10n.text("convert.fidelity.note"), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DialogSection(L10n.text("convert.section.sources")) {
                        ForEach(request.sourceURLs, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "doc.zipper")
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 480)

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("convert.button")) {
                    confirm(request)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(request.sourceURLs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500)
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    /// 六行保真度（✓ 保留 / ✗ 丢失），两列排布省高度。
    @ViewBuilder
    private func fidelityRows(_ fidelity: ConversionFidelity) -> some View {
        let entries: [(String, Bool)] = [
            ("fidelity.permissions", fidelity.preservesPermissions),
            ("fidelity.symlinks", fidelity.preservesSymlinks),
            ("fidelity.dates", fidelity.preservesModificationDates),
            ("fidelity.encryption", fidelity.supportsEncryption),
            ("fidelity.comment", fidelity.supportsArchiveComment),
            ("fidelity.multiVolume", fidelity.supportsMultiVolume)
        ]
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
            ForEach(entries, id: \.0) { entry in
                Label {
                    Text(L10n.text(entry.0))
                } icon: {
                    Image(systemName: entry.1 ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(entry.1 ? Color.green : Color.secondary)
                }
                .font(.callout)
            }
        }
    }
}
