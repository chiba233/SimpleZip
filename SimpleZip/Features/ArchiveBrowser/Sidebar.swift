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
    /// 0.4.5 #80:AI 主开关。关闭 → AI 工作区入口整体不渲染(A4 门控:主开关关,主界面 AI 入口全隐藏)。
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiEnabled = true
    @State private var recentURLs: [URL] = []
    @State private var pinnedURLs: [URL] = []
    @State private var isPinnedDropTargeted = false
    /// 图标缓存世代：app 重激活时自增,强制所有行重建、重取 NSWorkspace 图标（见 didBecomeActive）。
    @State private var iconGeneration = 0
    /// 当前被拖拽悬停的侧栏行(行级投递目标高亮)。值 = 行的唯一 id(路径 / "tag:名")。
    @State private var dropTargetID: String?

    /// 实际渲染到侧栏的「个人收藏」条目 —— Finder 收藏有就用 Finder 的，没有就用默认 5 项。
    /// `finderFavorites` 数据源在 `ArchiveBrowserModel` 而不是 Sidebar 的 @State（详见 model 上的注释）。
    private var favoriteRows: [FavoriteRow] {
        if !model.finderFavorites.isEmpty {
            return model.finderFavorites.map { item in
                FavoriteRow(id: item.url.path, title: item.displayName, systemImage: nil, openURL: item.url)
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
            // 0.4.5 #80:AI 工作区(白皮书工程补充一 MVP)。只读虚拟工作区,确定性候选;AI 主开关关 → 整段隐藏。
            if aiEnabled {
                Section(L10n.text("sidebar.ai.section")) {
                    SidebarButton(title: L10n.text("aiFolder.needsAttention"),
                                  systemImage: AISystemWorkspaceKind.needsAttention.systemImage) {
                        model.openAIWorkspace(.needsAttention)
                    }
                    SidebarButton(title: L10n.text("aiFolder.releaseAndVerify"),
                                  systemImage: AISystemWorkspaceKind.releaseAndVerify.systemImage) {
                        model.openAIWorkspace(.releaseAndVerify)
                    }
                    SidebarButton(title: L10n.text("aiFolder.recentArchives"),
                                  systemImage: AISystemWorkspaceKind.recentArchives.systemImage) {
                        model.openAIWorkspace(.recentArchives)
                    }
                }
            }

            Section(L10n.text("section.favorites")) {
                ForEach(favoriteRows) { row in
                    SidebarRowButton(action: { model.openFolder(row.openURL) }) {
                        if let systemImage = row.systemImage {
                            Label(row.title, systemImage: systemImage)
                        } else {
                            sidebarFileLabel(for: row.openURL, displayName: row.title)
                        }
                    }
                    .modifier(folderDropTarget(row.openURL, id: "fav:\(row.id)"))
                }
            }

            if !recentURLs.isEmpty {
                Section(L10n.text("section.recents")) {
                    ForEach(recentURLs, id: \.path) { url in
                        // 动态识别真实图标(用户点名):自定义文件夹图标 / 包 / 彩色 App 目录等
                        // 都按系统实际渲染,不再一律灰色时钟。
                        SidebarRowButton(action: { model.openFolder(url) }) {
                            sidebarFileLabel(for: url)
                        }
                        .modifier(folderDropTarget(url, id: "recent:\(url.path)"))
                    }
                }
            }

            Section(L10n.text("section.pinned")) {
                SidebarButton(title: L10n.text("button.pinCurrentLocation"), systemImage: "pin.fill", action: pinCurrentLocation)

                ForEach(pinnedURLs, id: \.path) { url in
                    SidebarRowButton(action: { model.openFolder(url) }) {
                        sidebarFileLabel(for: url)
                    }
                    .contextMenu {
                        Button(L10n.text("button.unpin")) { unpinSidebarURL(url) }
                    }
                    .modifier(folderDropTarget(url, id: "pin:\(url.path)"))
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
                        // 拖文件到标签行 = 给文件打这个 Finder 标签(Finder 同款交互)。
                        .background(dropHighlight(id: "tag:\(tag.name)"))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard !urls.isEmpty else { return false }
                            model.applyFinderTag(tag.name, to: urls)
                            return true
                        } isTargeted: { targeted in
                            updateDropTarget("tag:\(tag.name)", targeted: targeted)
                        }
                    }
                }
            }

            // 「压缩包」组(打开压缩包 / 打开文件夹两个按钮)已删 —— 用户拍板:工具栏 / 文件菜单 /
            // 拖入都能打开,侧栏占两行毫无价值。
        }
        .listStyle(.sidebar)
        .navigationTitle("SimpleZip")
        .onAppear(perform: refreshSidebarURLs)
        // 用户从 Finder 调过收藏切回 SimpleZip 时重读 sfl4。
        // sfl4 没有官方变化通知，App 重激活是「肯定刚操作过 Finder」的最近时间点。
        // 图标缓存同时清掉强制重取（用户报：别的 app 更新 / 文件夹换图标后,侧栏一直显示老图标 ——
        // NSCache 整个会话不失效,列表刷新了图标还是旧的）。generation 自增驱动行重建,Image 才会重新取图。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Self.iconCache.removeAllObjects()
            iconGeneration += 1
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

    /// 「最近 / 固定」行：系统真实文件图标 + 显示名。NSWorkspace 取的是该路径当前实际渲染的
    /// 图标（自定义文件夹色 / 特殊目录 / 包都对），比一刀切的 SF Symbol 信息量大得多。
    private func sidebarFileLabel(for url: URL, displayName explicitDisplayName: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: fileIcon(for: url))
            Text(explicitDisplayName ?? displayName(for: url))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// 图标缓存：NSWorkspace 取图标有 IO 成本，侧栏每次重渲染都查会浪费 —— 按路径缓存。
    /// 用 NSCache 而不是 @State 字典：渲染期间可写（@State 不行）、内存压力下自动清。
    private static let iconCache = NSCache<NSString, NSImage>()

    private func fileIcon(for url: URL) -> NSImage {
        if let cached = Self.iconCache.object(forKey: url.path as NSString) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        Self.iconCache.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    // MARK: - 行级拖放（拖文件进侧栏文件夹 = 移动；拖到标签 = 打标签）

    /// 文件夹行的投递目标：高亮 + dropDestination 一起挂。`id` 唯一标识这一行（区分同路径出现在多个分区）。
    private func folderDropTarget(_ folder: URL, id: String) -> FolderDropTargetModifier {
        FolderDropTargetModifier(
            highlighted: dropTargetID == id,
            onTargeted: { targeted in updateDropTarget(id, targeted: targeted) },
            onDrop: { urls in receiveFolderDrop(urls, into: folder) }
        )
    }

    @ViewBuilder
    private func dropHighlight(id: String) -> some View {
        if dropTargetID == id {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
        }
    }

    private func updateDropTarget(_ id: String, targeted: Bool) {
        if targeted {
            dropTargetID = id
        } else if dropTargetID == id {
            dropTargetID = nil
        }
    }

    /// 拖文件到侧栏文件夹行 = **移动**进该文件夹（Finder 同卷拖拽语义），走现有传输管线
    /// （冲突询问 / 撤销 / 活动中心日志）。拖进自己 / 自己的子孙被过滤。
    private func receiveFolderDrop(_ urls: [URL], into folder: URL) -> Bool {
        guard isExistingDirectory(folder) else { return false }
        let safeURLs = urls.filter { url in
            folder.path != url.path && !(folder.path + "/").hasPrefix(url.path + "/")
        }
        guard !safeURLs.isEmpty else { return false }
        model.dropFileURLs(safeURLs, to: folder, shouldMove: true)
        return true
    }
}

