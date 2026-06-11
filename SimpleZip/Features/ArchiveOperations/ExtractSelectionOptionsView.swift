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
            showsZipDecryptionMethod: request.archiveURL.pathExtension.lowercased() == "zip",
            zipEncryptionDetectionText: request.detectedZipEncryption.autoDetectionText,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            Picker(L10n.text("extract.pathMode"), selection: $request.pathMode) {
                ForEach(ExtractPathMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            // 0.4.2：不解压 macOS 元数据垃圾 —— 与整包解压同款开关。
            Toggle(isOn: $request.skipJunk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("extract.skipJunk"))
                    Text(L10n.text("extract.skipJunk.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 0.4.3 #15：不解压符号链接 —— 与整包解压同款开关。
            Toggle(isOn: $request.skipSymlinks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("extract.skipSymlinks"))
                    Text(L10n.text("extract.skipSymlinks.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 560)
    }
}

/// 0.4.2：`.gpg` 解压确认对话框 —— 用户点名「不能静默解」。展示解密产物名 + 可改目标目录，
/// 确认后走任务化解密（活动中心 / 可重跑）。轻量 sheet,套统一弹窗体例。
struct GPGExtractOptionsView: View {
    @State var request: ArchiveBrowserModel.GPGExtractRequest
    let extract: (ArchiveBrowserModel.GPGExtractRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                // "lock.open.doc" 不是合法 SF Symbol(渲染成空白,用户报"只有颜色没图标")。
                systemImage: "lock.open.fill",
                colors: [.teal, .blue],
                title: L10n.text("gpgExtract.title"),
                subtitle: request.url.lastPathComponent
            )

            VStack(alignment: .leading, spacing: 16) {
                DialogSection {
                    LabeledContent {
                        Text(request.productName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label(L10n.text("gpgExtract.product"), systemImage: "doc")
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
                        Label(L10n.text("archive.destination"), systemImage: "folder")
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
                        Label(L10n.text("archive.destination"), systemImage: "folder")
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
