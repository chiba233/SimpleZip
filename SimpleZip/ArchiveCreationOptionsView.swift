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
    @State private var showsAdvancedSevenZipOptions = true
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("archive.create.title"))
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                TextField(L10n.text("archive.fileName"), text: fileNameBinding)

                Picker(L10n.text("archive.format"), selection: $request.options.format) {
                    ForEach(ArchiveCreateFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .onChange(of: request.options.format) { _ in
                    updateDestinationExtension()
                }

                Picker(L10n.text("archive.compressionLevel"), selection: $request.options.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }

                SecureField(L10n.text("archive.password"), text: $request.options.password)

                if request.options.format == .sevenZip {
                    DisclosureGroup(isExpanded: $showsAdvancedSevenZipOptions) {
                        Picker(L10n.text("archive.7z.method"), selection: $request.options.sevenZipMethod) {
                            ForEach(SevenZipCompressionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }

                        Stepper(value: $request.options.sevenZipThreadCount, in: 0...maxThreadCount) {
                            HStack {
                                Text(L10n.text("archive.7z.threads"))
                                Spacer()
                                Text(threadCountLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(L10n.text("archive.7z.solid"), isOn: $request.options.sevenZipSolidArchive)

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

                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.text("archive.7z.volumeSize"), text: $request.options.sevenZipVolumeSize)
                                .textFieldStyle(.roundedBorder)
                            Text(L10n.text("archive.7z.volumeSizeHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(L10n.text("archive.7z.advanced"))
                    }
                }

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

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.create")) {
                    normalizeDestinationForCurrentFormat()
                    create(request)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
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
        normalizeDestinationForCurrentFormat()
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

    private var threadCountLabel: String {
        request.options.sevenZipThreadCount == 0
            ? L10n.text("archive.7z.threads.auto")
            : "\(request.options.sevenZipThreadCount)"
    }
}
