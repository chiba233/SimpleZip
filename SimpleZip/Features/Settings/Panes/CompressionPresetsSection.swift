//
//  CompressionPresetsSection.swift
//  SimpleZip
//
//  #115 压缩预设 GUI —— 设置 → 压缩 → 默认值。
//  列出 / 增删 / 编辑命名预设，并指定一个「默认预设」：Finder / NSService 一键「简化压缩」会自动套用它的
//  可复用设置（等级 / 方法 / solid 等；密码 / GPG 私钥不随预设走 —— 见 CompressionPreset.sanitized()）。
//  纯 UI；持久化全交给 Core 的 CompressionPresetStore。
//

import SwiftUI

/// 压缩预设管理区（嵌进 ArchivePane 的一个 Section）。
struct CompressionPresetsSection: View {
    private let store = CompressionPresetStore()

    @State private var presets: [CompressionPreset] = []
    @State private var defaultID: UUID?
    /// 非 nil = 正在编辑 / 新建（弹编辑 sheet）。
    @State private var editorTarget: PresetEditorTarget?

    var body: some View {
        Section(L10n.text("settings.presets.title")) {
            Text(L10n.text("settings.presets.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if presets.isEmpty {
                Text(L10n.text("settings.presets.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(presets) { preset in
                    presetRow(preset)
                    if preset.id != presets.last?.id { Divider() }
                }
            }

            Button {
                editorTarget = PresetEditorTarget(preset: CompressionPreset(name: "", options: ArchiveCreationOptions()), isNew: true)
            } label: {
                Label(L10n.text("settings.presets.add"), systemImage: "plus")
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editorTarget) { target in
            CompressionPresetEditorSheet(preset: target.preset, isNew: target.isNew) { saved in
                if target.isNew {
                    store.add(saved)
                } else {
                    store.update(saved)
                }
                editorTarget = nil
                reload()
            } onCancel: {
                editorTarget = nil
            }
        }
    }

    private func presetRow(_ preset: CompressionPreset) -> some View {
        HStack(spacing: 10) {
            // 设为默认（单选）：点圆点切换。默认预设 = Finder 一键简化压缩用的那个。
            Button {
                store.setDefaultPresetID(preset.id)
                reload()
            } label: {
                Image(systemName: defaultID == preset.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(defaultID == preset.id ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("settings.presets.makeDefault"))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(preset.name.isEmpty ? L10n.text("settings.presets.unnamed") : preset.name)
                    if defaultID == preset.id {
                        Text(L10n.text("settings.presets.default"))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
                Text(summary(preset.options))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.text("settings.presets.edit")) {
                editorTarget = PresetEditorTarget(preset: preset, isNew: false)
            }
            .buttonStyle(.borderless)

            Button {
                store.remove(id: preset.id)
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("file.delete"))
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        presets = store.load()
        defaultID = store.defaultPresetID()
    }

    /// 一行摘要：格式 · 等级（· 7z 方法）。
    private func summary(_ options: ArchiveCreationOptions) -> String {
        var parts: [String] = [options.format.title]
        if options.format.supportsCompressionLevel {
            parts.append(options.compressionLevel.title)
        }
        if options.format == .sevenZip, options.sevenZipMethod != .automatic {
            parts.append(options.sevenZipMethod.title)
        }
        return parts.joined(separator: " · ")
    }
}

/// sheet(item:) 需要 Identifiable 的载荷：包住「在编辑哪个预设 + 是否新建」。
private struct PresetEditorTarget: Identifiable {
    let id = UUID()
    var preset: CompressionPreset
    let isNew: Bool
}

/// 预设编辑表单：名称 + 格式 + 随格式自适应的等级 / 7z 方法 / solid。
/// 密码 / GPG 这类逐次操作字段**不在预设里编辑**（存储时也会被 sanitized 抹掉）。
struct CompressionPresetEditorSheet: View {
    @State private var name: String
    @State private var options: ArchiveCreationOptions
    let isNew: Bool
    let onSave: (CompressionPreset) -> Void
    let onCancel: () -> Void

    private let presetID: UUID

    /// 预设可选的格式（压缩相关；排除 DMG 挂载 / RAR 创建需外部工具）。
    private let selectableFormats: [ArchiveCreateFormat] = [.zip, .sevenZip, .tar, .tarGzip, .gzip, .bzip2, .xz]

    init(preset: CompressionPreset, isNew: Bool, onSave: @escaping (CompressionPreset) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: preset.name)
        _options = State(initialValue: preset.options)
        self.presetID = preset.id
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? L10n.text("settings.presets.editor.titleNew") : L10n.text("settings.presets.editor.titleEdit"))
                .font(.headline)
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 10)

            Form {
                Section {
                    TextField(L10n.text("settings.presets.editor.name"), text: $name)

                    Picker(L10n.text("settings.presets.editor.format"), selection: $options.format) {
                        ForEach(selectableFormats) { format in
                            Text(format.title).tag(format)
                        }
                    }

                    if options.format.supportsCompressionLevel {
                        Picker(L10n.text("settings.presets.editor.level"), selection: $options.compressionLevel) {
                            ForEach(CompressionLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                    }

                    // 7z 专属：方法 + 固实。其它格式不显示（格式自适应）。
                    if options.format == .sevenZip {
                        Picker(L10n.text("settings.presets.editor.method"), selection: $options.sevenZipMethod) {
                            ForEach(SevenZipCompressionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        Toggle(L10n.text("settings.presets.editor.solid"), isOn: $options.sevenZipSolidArchive)
                    }
                } footer: {
                    Text(L10n.text("settings.presets.editor.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("button.save")) {
                    var clean = options
                    clean.format = options.format
                    onSave(CompressionPreset(id: presetID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), options: clean))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 460, height: 380)
    }
}
