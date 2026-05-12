//
//  ExtractArchiveOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/13.
//

import SwiftUI

/// 整包解压前的选项面板：目标目录和可选密码。
struct ExtractArchiveOptionsView: View {
    @State var request: ExtractArchiveRequest
    let extract: (ExtractArchiveRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("extract.archive.title"))
                .font(.title3)
                .fontWeight(.semibold)

            Form {
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

                SecureField(L10n.text("extract.password.placeholder"), text: $request.password)
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.extract")) {
                    extract(request)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.extractTo")
        panel.prompt = L10n.text("button.choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = request.destinationURL

        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
        }
    }
}
