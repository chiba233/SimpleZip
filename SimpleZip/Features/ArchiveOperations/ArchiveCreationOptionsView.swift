//
//  ArchiveCreationOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 创建压缩包前的选项面板。
struct ArchiveCreationOptionsView: View {
    @State var request: ArchiveCreationRequest
    @State private var showsSevenZipAdvancedOptions = false
    @State private var excludedFileCount: Int?
    @State private var isCountingExcludedFiles = false
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("archive.create.title"))
                .font(.title3)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("archive.fileName"), text: fileNameBinding)
                        .textFieldStyle(.roundedBorder)

                    HStack(alignment: .center, spacing: 14) {
                        HStack(spacing: 6) {
                            Text(L10n.text("archive.format"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker(L10n.text("archive.format"), selection: $request.options.format) {
                                ForEach(ArchiveCreateFormat.allCases) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 112)
                            .onChange(of: request.options.format) { _ in
                                updateDestinationExtension()
                            }
                        }

                        if request.options.format.supportsCompressionLevel {
                            HStack(spacing: 6) {
                                Text(L10n.text("archive.compressionLevel"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker(L10n.text("archive.compressionLevel"), selection: $request.options.compressionLevel) {
                                    ForEach(CompressionLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 124)
                            }
                        }

                        if request.options.format.supportsUpdateMode {
                            HStack(spacing: 6) {
                                Text(L10n.text("archive.updateMode"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker(L10n.text("archive.updateMode"), selection: $request.options.updateMode) {
                                    ForEach(ArchiveUpdateMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 152)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if request.options.format.supportsPassword {
                        passwordField(L10n.text("archive.password"), text: $request.options.password)
                        if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                            passwordField(L10n.text("archive.passwordConfirm"), text: $request.options.passwordConfirmation)
                            Toggle(L10n.text("archive.showPassword"), isOn: $request.options.showPassword)
                                .toggleStyle(.checkbox)
                            if passwordValidationMessage != nil {
                                validationText(L10n.text("error.passwordsDoNotMatch"))
                            }
                        }
                        if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                            if request.options.format == .zip {
                                Picker(L10n.text("archive.encryptionMethod"), selection: $request.options.encryptionMethod) {
                                    ForEach(ArchiveEncryptionMethod.allCases) { method in
                                        Text(method.title).tag(method)
                                    }
                                }
                            } else {
                                HStack {
                                    Text(L10n.text("archive.encryptionMethod"))
                                    Spacer()
                                    Text(ArchiveEncryptionMethod.aes256.title)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let singleFileValidationMessage {
                        validationText(singleFileValidationMessage)
                    }

                    if request.options.format == .rar, !ArchiveService.canCreateRAR() {
                        validationText(L10n.text("archive.rar.requiresTool"))
                    }

                    if request.options.format.supportsVolumeSplitting {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.text("archive.7z.volumeSize"), text: $request.options.sevenZipVolumeSize)
                                .textFieldStyle(.roundedBorder)
                            if let volumeSizeValidationMessage {
                                validationText(volumeSizeValidationMessage)
                            } else {
                                Text(L10n.text("archive.7z.volumeSizeHint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if request.options.format == .sevenZip {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(L10n.text("archive.7z.method"), selection: $request.options.sevenZipMethod) {
                                ForEach(SevenZipCompressionMethod.allCases) { method in
                                    Text(method.title).tag(method)
                                }
                            }

                            Picker(L10n.text("archive.7z.dictionarySize"), selection: $request.options.sevenZipDictionarySizeMB) {
                                ForEach(dictionarySizeOptions, id: \.self) { size in
                                    Text("\(size) MB").tag(size)
                                }
                            }

                            Picker(L10n.text("archive.7z.wordSize"), selection: $request.options.sevenZipWordSize) {
                                ForEach(wordSizeOptions, id: \.self) { wordSize in
                                    Text("\(wordSize)").tag(wordSize)
                                }
                            }

                            HStack {
                                Text(L10n.text("archive.7z.threads"))
                                Spacer()
                                Stepper(value: $request.options.sevenZipThreadCount, in: 0...maxThreadCount) {
                                    Text(threadCountLabel)
                                        .foregroundStyle(.secondary)
                                }
                                .labelsHidden()
                            }

                            HStack {
                                Text(L10n.text("archive.memoryUsageCompressing"))
                                Spacer()
                                Text(estimatedCompressionMemoryText)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text(L10n.text("archive.memoryUsageDecompressing"))
                                Spacer()
                                Text(estimatedDecompressionMemoryText)
                                    .foregroundStyle(.secondary)
                            }

                            DisclosureGroup(L10n.text("archive.7z.advanced"), isExpanded: $showsSevenZipAdvancedOptions) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(L10n.text("archive.7z.solid"), isOn: $request.options.sevenZipSolidArchive)
                                    if request.options.sevenZipSolidArchive {
                                        Picker(L10n.text("archive.7z.solidBlockSize"), selection: $request.options.sevenZipSolidBlockSize) {
                                            ForEach(SevenZipSolidBlockSize.allCases) { size in
                                                Text(size.title).tag(size)
                                            }
                                        }
                                    }

                                    Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                                        ForEach(SevenZipPathMode.allCases) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }

                                    Toggle(L10n.text("archive.7z.storeSymbolicLinks"), isOn: $request.options.sevenZipStoreSymbolicLinks)
                                    Toggle(L10n.text("archive.7z.storeHardLinks"), isOn: $request.options.sevenZipStoreHardLinks)
                                    Toggle(L10n.text("archive.7z.compressSharedFiles"), isOn: $request.options.sevenZipCompressSharedFiles)
                                    Toggle(L10n.text("archive.7z.deleteAfterCompression"), isOn: $request.options.sevenZipDeleteSourceFiles)
                                }
                                .padding(.top, 6)
                            }
                        }
                    }

                    if request.options.format != .sevenZip, request.options.format.supportsUpdateMode {
                        Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                            ForEach(SevenZipPathMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    if request.options.format == .sevenZip || request.options.format == .rar {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(L10n.text("archive.7z.encryptFileNames"), isOn: $request.options.sevenZipEncryptFileNames)
                                .disabled(request.options.password.isEmpty)
                            if request.options.password.isEmpty {
                                Text(L10n.text("archive.7z.encryptFileNamesHint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
                            }
                        }
                    }

                    if request.options.format.supportsSFX {
                        Toggle(L10n.text("archive.createSFX"), isOn: $request.options.createSFXArchive)
                    }

                    if request.options.format.supportsRawParameters {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.text("archive.parameters"), text: $request.options.rawParameters)
                                .textFieldStyle(.roundedBorder)
                            Text(L10n.text("archive.parametersHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if request.options.format.supportsExcludeRules {
                        Toggle(L10n.text("archive.skipDSStore"), isOn: $request.options.skipDSStore)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(L10n.text("archive.skipHiddenFiles"), isOn: $request.options.skipHiddenFiles)
                            Text(L10n.text("archive.skipHiddenFilesHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("archive.customExcludes"))
                            TextEditor(text: $request.options.customExcludes)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: .separatorColor))
                                )
                            Text(L10n.text("archive.customExcludesHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button(L10n.text("archive.countExcludedFiles")) {
                                    countExcludedFiles()
                                }
                                .disabled(isCountingExcludedFiles || !hasExcludeRulesEnabled)

                                if isCountingExcludedFiles {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(excludedFileCountText)
                                    .font(.caption)
                                    .foregroundStyle((excludedFileCount ?? 0) > 0 ? .secondary : .tertiary)
                            }
                        }
                    }

                    HStack {
                        Text(L10n.text("archive.destination"))
                        Text(request.destinationURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("button.choose")) {
                            chooseDestination()
                        }
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 520)

            HStack {
                Toggle(isOn: $request.options.showDetails) {
                    Label(L10n.text("operation.showDetails"), systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.create")) {
                    normalizeDestinationForCurrentFormat()
                    create(request)
                }
                .disabled(validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .animation(.default, value: request.options.format)
        .animation(.default, value: showsSevenZipAdvancedOptions)
        .animation(.default, value: request.options.password.isEmpty)
        .animation(.default, value: request.options.passwordConfirmation.isEmpty)
        .onChange(of: request.options.skipDSStore) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.skipHiddenFiles) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.customExcludes) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.format) { _ in
            excludedFileCount = nil
        }
    }

    private var fileNameBinding: Binding<String> {
        Binding {
            archiveBaseName(from: request.destinationURL.lastPathComponent)
        } set: { newValue in
            let trimmedName = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            request.destinationURL = request.destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(archiveFileName(fromBaseName: trimmedName))
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = L10n.text("panel.createArchive")
        panel.directoryURL = request.destinationURL.deletingLastPathComponent()
        panel.nameFieldStringValue = archiveBaseName(from: request.destinationURL.lastPathComponent)
        panel.allowedContentTypes = ArchiveService.contentTypes(for: request.options.format)

        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(archiveFileName(fromBaseName: url.lastPathComponent))
        }
    }

    private func updateDestinationExtension() {
        normalizeOptionsForCurrentFormat()
        normalizeDestinationForCurrentFormat()
    }

    private func countExcludedFiles() {
        guard request.options.format.supportsExcludeRules else {
            excludedFileCount = 0
            return
        }
        let sourceURLs = request.sourceURLs
        let options = request.options
        isCountingExcludedFiles = true
        Task { @MainActor in
            let count = await Task.detached(priority: .utility) {
                ArchiveService.excludedFileCount(in: sourceURLs, options: options)
            }.value
            excludedFileCount = count
            isCountingExcludedFiles = false
        }
    }

    private var hasExcludeRulesEnabled: Bool {
        request.options.skipDSStore
            || request.options.skipHiddenFiles
            || !ArchiveService.customExcludePatterns(from: request.options.customExcludes).isEmpty
    }

    private var excludedFileCountText: String {
        guard hasExcludeRulesEnabled else {
            return L10n.text("archive.excludedFilesNotConfigured")
        }
        guard let excludedFileCount else {
            return L10n.text("archive.excludedFilesNeedsCalculation")
        }
        return L10n.format("archive.excludedFilesDetected", excludedFileCount)
    }

    private func normalizeOptionsForCurrentFormat() {
        if !request.options.format.supportsPassword {
            request.options.password = ""
            request.options.passwordConfirmation = ""
            request.options.showPassword = false
        }
        if !request.options.format.supportsVolumeSplitting {
            request.options.sevenZipVolumeSize = ""
        }
        if !request.options.format.supportsUpdateMode {
            request.options.updateMode = .addAndReplace
            request.options.sevenZipPathMode = .relative
        }
        if !request.options.format.supportsSFX {
            request.options.createSFXArchive = false
        }
        if !request.options.format.supportsRawParameters {
            request.options.rawParameters = ""
        }
        if request.options.format == .zip, request.options.password.isEmpty {
            request.options.encryptionMethod = .zipCrypto
        }
        if request.options.format != .zip {
            request.options.encryptionMethod = .aes256
        }
    }

    private func normalizeDestinationForCurrentFormat() {
        let baseName = archiveBaseName(from: request.destinationURL.lastPathComponent)
        request.destinationURL = request.destinationURL
            .deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(archiveFileName(fromBaseName: baseName))
    }

    private func archiveFileName(fromBaseName fileName: String) -> String {
        archiveBaseName(from: fileName) + ".\(request.options.format.pathExtension)"
    }

    private func archiveBaseName(from fileName: String) -> String {
        var baseName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownExtensions = ArchiveCreateFormat.allCases.map(\.pathExtension)
        while let extensionName = knownExtensions.first(where: { baseName.lowercased().hasSuffix(".\($0)") }) {
            baseName.removeLast(extensionName.count + 1)
            baseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return baseName.isEmpty ? "Archive" : baseName
    }

    private var maxThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    private var dictionarySizeOptions: [Int] {
        [1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    }

    private var wordSizeOptions: [Int] {
        [16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    }

    private var threadCountLabel: String {
        request.options.sevenZipThreadCount == 0
            ? L10n.text("archive.7z.threads.auto")
            : "\(request.options.sevenZipThreadCount)"
    }

    private var validationMessage: String? {
        if request.options.format == .rar, !ArchiveService.canCreateRAR() {
            return L10n.text("error.missingRarTool")
        }
        if let passwordValidationMessage {
            return passwordValidationMessage
        }
        if let volumeSizeValidationMessage {
            return volumeSizeValidationMessage
        }
        if let singleFileValidationMessage {
            return singleFileValidationMessage
        }
        return nil
    }

    private var passwordValidationMessage: String? {
        if !request.options.password.isEmpty, request.options.password != request.options.passwordConfirmation {
            return L10n.text("error.passwordsDoNotMatch")
        }
        return nil
    }

    private var volumeSizeValidationMessage: String? {
        guard request.options.format.supportsVolumeSplitting else { return nil }
        let trimmed = request.options.sevenZipVolumeSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? ArchiveService.normalizedSevenZipVolumeSize(from: trimmed)) == nil
            ? L10n.text("error.invalidSevenZipVolumeSize")
            : nil
    }

    private var singleFileValidationMessage: String? {
        guard request.options.format.requiresSingleRegularFile else { return nil }
        guard request.sourceURLs.count == 1 else {
            return L10n.text("error.singleFileCompressionRequiresSingleFile")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: request.sourceURLs[0].path, isDirectory: &isDirectory), isDirectory.boolValue {
            return L10n.text("error.singleFileCompressionRequiresSingleFile")
        }
        return nil
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        if request.options.showPassword {
            TextField(title, text: text)
        } else {
            SecureField(title, text: text)
        }
    }

    private var effectiveThreadCount: Int {
        request.options.sevenZipThreadCount == 0 ? maxThreadCount : request.options.sevenZipThreadCount
    }

    private var estimatedCompressionMemoryText: String {
        formatMemoryEstimate(compressionMemoryEstimateBytes)
    }

    private var estimatedDecompressionMemoryText: String {
        formatMemoryEstimate(decompressionMemoryEstimateBytes)
    }

    private var compressionMemoryEstimateBytes: Int64 {
        let dictionaryBytes = Int64(request.options.sevenZipDictionarySizeMB) * 1_048_576
        let threads = Int64(effectiveThreadCount)
        switch request.options.sevenZipMethod {
        case .automatic, .lzma2, .lzma:
            return dictionaryBytes * max(1, threads) + threads * 34 * 1_048_576
        case .ppmd:
            return dictionaryBytes + 32 * 1_048_576
        case .bzip2:
            return threads * 10 * 1_048_576
        case .deflate:
            return threads * 4 * 1_048_576
        case .copy:
            return 1 * 1_048_576
        }
    }

    private var decompressionMemoryEstimateBytes: Int64 {
        let dictionaryBytes = Int64(request.options.sevenZipDictionarySizeMB) * 1_048_576
        switch request.options.sevenZipMethod {
        case .automatic, .lzma2, .lzma:
            return dictionaryBytes + 4 * 1_048_576
        case .ppmd:
            return dictionaryBytes
        case .bzip2:
            return 8 * 1_048_576
        case .deflate:
            return 2 * 1_048_576
        case .copy:
            return 1 * 1_048_576
        }
    }

    private func formatMemoryEstimate(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    @ViewBuilder
    private func validationText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
