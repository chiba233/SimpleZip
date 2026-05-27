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
        ExtractOptionsForm(
            title: L10n.text("extract.selected.title"),
            destinationURL: $request.destinationURL,
            password: $request.password,
            zipDecryptionMethod: $request.zipDecryptionMethod,
            showDetails: $request.showDetails,
            showsZipDecryptionMethod: request.archiveURL.pathExtension.lowercased() == "zip",
            zipEncryptionDetectionText: request.detectedZipEncryption.autoDetectionText,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            Picker(L10n.text("extract.pathMode"), selection: $request.pathMode) {
                ForEach(ExtractPathMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
        .frame(width: 520)
    }
}
