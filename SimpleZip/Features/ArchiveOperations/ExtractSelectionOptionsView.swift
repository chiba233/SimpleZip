//
//  ExtractSelectionOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 解压选中条目前的选项面板。
struct ExtractSelectionOptionsView: View {
    @State var request: ExtractSelectionRequest
    let extract: (ExtractSelectionRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        ExtractOptionsForm(
            title: L10n.text("extract.selected.title"),
            subtitle: request.archiveURL.lastPathComponent,
            destinationURL: $request.destinationURL,
            password: $request.password,
            zipDecryptionMethod: $request.zipDecryptionMethod,
            showDetails: $request.showDetails,
            // 开了流式快速解压 → 隐藏密码行 + ZIP 解密方式(bsdtar 不支持加密,是它「不支持的选项」)。
            showsZipDecryptionMethod: request.archiveURL.pathExtension.lowercased() == "zip" && !request.useStreamingExtraction,
            showsPassword: !request.useStreamingExtraction,
            zipEncryptionDetectionText: request.detectedZipEncryption.autoDetectionText,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            LabeledContent {
                // 控件钉行最右(解压对话框拍板:选择框/复选框/输入框全部靠最右)。
                Picker("", selection: $request.pathMode) {
                    ForEach(ExtractPathMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
            } label: {
                DialogRowLabel(L10n.text("extract.pathMode"), systemImage: "point.topleft.down.to.point.bottomright.curvepath", tint: .indigo)
            }
            // 0.4.2：不解压 macOS 元数据垃圾 —— 与整包解压同款开关。
            DialogToggleRow(
                title: L10n.text("extract.skipJunk"),
                subtitle: L10n.text("extract.skipJunk.detail"),
                systemImage: "doc.badge.gearshape.fill",
                tint: .teal,
                pinsToTrailing: true,
                isOn: $request.skipJunk
            )
            // 0.4.3 #15：不解压符号链接 —— 与整包解压同款开关。
            DialogToggleRow(
                title: L10n.text("extract.skipSymlinks"),
                subtitle: L10n.text("extract.skipSymlinks.detail"),
                systemImage: "link",
                tint: .orange,
                pinsToTrailing: true,
                isOn: $request.skipSymlinks
            )
            // 流式快速解压(bsdtar 按条目名顺序解压,选条目也能流式):仅支持格式 + 无密码 + 非加密时露出。
            if isStreamingEligible {
                DialogToggleRow(
                    title: L10n.text("extract.streamingZip"),
                    subtitle: L10n.text("extract.streamingZip.detail"),
                    systemImage: "bolt.horizontal.fill",
                    tint: .yellow,
                    pinsToTrailing: true,
                    isOn: $request.useStreamingExtraction
                )
            }
        } drawers: {}
        .frame(width: 560)
        .task {
            // ZIP 加密方法提示:后台异步读 central directory(别在主线程同步读整包卡死网络归档);非 zip 跳过。
            guard request.detectedZipEncryption == .unknown,
                  request.archiveURL.pathExtension.lowercased() == "zip" else { return }
            let url = request.archiveURL
            request.detectedZipEncryption = await Task.detached { ArchiveService.detectZipEncryption(in: url) }.value
        }
    }

    /// 流式快速解压是否可用:zip + tar 家族、无密码、非加密。bsdtar 不支持加密 ZIP;检测中(.unknown)也先露出
    /// —— 真加密会回退,有密码时后端自动跳过。tar 家族无加密概念,detectedZipEncryption 恒 .unknown。
    private var isStreamingEligible: Bool {
        ArchiveService.isStreamingExtractionSupported(request.archiveURL)
            && request.password.isEmpty
            && (request.detectedZipEncryption == .none || request.detectedZipEncryption == .unknown)
    }
}

/// 0.4.2：`.gpg` 解压确认对话框 —— 不能静默解。展示解密产物名 + 可改目标目录，
/// 确认后走任务化解密（活动中心 / 可重跑）。轻量 sheet,套统一弹窗体例。
struct GPGExtractOptionsView: View {
    @State var request: ArchiveBrowserModel.GPGExtractRequest
    let extract: (ArchiveBrowserModel.GPGExtractRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                // "lock.open.doc" 不是合法 SF Symbol(渲染成空白,只有颜色没图标)。
                systemImage: "lock.open.fill",
                colors: [.teal, .blue],
                title: L10n.text("gpgExtract.title"),
                subtitle: request.url.lastPathComponent
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
                    // 解密产物名是不可选择的信息行 —— 保持单色低调。
                    LabeledContent {
                        Text(request.productName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label(L10n.text("gpgExtract.product"), systemImage: "doc")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(request.destinationURL.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button(L10n.text("button.choose")) {
                                chooseDestination()
                            }
                        }
                    } label: {
                        DialogRowLabel(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue)
                    }
                }

                Label(L10n.text("gpgExtract.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("button.extract"),
                confirmSystemImage: "lock.open",
                confirmDisabled: false,
                confirm: { extract(request) },
                cancel: cancel
            ) {
                EmptyView()
            }
        }
        .frame(width: 520)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = request.destinationURL
        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
        }
    }
}

/// 0.4.2：虚拟浏览导出对话框 —— 列出将导出的解密文件 + 可改目标目录（专用绘制,不偷懒用系统面板）。
struct VirtualExportOptionsView: View {
    @State var request: ArchiveBrowserModel.VirtualExportRequest
    let export: (ArchiveBrowserModel.VirtualExportRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "square.and.arrow.down.on.square",
                colors: [.blue, .cyan],
                title: L10n.text("virtual.export.title"),
                subtitle: L10n.format("virtual.export.subtitle", "\(request.files.count)")
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection(L10n.text("virtual.export.filesSection")) {
                    HeightCappedScrollView(maxHeight: 180) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(request.files, id: \.self) { file in
                                Label(file.lastPathComponent, systemImage: "doc")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                DialogSection {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(request.destinationURL.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button(L10n.text("button.choose")) {
                                chooseDestination()
                            }
                        }
                    } label: {
                        DialogRowLabel(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue)
                    }
                }

                Label(L10n.text("virtual.export.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("button.extract"),
                confirmSystemImage: "square.and.arrow.down.on.square",
                confirmDisabled: false,
                confirm: { export(request) },
                cancel: cancel
            ) {
                EmptyView()
            }
        }
        .frame(width: 520)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = request.destinationURL
        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
        }
    }
}
