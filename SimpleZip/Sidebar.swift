//
//  Sidebar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 左侧导航栏：放常用位置和打开入口。
struct Sidebar: View {
    @ObservedObject var model: ArchiveBrowserModel

    var body: some View {
        List {
            Section(L10n.text("section.locations")) {
                SidebarButton(title: L10n.text("location.home"), systemImage: "house", action: model.openHome)
                SidebarButton(title: L10n.text("location.downloads"), systemImage: "arrow.down.circle", action: model.openDownloads)
                SidebarButton(title: L10n.text("location.desktop"), systemImage: "display", action: model.openDesktop)
            }

            Section(L10n.text("section.archives")) {
                SidebarButton(title: L10n.text("button.openArchive"), systemImage: "doc.zipper", action: model.chooseArchive)
                SidebarButton(title: L10n.text("button.openFolder"), systemImage: "folder", action: model.chooseFolder)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SimpleZip")
    }
}

/// 侧边栏里的统一按钮样式。
struct SidebarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}
