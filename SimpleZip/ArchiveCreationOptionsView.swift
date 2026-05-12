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
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("archive.create.title"))
                .font(.title3)
                .fontWeight(.semibold)

            Form {
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

                Toggle(L10n.text("archive.skipDSStore"), isOn: $request.options.skipDSStore)
                Toggle(L10n.text("archive.skipHiddenFiles"), isOn: $request.options.skipHiddenFiles)

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
                    create(request)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = L10n.text("panel.createArchive")
        panel.directoryURL = request.destinationURL.deletingLastPathComponent()
        panel.nameFieldStringValue = request.destinationURL.lastPathComponent
        panel.allowedContentTypes = ArchiveService.contentTypes(for: request.options.format)

        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
        }
    }

    private func updateDestinationExtension() {
        request.destinationURL = request.destinationURL
            .deletingPathExtension()
            .appendingPathExtension(request.options.format.pathExtension)
    }
}
