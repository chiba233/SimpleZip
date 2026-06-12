//
//  ReleaseAssistantSheet.swift
//  SimpleZip
//
//  发布助手:选产物目录 → 打包(可排垃圾、可复现) → 发布检查 → SHA256SUMS → 可选签名清单,
//  一条流。每一步都是现成能力(创建选项 / ReleaseInspection / ChecksumFile / CreateSZSSheet),
//  这里只是把它们按发布工作流串起来 —— 不造平行引擎。执行管线在
//  ArchiveBrowserModel.runReleaseAssistant(_:),走 startManagedArchiveTask(活动中心可见、可取消)。
//

import AppKit
import SwiftUI

/// 发布助手的待确认配置。`sourceFolder` 是要打包的产物目录;归档落在 `destinationFolder` 下
/// (默认产物目录的父目录),重名自动唯一化,绝不覆盖。
struct ReleaseAssistantRequest: Identifiable {
    let id = UUID()
    var sourceFolder: URL?
    var fileName: String = ""
    /// 仅 zip / 7z —— 可复现压缩只有这两个格式支持(tar 家族走系统 tar 没有时间戳钳制)。
    var format: ArchiveCreateFormat = .zip
    var destinationFolder: URL?
    var excludeJunk = true
    var reproducible = true
    var runInspection = true
    var writeChecksums = true
    /// 完成后用现有「创建签名清单」sheet 继续签 `.szs`(A4:GPG 主开关关闭时该行不渲染)。
    var createSignedManifest = false
}

struct ReleaseAssistantSheet: View {
    @State var request: ReleaseAssistantRequest
    let confirm: (ReleaseAssistantRequest) -> Void
    let cancel: () -> Void

    private var canConfirm: Bool {
        request.sourceFolder != nil
            && request.destinationFolder != nil
            && !request.fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var showsGPGRow: Bool {
        AppPreferences.gpgEnabled && GPGBackend.isAvailable()
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "shippingbox.and.arrow.backward.fill",
                colors: [.teal, .green],
                title: L10n.text("releaseAssistant.title"),
                subtitle: L10n.text("releaseAssistant.subtitle")
            )

            HeightCappedScrollView(maxHeight: 480) {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection(L10n.text("releaseAssistant.section.source")) {
                        LabeledContent {
                            folderPicker(
                                selection: $request.sourceFolder,
                                prompt: L10n.text("releaseAssistant.chooseSource")
                            ) { chosen in
                                // 选完产物目录顺手把空着的文件名 / 输出目录补全 —— 已手改过的不动。
                                if request.fileName.trimmingCharacters(in: .whitespaces).isEmpty {
                                    request.fileName = chosen.lastPathComponent
                                }
                                if request.destinationFolder == nil {
                                    request.destinationFolder = chosen.deletingLastPathComponent()
                                }
                            }
                        } label: {
                            DialogRowLabel(L10n.text("releaseAssistant.sourceFolder"), systemImage: "folder.fill", tint: .blue)
                        }

                        LabeledContent {
                            HStack(spacing: 8) {
                                TextField("", text: $request.fileName)
                                    .textFieldStyle(.roundedBorder)
                                    .dialogFieldEmphasis()
                                    .frame(maxWidth: 200)
                                Picker("", selection: $request.format) {
                                    ForEach([ArchiveCreateFormat.zip, .sevenZip]) { format in
                                        Text(format.title).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        } label: {
                            DialogRowLabel(L10n.text("archive.fileName"), systemImage: "shippingbox.fill", tint: .brown)
                        }

                        LabeledContent {
                            folderPicker(
                                selection: $request.destinationFolder,
                                prompt: L10n.text("releaseAssistant.chooseDestination")
                            ) { _ in }
                        } label: {
                            DialogRowLabel(L10n.text("archive.saveTo"), systemImage: "tray.and.arrow.down.fill", tint: .indigo)
                        }
                    }

                    DialogSection(L10n.text("releaseAssistant.section.steps")) {
                        DialogToggleRow(
                            title: L10n.text("releaseAssistant.excludeJunk"),
                            subtitle: L10n.text("releaseAssistant.excludeJunk.subtitle"),
                            systemImage: "paintbrush.fill", tint: .pink,
                            isOn: $request.excludeJunk
                        )
                        DialogToggleRow(
                            title: L10n.text("releaseAssistant.reproducible"),
                            subtitle: L10n.text("releaseAssistant.reproducible.subtitle"),
                            systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .purple,
                            isOn: $request.reproducible
                        )
                        DialogToggleRow(
                            title: L10n.text("releaseAssistant.inspect"),
                            subtitle: L10n.text("releaseAssistant.inspect.subtitle"),
                            systemImage: "checklist", tint: .teal,
                            isOn: $request.runInspection
                        )
                        DialogToggleRow(
                            title: L10n.text("releaseAssistant.checksums"),
                            subtitle: L10n.text("releaseAssistant.checksums.subtitle"),
                            systemImage: "number.square.fill", tint: .orange,
                            isOn: $request.writeChecksums
                        )
                        if showsGPGRow {
                            DialogToggleRow(
                                title: L10n.text("releaseAssistant.sign"),
                                subtitle: L10n.text("releaseAssistant.sign.subtitle"),
                                systemImage: "signature", tint: .green,
                                isOn: $request.createSignedManifest
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    confirm(request)
                } label: {
                    Label(L10n.text("releaseAssistant.start"), systemImage: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    /// 文件夹选择行:当前选择(可中截断)+「选择…」按钮。
    private func folderPicker(
        selection: Binding<URL?>,
        prompt: String,
        onChoose: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(selection.wrappedValue?.path ?? prompt)
                .font(.callout)
                .foregroundStyle(selection.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if let current = selection.wrappedValue {
                    panel.directoryURL = current
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                selection.wrappedValue = url
                onChoose(url)
            } label: {
                Label(L10n.text("button.choose"), systemImage: "folder")
            }
        }
    }
}
