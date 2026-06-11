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
            subtitle: request.archiveURL.lastPathComponent,
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
            // 0.4.2：不解压 macOS 元数据垃圾 —— 与整包解压同款开关。
            Toggle(isOn: $request.skipJunk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("extract.skipJunk"))
                    Text(L10n.text("extract.skipJunk.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 560)
    }
}