/// 侧栏行的「文件夹投递目标」修饰器：dropDestination + 高亮背景。
/// 抽成 ViewModifier 是因为收藏 / 最近 / 固定三种行结构不同，但投递行为完全一致。
private struct FolderDropTargetModifier: ViewModifier {
    let highlighted: Bool
    let onTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Bool

    func body(content: Content) -> some View {
        content
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
            } isTargeted: { targeted in
                onTargeted(targeted)
            }
    }
}

/// 「个人收藏」侧栏单条目的最小化表示。
/// Finder 真实收藏走 sfl4 路径 → 转成它；解析失败的回落 5 项也用同一类型。
/// 让 List/ForEach 拿到统一形状的数组，避开 `_ConditionalContent` 切换不刷新的怪问题。
private struct FavoriteRow: Identifiable {
    let id: String
    let title: String
    /// `nil` 表示这是 Finder sfl4 读出的真实收藏，图标应按实际路径从 NSWorkspace 取。
    let systemImage: String?
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

/// 侧边栏**动作行**按钮（唯一消费者：固定当前位置）。0.4.2 重绘：白色符号 + 强调色渐变
/// 圆角瓦片,对齐真实文件图标行的 16px 节拍 —— 与设置 / 活动中心侧栏的彩色瓦片同一套语言,
/// 不再是孤零零的灰色模板 Label（用户报「大头针还没重绘」）。
struct SidebarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        SidebarRowButton(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 16, height: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
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
