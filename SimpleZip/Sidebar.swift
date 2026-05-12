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
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16) : .clear)
                }
        }
        .buttonStyle(SidebarRowButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

/// 让侧边栏按钮拥有整行点击区域，并提供轻量的按压动画。
private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1, anchor: .center)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
