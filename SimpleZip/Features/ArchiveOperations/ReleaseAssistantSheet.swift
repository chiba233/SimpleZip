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

    /// #18:命名工作区预设(整套发布配置一把存取;store 在 Core,随设置备份)。
    @State private var workspacePresets: [ReleaseWorkspacePreset] = ReleaseWorkspacePresetStore().loadAll()

    private var canConfirm: Bool {
        request.sourceFolder != nil
            && request.destinationFolder != nil
            && !request.fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var showsGPGRow: Bool {
        AppPreferences.gpgEnabled && GPGBackend.isAvailable()
    }

    // MARK: - #18 工作区预设

    /// 套用:路径仅在目录仍存在时回填(项目挪走了就留空让用户重挑,不瞎填死路径)。
    private func apply(_ preset: ReleaseWorkspacePreset) {
        func existingDirectory(_ path: String?) -> URL? {
            guard let path else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
        request.sourceFolder = existingDirectory(preset.sourceFolderPath)
        request.destinationFolder = existingDirectory(preset.destinationFolderPath)
        request.fileName = preset.fileName
        if let format = ArchiveCreateFormat(rawValue: preset.formatRawValue),
           format == .zip || format == .sevenZip {
            request.format = format
        }
        request.excludeJunk = preset.excludeJunk
        request.reproducible = preset.reproducible
        request.runInspection = preset.runInspection
        request.writeChecksums = preset.writeChecksums
        request.createSignedManifest = preset.createSignedManifest && showsGPGRow
    }

    /// 保存当前配置为命名预设(同名覆盖)。NSAlert + TextField,与「保存搜索过滤器」同一体例。
    private func promptSaveWorkspacePreset() {
        let alert = NSAlert()
        alert.messageText = L10n.text("releaseAssistant.workspace.savePrompt.title")
        alert.informativeText = L10n.text("releaseAssistant.workspace.savePrompt.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = request.sourceFolder?.lastPathComponent ?? request.fileName
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("button.save"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = ReleaseWorkspacePreset(
            name: name,
            sourceFolderPath: request.sourceFolder?.path,
            fileName: request.fileName,
            formatRawValue: request.format.rawValue,
            destinationFolderPath: request.destinationFolder?.path,
            excludeJunk: request.excludeJunk,
            reproducible: request.reproducible,
            runInspection: request.runInspection,
            writeChecksums: request.writeChecksums,
            createSignedManifest: request.createSignedManifest
        )
        ReleaseWorkspacePresetStore().save(preset)
        workspacePresets = ReleaseWorkspacePresetStore().loadAll()
    }

    var body: some View {
        TaskDialogShell(
            heroSystemImage: "shippingbox.and.arrow.backward.fill",
            heroColors: [.teal, .green],
            title: L10n.text("releaseAssistant.title"),
            subtitle: L10n.text("releaseAssistant.subtitle"),
            confirmTitle: L10n.text("releaseAssistant.start"),
            confirmSystemImage: "shippingbox.and.arrow.backward",
            confirmDisabled: !canConfirm,
            confirm: { confirm(request) },
            cancel: cancel
        ) {
            // #18:工作区预设 —— 与创建对话框「套用模板」同款形态:套用 / 保存当前 / 删除。
            HStack {
                Menu {
                    ForEach(workspacePresets) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                    if !workspacePresets.isEmpty {
                        Divider()
                        Menu(L10n.text("releaseAssistant.workspace.delete")) {
                            ForEach(workspacePresets) { preset in
                                Button(preset.name) {
                                    ReleaseWorkspacePresetStore().delete(id: preset.id)
                                    workspacePresets = ReleaseWorkspacePresetStore().loadAll()
                                }
                            }
                        }
                    }
                    Divider()
                    Button(L10n.text("releaseAssistant.workspace.save")) { promptSaveWorkspacePreset() }
                } label: {
                    Label(L10n.text("releaseAssistant.workspace.menu"), systemImage: "square.stack.3d.up")
                }
                .fixedSize()
                Spacer()
            }

            DialogSection(L10n.text("releaseAssistant.section.source")) {
                // 值一侧全部顶到右缘(用户点名):label + Spacer + 值,与解压家族同款。
                // LabeledContent 在普通 VStack 里只按自然宽度排,右缘会参差。
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("releaseAssistant.sourceFolder"), systemImage: "hammer.fill", tint: .orange)
                    Spacer(minLength: 12)
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
                }

                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("archive.fileName"), systemImage: "shippingbox.fill", tint: .brown)
                    Spacer(minLength: 12)
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

                HStack(alignment: .center, spacing: 12) {
                    // 与创建对话框「保存到」同键同图标同色(同类同色)。
                    DialogRowLabel(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue)
                    Spacer(minLength: 12)
                    folderPicker(
                        selection: $request.destinationFolder,
                        prompt: L10n.text("releaseAssistant.chooseDestination")
                    ) { _ in }
                }
            }

            DialogSection(L10n.text("releaseAssistant.section.steps")) {
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.excludeJunk"),
                    subtitle: L10n.text("releaseAssistant.excludeJunk.subtitle"),
                    systemImage: "paintbrush.fill", tint: .pink,
                    pinsToTrailing: true,
                    isOn: $request.excludeJunk
                )
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.reproducible"),
                    subtitle: L10n.text("releaseAssistant.reproducible.subtitle"),
                    systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .purple,
                    pinsToTrailing: true,
                    isOn: $request.reproducible
                )
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.inspect"),
                    subtitle: L10n.text("releaseAssistant.inspect.subtitle"),
                    systemImage: "checklist", tint: .teal,
                    pinsToTrailing: true,
                    isOn: $request.runInspection
                )
            }

            // #18 一级密度治理:伴生产物(SHA256SUMS / .szs 签名)收进普通抽屉,子行单色;
            // 打包行为三开关(排垃圾/可复现/发布检查)是本对话框的灵魂,留一级。
            DialogDrawer(L10n.text("releaseAssistant.section.outputs"), systemImage: "square.and.arrow.down", color: .orange) {
                drawerToggle("releaseAssistant.checksums", subtitleKey: "releaseAssistant.checksums.subtitle", systemImage: "number.square", isOn: $request.writeChecksums)
                if showsGPGRow {
                    drawerToggle("releaseAssistant.sign", subtitleKey: "releaseAssistant.sign.subtitle", systemImage: "signature", isOn: $request.createSignedManifest)
                }
            }
        }
    }

    /// #18 抽屉子行:单色 Label + 紧贴开关 + caption 说明(解压/转换对话框同款)。
    private func drawerToggle(_ titleKey: String, subtitleKey: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L10n.text(titleKey), systemImage: systemImage)
                Toggle("", isOn: isOn)
                    .labelsHidden()
            }
            Text(L10n.text(subtitleKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
