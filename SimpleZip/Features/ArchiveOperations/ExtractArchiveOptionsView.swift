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
        ExtractOptionsForm(
            title: L10n.text("extract.archive.title"),
            destinationURL: $request.destinationURL,
            password: $request.password,
            showDetails: $request.showDetails,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            EmptyView()
        }
        .frame(width: 540)
    }
}
