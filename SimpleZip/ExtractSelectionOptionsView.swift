//
//  ExtractSelectionOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 解压选中条目前的选项面板。
struct ExtractSelectionOptionsView: View {
    @State var request: ExtractSelectionRequest
    let extract: (ExtractSelectionRequest) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("extract.selected.title"))
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                Picker(L10n.text("extract.pathMode"), selection: $request.pathMode) {
                    ForEach(ExtractPathMode.allCases) { mode in
                        Text(mode.title).tag(mode)
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

                SecureField(L10n.text("extract.password.placeholder"), text: $request.password)
                Toggle(L10n.text("operation.showDetails"), isOn: $request.showDetails)
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
        .frame(width: 520)
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
