//
//  CompressionPresetsSection.swift
//  SimpleZip
//
//  #115 设置 → 压缩 → 默认值：**按格式**的默认压缩设置。每个格式（zip / 7z / rar / tar.gz …）最多一份预设。
//  列表 + 添加（选格式）+ 编辑 sheet。编辑器里每个选项前面有「启用」勾选 —— **不勾就不进预设**，创建 /
//  一键压缩时该项保持内建默认（「可以选择不配置某个选项」）。持久化交给 Core 的 CompressionDefaultsStore。
//

import SwiftUI

struct CompressionDefaultsSection: View {
    private let store = CompressionDefaultsStore()

    @State private var presetsByFormat: [ArchiveCreateFormat: CompressionFormatPreset] = [:]
    @State private var editorTarget: FormatPresetEditorTarget?

    /// 可配默认值的格式（压缩相关；DMG 是挂载不在内）。每个格式一行 + 自己的开关。
    private let allFormats: [ArchiveCreateFormat] = [.zip, .sevenZip, .rar, .tar, .tarGzip, .gzip, .bzip2, .xz]

    var body: some View {
        Section(L10n.text("settings.defaults.title")) {
            Text(L10n.text("settings.defaults.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(allFormats) { format in
                formatRow(format)
                if format != allFormats.last { Divider() }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editorTarget) { target in
            FormatPresetEditorSheet(preset: target.preset) { saved in
                store.save(saved)
                editorTarget = nil
                reload()
            } onCancel: {
                editorTarget = nil
            }
        }
    }

    /// 每个格式一行：左边「启用」开关，启用后右边出「编辑」。
    private func formatRow(_ format: ArchiveCreateFormat) -> some View {
        let preset = presetsByFormat[format]
        let isEnabled = preset != nil
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { presetsByFormat[format] != nil },
                set: { on in
                    if on {
                        store.save(CompressionFormatPreset(format: format))
                    } else {
                        store.reset(for: format)
                    }
                    reload()
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.title)
                    if let preset {
                        Text(summary(preset))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isEnabled {
                Button(L10n.text("settings.presets.edit")) {
                    editorTarget = FormatPresetEditorTarget(preset: preset ?? CompressionFormatPreset(format: format))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        presetsByFormat = store.loadAll()
    }

    private func summary(_ preset: CompressionFormatPreset) -> String {
        if preset.includedFields.isEmpty {
            return L10n.text("settings.defaults.noOptions")
        }
        return L10n.format("settings.defaults.optionCount", "\(preset.includedFields.count)")
    }
}

/// sheet(item:) 载荷。
private struct FormatPresetEditorTarget: Identifiable {
    let id = UUID()
    var preset: CompressionFormatPreset
}

/// 某格式的默认值编辑器：每个适用选项前面一个「启用」勾选，勾上才配置 + 进预设。
struct FormatPresetEditorSheet: View {
    private let format: ArchiveCreateFormat
    @State private var included: Set<CompressionOptionField>
    @State private var options: ArchiveCreationOptions
    let onSave: (CompressionFormatPreset) -> Void
    let onCancel: () -> Void

    private let dictionarySizeOptions = [1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    private let wordSizeOptions = [16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    private var maxThreadCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    init(preset: CompressionFormatPreset, onSave: @escaping (CompressionFormatPreset) -> Void, onCancel: @escaping () -> Void) {
        self.format = preset.format
        _included = State(initialValue: preset.includedFields)
        _options = State(initialValue: preset.options)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.format("settings.defaults.editorTitle", format.title))
                .font(.headline)
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 4)
            Text(L10n.text("settings.defaults.editorHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            Form {
                if format.supportsCompressionLevel {
                    row(.level, L10n.text("archive.compressionLevel")) {
                        Picker("", selection: $options.compressionLevel) {
                            ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 130)
                    }
                }
                if format.supportsUpdateMode {
                    row(.updateMode, L10n.text("archive.updateMode")) {
                        Picker("", selection: $options.updateMode) {
                            ForEach(ArchiveUpdateMode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 160)
                    }
                }
                if format == .zip {
                    row(.encryptionMethod, L10n.text("archive.encryptionMethod")) {
                        Picker("", selection: $options.encryptionMethod) {
                            ForEach(ArchiveEncryptionMethod.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 160)
                    }
                }
                if format == .sevenZip {
                    row(.sevenZipMethod, L10n.text("archive.7z.method")) {
                        Picker("", selection: $options.sevenZipMethod) {
                            ForEach(SevenZipCompressionMethod.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 130)
                    }
                    row(.dictionarySize, L10n.text("archive.7z.dictionarySize")) {
                        Picker("", selection: $options.sevenZipDictionarySizeMB) {
                            ForEach(dictionarySizeOptions, id: \.self) { Text("\($0) MB").tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    row(.wordSize, L10n.text("archive.7z.wordSize")) {
                        Picker("", selection: $options.sevenZipWordSize) {
                            ForEach(wordSizeOptions, id: \.self) { Text("\($0)").tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                    row(.threadCount, L10n.text("archive.7z.threads")) {
                        Stepper(value: $options.sevenZipThreadCount, in: 0...maxThreadCount) {
                            Text(options.sevenZipThreadCount == 0 ? L10n.text("archive.7z.method.automatic") : "\(options.sevenZipThreadCount)")
                                .foregroundStyle(.secondary)
                        }.fixedSize()
                    }
                    row(.solid, L10n.text("archive.7z.solid")) {
                        Toggle("", isOn: $options.sevenZipSolidArchive).labelsHidden()
                    }
                    row(.solidBlockSize, L10n.text("archive.7z.solidBlockSize")) {
                        Picker("", selection: $options.sevenZipSolidBlockSize) {
                            ForEach(SevenZipSolidBlockSize.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    row(.storeSymlinks, L10n.text("archive.7z.storeSymbolicLinks")) {
                        Toggle("", isOn: $options.sevenZipStoreSymbolicLinks).labelsHidden()
                    }
                    row(.storeHardlinks, L10n.text("archive.7z.storeHardLinks")) {
                        Toggle("", isOn: $options.sevenZipStoreHardLinks).labelsHidden()
                    }
                    row(.compressShared, L10n.text("archive.7z.compressSharedFiles")) {
                        Toggle("", isOn: $options.sevenZipCompressSharedFiles).labelsHidden()
                    }
                }
                if format == .sevenZip || format.supportsUpdateMode {
                    row(.pathMode, L10n.text("archive.7z.pathMode")) {
                        Picker("", selection: $options.sevenZipPathMode) {
                            ForEach(SevenZipPathMode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 140)
                    }
                }
                if format == .sevenZip || format == .rar {
                    row(.encryptFileNames, L10n.text("archive.7z.encryptFileNames")) {
                        Toggle("", isOn: $options.sevenZipEncryptFileNames).labelsHidden()
                    }
                }
                if format.supportsRawParameters {
                    row(.rawParameters, L10n.text("archive.parameters")) {
                        TextField("", text: $options.rawParameters).frame(width: 160)
                    }
                }
                if format.supportsExcludeRules {
                    row(.skipDSStore, L10n.text("archive.skipDSStore")) {
                        Toggle("", isOn: $options.skipDSStore).labelsHidden()
                    }
                    row(.skipHiddenFiles, L10n.text("archive.skipHiddenFiles")) {
                        Toggle("", isOn: $options.skipHiddenFiles).labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("button.save")) {
                    onSave(CompressionFormatPreset(format: format, includedFields: included, options: options))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 480, height: 520)
    }

    /// 一行：左边「启用」勾选，右边值控件（没勾时禁用 + 变淡）。
    @ViewBuilder
    private func row(_ field: CompressionOptionField, _ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack {
            Toggle(label, isOn: includeBinding(field))
                .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            control()
                .disabled(!included.contains(field))
                .opacity(included.contains(field) ? 1 : 0.35)
        }
    }

    private func includeBinding(_ field: CompressionOptionField) -> Binding<Bool> {
        Binding(
            get: { included.contains(field) },
            set: { on in
                if on { included.insert(field) } else { included.remove(field) }
            }
        )
    }
}
