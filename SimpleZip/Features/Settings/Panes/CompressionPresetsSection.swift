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

    @State private var presets: [CompressionFormatPreset] = []
    @State private var editorTarget: FormatPresetEditorTarget?

    /// 可添加的格式（压缩相关；DMG 是挂载不在内）。
    private let allFormats: [ArchiveCreateFormat] = [.zip, .sevenZip, .rar, .tar, .tarGzip, .gzip, .bzip2, .xz]

    var body: some View {
        Section(L10n.text("settings.defaults.title")) {
            Text(L10n.text("settings.defaults.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 只列出**用户已添加**的格式模板；每条一个启用开关。没添加的不显示。
            // 注意：不要在行间插 Divider() —— 在 Form/Section 里它会单独占一整行(显示成空灰行)，
            // 行间分隔线 Form 已自带。
            ForEach(presets) { preset in
                formatRow(preset)
            }

            let available = allFormats.filter { format in !presets.contains { $0.format == format } }
            if !available.isEmpty {
                Menu {
                    ForEach(available) { format in
                        Button(format.title) {
                            // 添加即弹编辑器：在 sheet 里配置完点保存才真正加进列表（取消则不加）。
                            editorTarget = FormatPresetEditorTarget(preset: CompressionFormatPreset(format: format))
                        }
                    }
                } label: {
                    Label(L10n.text("settings.defaults.add"), systemImage: "plus")
                }
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

    /// 已添加的一行：左边开关（启用 / 停用本模板），名字 + 摘要，右边编辑 / 删除。
    private func formatRow(_ preset: CompressionFormatPreset) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.format.title)
                Text(summary(preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.text("settings.presets.edit")) {
                editorTarget = FormatPresetEditorTarget(preset: preset)
            }
            .buttonStyle(.borderless)
            Button {
                store.reset(for: preset.format)
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("file.delete"))

            // 启用开关放最右 —— macOS 设置项开关的惯例位置。
            Toggle("", isOn: Binding(
                get: { preset.enabled },
                set: { on in
                    var updated = preset
                    updated.enabled = on
                    store.save(updated)
                    reload()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        presets = store.allPresets()
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
                        }.labelsHidden()
                    }
                }
                if format.supportsUpdateMode {
                    row(.updateMode, L10n.text("archive.updateMode")) {
                        Picker("", selection: $options.updateMode) {
                            ForEach(ArchiveUpdateMode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                }
                if format == .zip {
                    row(.encryptionMethod, L10n.text("archive.encryptionMethod")) {
                        Picker("", selection: $options.encryptionMethod) {
                            ForEach(ArchiveEncryptionMethod.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                }
                if format == .sevenZip {
                    row(.sevenZipMethod, L10n.text("archive.7z.method")) {
                        Picker("", selection: $options.sevenZipMethod) {
                            ForEach(SevenZipCompressionMethod.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    row(.dictionarySize, L10n.text("archive.7z.dictionarySize")) {
                        Picker("", selection: $options.sevenZipDictionarySizeMB) {
                            ForEach(dictionarySizeOptions, id: \.self) { Text("\($0) MB").tag($0) }
                        }.labelsHidden()
                    }
                    row(.wordSize, L10n.text("archive.7z.wordSize")) {
                        Picker("", selection: $options.sevenZipWordSize) {
                            ForEach(wordSizeOptions, id: \.self) { Text("\($0)").tag($0) }
                        }.labelsHidden()
                    }
                    row(.threadCount, L10n.text("archive.7z.threads")) {
                        HStack(spacing: 6) {
                            Text(options.sevenZipThreadCount == 0 ? L10n.text("archive.7z.method.automatic") : "\(options.sevenZipThreadCount)")
                                .foregroundStyle(.secondary)
                            Stepper("", value: $options.sevenZipThreadCount, in: 0...maxThreadCount)
                                .labelsHidden()
                        }
                    }
                    row(.solid, L10n.text("archive.7z.solid")) {
                        Toggle("", isOn: $options.sevenZipSolidArchive).labelsHidden()
                    }
                    row(.solidBlockSize, L10n.text("archive.7z.solidBlockSize")) {
                        Picker("", selection: $options.sevenZipSolidBlockSize) {
                            ForEach(SevenZipSolidBlockSize.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
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
                        }.labelsHidden()
                    }
                }
                if format == .sevenZip || format == .rar {
                    row(.encryptFileNames, L10n.text("archive.7z.encryptFileNames")) {
                        Toggle("", isOn: $options.sevenZipEncryptFileNames).labelsHidden()
                    }
                }
                if format.supportsRawParameters {
                    row(.rawParameters, L10n.text("archive.parameters")) {
                        TextField("", text: $options.rawParameters)
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
        // 高度跟随选项行数,但封顶 620 —— 选项少不留大空白,选项多(7z)也不会超出屏幕(超了 Form 内部滚动)。
        .frame(width: 480, height: min(estimatedHeight, 620))
    }

    /// 按当前格式实际显示的选项行数估算内容高度。
    private var estimatedHeight: CGFloat {
        var rows = 0
        if format.supportsCompressionLevel { rows += 1 }
        if format.supportsUpdateMode { rows += 1 }
        if format == .zip { rows += 1 }                                  // 加密方式
        if format == .sevenZip { rows += 9 }                             // 方法/字典/字/线程/固实/固实块/符号/硬链/共享
        if format == .sevenZip || format.supportsUpdateMode { rows += 1 } // 路径模式
        if format == .sevenZip || format == .rar { rows += 1 }           // 加密文件名
        if format.supportsRawParameters { rows += 1 }                    // 参数
        if format.supportsExcludeRules { rows += 2 }                     // 跳过 .DS_Store / 隐藏文件
        return CGFloat(96 + rows * 40 + 70)   // 标题+提示 + 每行 + 分隔线+按钮
    }

    /// 一行：左边「启用」勾选，右边值控件（没勾时禁用 + 变淡）。
    @ViewBuilder
    private func row(_ field: CompressionOptionField, _ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack {
            Toggle(label, isOn: includeBinding(field))
                .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            control()
                .frame(width: 190, alignment: .trailing)   // 统一列宽 + 右对齐 → 右边缘齐
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
