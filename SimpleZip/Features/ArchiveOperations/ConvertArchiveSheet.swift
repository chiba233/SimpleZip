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
    /// 要转换的源归档（已过滤为支持的归档类型）。var:活动中心「重跑」单项时替换为该源。
    var sourceURLs: [URL]

    /// #14:重跑单项 —— 保留全部选项,只换源列表。
    mutating func replaceSources(_ urls: [URL]) {
        sourceURLs = urls
    }
    /// 目标格式（默认 7z）。
    var targetFormat: ArchiveCreateFormat = .sevenZip
    /// 压缩级别。
    var compressionLevel: CompressionLevel = .normal
    /// 输出归档的可选密码（留空 = 不加密）。
    var password: String = ""
    /// #14:统一输出目录（nil = 各源同目录,既有行为）。
    var outputDirectory: URL? = nil
    /// #14:统一输出目录时,按各源相对公共祖先的目录结构落盘（仅 outputDirectory 非 nil 时有意义）。
    var preserveRelativeStructure = false
    /// #14:目标已有同名归档且**结构指纹一致** → 整项跳过（记 skipped）,不再「名 2」重复转。
    var skipIdenticalExisting = false
    /// #14:失败自动重试一次（清掉半成品再试;取消不重试）。
    var retryOnFailure = true
    /// #14:转换后测试产物（弹面板时按设置「创建后验证」预填;加密输出跳过）。
    var verifyAfterConvert = false
    /// #14:成功（含验证）后把原包移到废纸篓（默认关,可恢复）。
    var trashOriginalWhenDone = false
    /// #14:套用目标格式在「设置 → 压缩 → 默认值」存的预设（密码仍用本面板的;预设启用的字段覆盖级别）。
    var useTargetFormatDefaults = false
}

struct ConvertArchiveSheet: View {
    @State var request: ConvertArchiveRequest
    let confirm: (ConvertArchiveRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        TaskDialogShell(
            heroSystemImage: "arrow.triangle.2.circlepath",
            heroColors: [.purple, .blue],
            title: L10n.text("convert.title"),
            subtitle: L10n.format("convert.subtitle", "\(request.sourceURLs.count)"),
            width: 500,
            confirmTitle: L10n.text("convert.button"),
            confirmSystemImage: "arrow.triangle.2.circlepath",
            confirmDisabled: request.sourceURLs.isEmpty,
            confirm: { confirm(request) },
            cancel: cancel
        ) {
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
                    DialogRowLabel(L10n.text("archive.format"), systemImage: "shippingbox.fill", tint: .brown)
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
                        DialogRowLabel(L10n.text("archive.compressionLevel"), systemImage: "gauge.with.dots.needle.67percent", tint: .green)
                    }
                }

                if request.targetFormat.supportsPassword {
                    LabeledContent {
                        SecureField(L10n.text("convert.password.placeholder"), text: $request.password)
                            .textFieldStyle(.roundedBorder)
                            .dialogFieldEmphasis()
                            .frame(maxWidth: 220)
                    } label: {
                        DialogRowLabel(L10n.text("archive.password"), systemImage: "key.fill", tint: .orange)
                    }
                }

                Label(L10n.text("convert.note"), systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #14:输出与批量选项。
            DialogSection(L10n.text("convert.section.output")) {
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("convert.outputDirectory"), systemImage: "folder.fill", tint: .blue)
                    Spacer(minLength: 12)
                    if let directory = request.outputDirectory {
                        Text(directory.path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button(L10n.text("convert.outputDirectory.reset")) {
                            request.outputDirectory = nil
                            request.preserveRelativeStructure = false
                        }
                    } else {
                        Text(L10n.text("convert.outputDirectory.sameAsSource"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Button(L10n.text("button.choose")) { chooseOutputDirectory() }
                }
                if request.outputDirectory != nil {
                    DialogToggleRow(
                        title: L10n.text("convert.preserveStructure"),
                        subtitle: L10n.text("convert.preserveStructure.detail"),
                        systemImage: "square.grid.3x1.folder.badge.plus",
                        tint: .indigo,
                        pinsToTrailing: true,
                        isOn: $request.preserveRelativeStructure
                    )
                }
                DialogToggleRow(
                    title: L10n.text("convert.skipIdentical"),
                    subtitle: L10n.text("convert.skipIdentical.detail"),
                    systemImage: "equal.circle",
                    tint: .teal,
                    pinsToTrailing: true,
                    isOn: $request.skipIdenticalExisting
                )
                DialogToggleRow(
                    title: L10n.text("convert.retryOnFailure"),
                    subtitle: L10n.text("convert.retryOnFailure.detail"),
                    systemImage: "arrow.clockwise",
                    tint: .orange,
                    pinsToTrailing: true,
                    isOn: $request.retryOnFailure
                )
                DialogToggleRow(
                    title: L10n.text("convert.verifyAfter"),
                    subtitle: L10n.text("convert.verifyAfter.detail"),
                    systemImage: "checkmark.seal",
                    tint: .green,
                    pinsToTrailing: true,
                    isOn: $request.verifyAfterConvert
                )
                DialogToggleRow(
                    title: L10n.text("convert.trashOriginal"),
                    subtitle: L10n.text("convert.trashOriginal.detail"),
                    systemImage: "trash",
                    tint: .red,
                    pinsToTrailing: true,
                    isOn: $request.trashOriginalWhenDone
                )
                if targetFormatHasDefaults {
                    DialogToggleRow(
                        title: L10n.text("convert.useFormatDefaults"),
                        subtitle: L10n.text("convert.useFormatDefaults.detail"),
                        systemImage: "square.3.layers.3d",
                        tint: .purple,
                        pinsToTrailing: true,
                        isOn: $request.useTargetFormatDefaults
                    )
                }
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
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    /// #14:目标格式在「设置 → 压缩 → 默认值」有启用的预设时才显示「套用默认值」开关。
    private var targetFormatHasDefaults: Bool {
        CompressionDefaultsStore().preset(for: request.targetFormat)?.enabled == true
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            request.outputDirectory = url
        }
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
