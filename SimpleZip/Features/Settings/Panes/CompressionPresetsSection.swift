//
//  CompressionPresetsSection.swift
//  SimpleZip
//
//  #115（重做）设置 → 压缩 → 默认值：**按格式**配一份完整的可复用压缩选项。
//  每个格式（zip / 7z / rar / tar.gz …）最多一份默认值，开关控制「这个格式要不要配默认值」。
//  这是**新写的设置 UI**（不复用创建对话框）；持久化交给 Core 的 CompressionDefaultsStore。
//  Finder / NSService 一键压缩按目标格式取它；创建对话框可勾选「使用本格式默认值」消费它。
//

import SwiftUI

struct CompressionDefaultsSection: View {
    private let store = CompressionDefaultsStore()

    /// 当前正在编辑哪个格式的默认值。
    @State private var format: ArchiveCreateFormat = .zip
    /// 这个格式是否启用了默认值（= store 里有没有这一份）。
    @State private var enabled = false
    /// 编辑中的整套选项（启用时绑定到各控件，变化即存）。
    @State private var options = ArchiveCreationOptions()

    /// 可配默认值的格式（压缩相关；DMG 是挂载不在内）。
    private let selectableFormats: [ArchiveCreateFormat] = [.zip, .sevenZip, .rar, .tar, .tarGzip, .gzip, .bzip2, .xz]
    private let dictionarySizeOptions = [1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    private let wordSizeOptions = [16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    private var maxThreadCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    var body: some View {
        Section(L10n.text("settings.defaults.title")) {
            Text(L10n.text("settings.defaults.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.text("settings.defaults.format"), selection: $format) {
                ForEach(selectableFormats) { format in
                    Text(format.title).tag(format)
                }
            }
            .onChange(of: format) { _ in loadForCurrentFormat() }

            Toggle(L10n.text("settings.defaults.enable"), isOn: $enabled)
                .onChange(of: enabled) { on in
                    if on {
                        options.format = format
                        store.setOptions(options, for: format)
                    } else {
                        store.reset(for: format)
                    }
                }

            if enabled {
                optionControls
                    // 任何选项变化即存（已 sanitize；不含密码 / GPG）。
                    .onChange(of: options) { _ in
                        store.setOptions(options, for: format)
                    }
            }
        }
        .onAppear(perform: loadForCurrentFormat)
    }

    /// 全套可复用选项 —— 按格式自适应显示。逐次操作字段（密码 / GPG / 删除源文件）**不在默认值里**。
    @ViewBuilder private var optionControls: some View {
        if format.supportsCompressionLevel {
            Picker(L10n.text("archive.compressionLevel"), selection: $options.compressionLevel) {
                ForEach(CompressionLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
        }

        if format.supportsUpdateMode {
            Picker(L10n.text("archive.updateMode"), selection: $options.updateMode) {
                ForEach(ArchiveUpdateMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }

        // ZIP 加密算法（AES-256 / ZipCrypto）—— 与密码无关的可复用偏好。
        if format == .zip {
            Picker(L10n.text("archive.encryptionMethod"), selection: $options.encryptionMethod) {
                ForEach(ArchiveEncryptionMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
        }

        if format == .sevenZip {
            Picker(L10n.text("archive.7z.method"), selection: $options.sevenZipMethod) {
                ForEach(SevenZipCompressionMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            Picker(L10n.text("archive.7z.dictionarySize"), selection: $options.sevenZipDictionarySizeMB) {
                ForEach(dictionarySizeOptions, id: \.self) { Text("\($0) MB").tag($0) }
            }
            Picker(L10n.text("archive.7z.wordSize"), selection: $options.sevenZipWordSize) {
                ForEach(wordSizeOptions, id: \.self) { Text("\($0)").tag($0) }
            }
            HStack {
                Text(L10n.text("archive.7z.threads"))
                Spacer()
                Stepper(value: $options.sevenZipThreadCount, in: 0...maxThreadCount) {
                    Text(options.sevenZipThreadCount == 0 ? L10n.text("archive.7z.method.automatic") : "\(options.sevenZipThreadCount)")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.text("archive.7z.solid"), isOn: $options.sevenZipSolidArchive)
            if options.sevenZipSolidArchive {
                Picker(L10n.text("archive.7z.solidBlockSize"), selection: $options.sevenZipSolidBlockSize) {
                    ForEach(SevenZipSolidBlockSize.allCases) { Text($0.title).tag($0) }
                }
            }
            Toggle(L10n.text("archive.7z.storeSymbolicLinks"), isOn: $options.sevenZipStoreSymbolicLinks)
            Toggle(L10n.text("archive.7z.storeHardLinks"), isOn: $options.sevenZipStoreHardLinks)
            Toggle(L10n.text("archive.7z.compressSharedFiles"), isOn: $options.sevenZipCompressSharedFiles)
        }

        // 路径模式：7z 和支持「更新模式」的格式都用得上。
        if format == .sevenZip || format.supportsUpdateMode {
            Picker(L10n.text("archive.7z.pathMode"), selection: $options.sevenZipPathMode) {
                ForEach(SevenZipPathMode.allCases) { Text($0.title).tag($0) }
            }
        }

        // 加密文件名（7z / rar，需配密码时才生效；作为偏好仍可在默认值里设）。
        if format == .sevenZip || format == .rar {
            Toggle(L10n.text("archive.7z.encryptFileNames"), isOn: $options.sevenZipEncryptFileNames)
        }

        if format.supportsRawParameters {
            TextField(L10n.text("archive.parameters"), text: $options.rawParameters)
                .textFieldStyle(.roundedBorder)
        }

        if format.supportsExcludeRules {
            Toggle(L10n.text("archive.skipDSStore"), isOn: $options.skipDSStore)
            Toggle(L10n.text("archive.skipHiddenFiles"), isOn: $options.skipHiddenFiles)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("archive.customExcludes")).font(.caption)
                TextEditor(text: $options.customExcludes)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }

    private func loadForCurrentFormat() {
        if let stored = store.options(for: format) {
            enabled = true
            options = stored
        } else {
            enabled = false
            var fresh = ArchiveCreationOptions()
            fresh.format = format
            options = fresh
        }
    }
}
