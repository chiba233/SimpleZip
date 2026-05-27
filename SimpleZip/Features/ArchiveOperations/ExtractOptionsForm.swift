//
//  ExtractOptionsForm.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/16.
//

import SwiftUI

struct ExtractOptionsForm<ExtraControls: View>: View {
    let title: String
    @Binding var destinationURL: URL
    @Binding var password: String
    @Binding var zipDecryptionMethod: ArchiveDecryptionMethod
    @Binding var showDetails: Bool
    let showsZipDecryptionMethod: Bool
    let zipEncryptionDetectionText: String?
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let extraControls: () -> ExtraControls

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                extraControls()
                destinationRow
                SecureField(L10n.text("extract.password.placeholder"), text: $password)
                if showsZipDecryptionMethod {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(L10n.text("extract.decryptionMethod"), selection: $zipDecryptionMethod) {
                            ForEach(ArchiveDecryptionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }

                        if zipDecryptionMethod == .automatic, let zipEncryptionDetectionText {
                            Text(zipEncryptionDetectionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            HStack {
                Toggle(isOn: $showDetails) {
                    Label(L10n.text("operation.showDetails"), systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.extract"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var destinationRow: some View {
        HStack {
            Text(L10n.text("archive.destination"))
            Text(destinationURL.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("button.choose")) {
                chooseDestination()
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.extractTo")
        panel.prompt = L10n.text("button.choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL

        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }
}
