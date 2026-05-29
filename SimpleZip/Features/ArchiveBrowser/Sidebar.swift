//
//  Sidebar.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 左侧导航栏：放常用位置和打开入口。
struct Sidebar: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var recentURLs: [URL] = []
    @State private var pinnedURLs: [URL] = []
    @State private var isPinnedDropTargeted = false

    /// 实际渲染到侧栏的「个人收藏」条目 —— Finder 收藏有就用 Finder 的，没有就用默认 5 项。
    /// `finderFavorites` 数据源在 `ArchiveBrowserModel` 而不是 Sidebar 的 @State（详见 model 上的注释）。
    private var favoriteRows: [FavoriteRow] {
        if !model.finderFavorites.isEmpty {
            return model.finderFavorites.map { item in
                FavoriteRow(id: item.url.path, title: item.displayName, systemImage: item.systemImage, openURL: item.url)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let applications = URL(fileURLWithPath: "/Applications")
        return [
            FavoriteRow(id: "fallback.home", title: L10n.text("location.home"), systemImage: "house", openURL: home),
            FavoriteRow(id: "fallback.downloads", title: L10n.text("location.downloads"), systemImage: "arrow.down.circle", openURL: downloads ?? home),
            FavoriteRow(id: "fallback.desktop", title: L10n.text("location.desktop"), systemImage: "display", openURL: desktop ?? home),
            FavoriteRow(id: "fallback.documents", title: L10n.text("location.documents"), systemImage: "doc.text", openURL: documents ?? home),
            FavoriteRow(id: "fallback.applications", title: L10n.text("location.applications"), systemImage: "app", openURL: applications)
        ]
    }

    /// Finder 侧栏的标签列表。
    ///
    /// 直接用 `NSWorkspace.shared.fileLabels` + `fileLabelColors`：系统当前语言下的 7 个系统色块名 +
    /// Finder 实际渲染的精确色块颜色，跟 Finder 侧栏 1:1 对齐。
    /// 之前尝试过用 `FavoriteTagNames` 偏好，但实测语义跟 Finder 侧栏实际显示对不上 ——
    /// 多 locale / 空槽位 / 重复 / 顺序错都会出问题，回到这个最朴素的实现。
    private var finderTags: [FinderTag] {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return labels.indices.compactMap { index in
            let name = labels[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return FinderTag(
                id: index,
                name: name,
                color: colors.indices.contains(index) ? colors[index] : .labelColor
            )
        }
    }

    var body: some View {
        List {
            Section(L10n.text("section.favorites")) {
                ForEach(favoriteRows) { row in
                    SidebarButton(
                        title: row.title,
                        systemImage: row.systemImage,
                        action: { model.openFolder(row.openURL) }
                    )
                }
            }

            if !recentURLs.isEmpty {
                Section(L10n.text("section.recents")) {
                    ForEach(recentURLs, id: \.path) { url in
                        SidebarButton(title: displayName(for: url), systemImage: "clock", action: { model.openFolder(url) })
                    }
                }
            }

            Section(L10n.text("section.pinned")) {
                SidebarButton(title: L10n.text("button.pinCurrentLocation"), systemImage: "pin", action: pinCurrentLocation)

                ForEach(pinnedURLs, id: \.path) { url in
                    SidebarRowButton(action: { model.openFolder(url) }) {
                        Label(displayName(for: url), systemImage: "pin.fill")
                    }
                    .contextMenu {
                        Button(L10n.text("button.unpin")) { unpinSidebarURL(url) }
                    }
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isPinnedDropTargeted) { providers in
                receivePinnedDrop(from: providers)
            }
            .dropDestination(for: URL.self) { urls, _ in
                pinDroppedDirectories(urls)
            } isTargeted: { targeted in
                isPinnedDropTargeted = targeted
            }
            .listRowBackground(isPinnedDropTargeted ? Color.accentColor.opacity(0.16) : Color.clear)

            if !finderTags.isEmpty {
                Section(L10n.text("section.tags")) {
                    ForEach(finderTags) { tag in
                        SidebarRowButton(action: { model.openTag(tag.name) }) {
                            HStack(spacing: 8) {
                                // Finder 风格：标签 = 系统颜色圆点 + 名称，跟通用 tag 图标区分开。
                                Circle()
                                    .fill(Color(nsColor: tag.color))
                                    .frame(width: 9, height: 9)
                                    .overlay {
                                        Circle()
                                            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                                    }
                                    .accessibilityHidden(true)
                                Text(tag.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                        .accessibilityLabel(tag.name)
                    }
                }
            }

            Section(L10n.text("section.archives")) {
                SidebarButton(title: L10n.text("button.openArchive"), systemImage: "doc.zipper", action: model.chooseArchive)
                SidebarButton(title: L10n.text("button.openFolder"), systemImage: "folder", action: model.chooseFolder)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SimpleZip")
        .onAppear(perform: refreshSidebarURLs)
        // 用户从 Finder 调过收藏切回 SimpleZip 时重读 sfl4。
        // sfl4 没有官方变化通知，App 重激活是「肯定刚操作过 Finder」的最近时间点。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSidebarURLs()
        }
    }

    private func pinCurrentLocation() {
        model.pinCurrentFolderToSidebar()
        refreshSidebarURLs()
    }

    private func unpinSidebarURL(_ url: URL) {
        AppPreferences.unpinSidebarURL(url)
        refreshSidebarURLs()
    }

    private func refreshSidebarURLs() {
        recentURLs = existingURLs(AppPreferences.recentSidebarURLs)
        pinnedURLs = existingURLs(AppPreferences.pinnedSidebarURLs)
        model.refreshFinderFavorites()
    }

    private func receivePinnedDrop(from providers: [NSItemProvider]) -> Bool {
        extractDroppedFileURLs(from: providers) { urls in
            // 共享 extractor 不做内容过滤；固定列表只接目录，所以在主线程回调里再过一遍 isExistingDirectory。
            _ = pinDroppedDirectories(urls.filter(isExistingDirectory))
        }
    }

    @discardableResult
    private func pinDroppedDirectories(_ urls: [URL]) -> Bool {
        let droppedDirectories = urls.filter(isExistingDirectory)
        guard !droppedDirectories.isEmpty else { return false }

        droppedDirectories.reversed().forEach(AppPreferences.pinSidebarURL)
        refreshSidebarURLs()
        return true
    }

    private func existingURLs(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func displayName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).isEmpty ? url.path : FileManager.default.displayName(atPath: url.path)
    }
}

/// 「个人收藏」侧栏单条目的最小化表示。
/// Finder 真实收藏走 sfl4 路径 → 转成它；解析失败的回落 5 项也用同一类型。
/// 让 List/ForEach 拿到统一形状的数组，避开 `_ConditionalContent` 切换不刷新的怪问题。
private struct FavoriteRow: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let openURL: URL
}

private struct FinderTag: Identifiable {
    let id: Int
    let name: String
    let color: NSColor
}

/// 侧边栏行按钮的统一外壳：hover 高亮 + 圆角背景 + buttonStyle + onHover 动画。
/// 三种 row（普通 / 固定 / 标签）共享，只在「leading 内容」上分叉 ——
/// 通用 row 用 `Label(title, systemImage:)`；标签 row 用 Circle+Text；
/// 固定 row 在调用点再加 `.contextMenu` 即可。
private struct SidebarRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
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

/// 普通侧边栏按钮：Label 图标 + 标题。`SidebarRowButton` 的预制 facade。
struct SidebarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        SidebarRowButton(action: action) {
            Label(title, systemImage: systemImage)
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
