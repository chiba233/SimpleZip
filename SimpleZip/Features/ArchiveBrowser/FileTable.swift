//
//  FileTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 文件夹模式下的文件列表。底层使用 NSOutlineView：可见文件在顶层，OS 隐藏文件（dotfile / 隐藏标志）
/// 收进一个默认折叠的「隐藏文件」分组节点，点开才展开。保留 macOS 原生的拖动多选手感。
struct FileTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileApplicationColumn) private var showApplicationColumn = true
    @AppStorage(AppPreferences.Key.showFileLastOpenedColumn) private var showLastOpenedColumn = true
    @AppStorage(AppPreferences.Key.showFileDateAddedColumn) private var showDateAddedColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showFileCreatedColumn) private var showCreatedColumn = true

    var body: some View {
        FileNSOutlineView(
            model: model,
            showSizeColumn: showSizeColumn,
            showTypeColumn: showTypeColumn,
            showApplicationColumn: showApplicationColumn,
            showLastOpenedColumn: showLastOpenedColumn,
            showDateAddedColumn: showDateAddedColumn,
            showModifiedColumn: showModifiedColumn,
            showCreatedColumn: showCreatedColumn
        )
    }
}

/// 大纲节点：要么是一个文件行，要么是「隐藏文件」分组头。
/// 用 class（引用类型）是因为 NSOutlineView 按对象身份跟踪展开状态 —— 分组头用一个稳定的单例实例。
@MainActor
private final class FileOutlineNode {
    enum Kind {
        case file(FileItem)
        case hiddenGroup
    }

    let kind: Kind
    /// 仅 `.hiddenGroup` 用：当前隐藏文件条数，渲染「隐藏文件 (N)」用。
    var hiddenCount = 0

    init(kind: Kind) {
        self.kind = kind
    }

    var fileItem: FileItem? {
        if case .file(let item) = kind { return item }
        return nil
    }

    var isHiddenGroup: Bool {
        if case .hiddenGroup = kind { return true }
        return false
    }
}

private struct FileNSOutlineView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let showSizeColumn: Bool
    let showTypeColumn: Bool
    let showApplicationColumn: Bool
    let showLastOpenedColumn: Bool
    let showDateAddedColumn: Bool
    let showModifiedColumn: Bool
    let showCreatedColumn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeOutlineScrollView(
            delegate: context.coordinator,
            target: context.coordinator,
            doubleAction: #selector(Coordinator.doubleClick(_:))
        ) { outlineView in
            outlineView.registerForDraggedTypes([.fileURL])
            outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
            outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
            outlineView.headerView?.menu = context.coordinator.headerMenu()
            context.coordinator.outlineView = outlineView
        }
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return scrollView }
        configureColumns(for: outlineView)
        context.coordinator.syncContent()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.model = model
        configureColumns(for: outlineView)
        context.coordinator.syncContent()
        context.coordinator.applySelection()
    }

    private func configureColumns(for outlineView: NSOutlineView) {
        configureTableColumns(visibleColumns, for: outlineView)
        // 「隐藏文件」分组的 disclosure 三角挂在 name 列上。
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.identifier))
    }

    private var visibleColumns: [FileColumn] {
        var columns: [FileColumn] = [.name]
        if showSizeColumn { columns.append(.size) }
        if showTypeColumn { columns.append(.type) }
        if showApplicationColumn { columns.append(.application) }
        if showLastOpenedColumn { columns.append(.lastOpened) }
        if showDateAddedColumn { columns.append(.dateAdded) }
        if showModifiedColumn { columns.append(.modified) }
        if showCreatedColumn { columns.append(.created) }
        return orderedColumns(columns, key: AppPreferences.Key.fileColumnOrder)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: ArchiveBrowserModel
        weak var outlineView: NSOutlineView?
        private var isApplyingSelection = false
        private var isSyncingExpansion = false

        // 从 model.fileItems 拆出来的两段；分组头是稳定单例，保证展开状态跨 reloadData 不丢。
        private var visibleNodes: [FileOutlineNode] = []
        private var hiddenNodes: [FileOutlineNode] = []
        private let hiddenGroupNode = FileOutlineNode(kind: .hiddenGroup)
        private var showsHiddenGroup: Bool { !hiddenNodes.isEmpty }

        // 展开状态的真值由这里持有；进新文件夹时按折叠记忆策略 seed，用户手动展开 / 折叠时持久化。
        private var groupExpanded = false
        private var lastFolderKey: String?

        init(model: ArchiveBrowserModel) {
            self.model = model
        }

        /// 当前位置的 key，用于 `.rememberPerFolder` 记忆。
        private var currentFolderKey: String {
            switch model.mode {
            case .folder(let url): return url.standardizedFileURL.path
            case .tag(let tag): return "tag:\(tag)"
            case .archive(let url): return "archive:\(url.standardizedFileURL.path)"
            }
        }

        /// 重建节点 + reload + 强制同步展开状态。make / update 都走这里。
        func syncContent() {
            let split = FileBrowserOutline.split(model.fileItems)
            visibleNodes = split.visible.map { FileOutlineNode(kind: .file($0)) }
            hiddenNodes = split.hidden.map { FileOutlineNode(kind: .file($0)) }
            hiddenGroupNode.hiddenCount = hiddenNodes.count

            // 进入新文件夹时按折叠记忆策略决定初始展开；同一文件夹内的增量 reload 保留当前展开状态。
            let key = currentFolderKey
            if key != lastFolderKey {
                lastFolderKey = key
                groupExpanded = FileBrowserOutline.initialExpanded(
                    mode: AppPreferences.hiddenGroupCollapseMode,
                    folderKey: key,
                    perFolderExpanded: AppPreferences.hiddenGroupExpandedFolders,
                    globalExpanded: AppPreferences.hiddenGroupGlobalExpanded
                )
            }

            outlineView?.reloadData()
            enforceExpansion()
        }

        private func enforceExpansion() {
            guard let outlineView, showsHiddenGroup else { return }
            isSyncingExpansion = true
            if groupExpanded {
                outlineView.expandItem(hiddenGroupNode)
            } else {
                outlineView.collapseItem(hiddenGroupNode)
            }
            isSyncingExpansion = false
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileOutlineNode else {
                return visibleNodes.count + (showsHiddenGroup ? 1 : 0)
            }
            return node.isHiddenGroup ? hiddenNodes.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileOutlineNode else {
                if index < visibleNodes.count { return visibleNodes[index] }
                return hiddenGroupNode
            }
            guard node.isHiddenGroup, index < hiddenNodes.count else { return hiddenGroupNode }
            return hiddenNodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileOutlineNode)?.isHiddenGroup == true
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileOutlineNode, let tableColumn else { return nil }
            let column = FileColumn(identifier: tableColumn.identifier.rawValue) ?? .name

            if node.isHiddenGroup {
                // 分组头只在 name 列画「隐藏文件 (N)」+ 图标；其它列留空。
                guard column == .name else { return nil }
                return makeTableCell(
                    in: outlineView,
                    owner: self,
                    identifier: "FileCell-hiddenGroup",
                    text: L10n.format("file.hiddenGroup", node.hiddenCount),
                    isPrimaryColumn: true,
                    icon: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
                )
            }

            guard let fileItem = node.fileItem else { return nil }
            return makeTableCell(
                in: outlineView,
                owner: self,
                identifier: "FileCell-\(column.identifier)",
                text: column.value(for: fileItem),
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: fileItem) : nil
            )
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outlineView else { return }
            var selection = Set<UUID>()
            for index in outlineView.selectedRowIndexes {
                if let node = outlineView.item(atRow: index) as? FileOutlineNode, let item = node.fileItem {
                    selection.insert(item.id)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selection != selection else { return }
                self.model.selection = selection
            }
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortFileItems(by: key, ascending: descriptor.ascending)
            syncContent()
            applySelection()
        }

        func outlineViewColumnDidMove(_ notification: Notification) {
            guard let outlineView else { return }
            AppPreferences.setStringArray(outlineView.tableColumns.map(\.identifier.rawValue), forKey: AppPreferences.Key.fileColumnOrder)
        }

        // 用户手动展开 / 折叠隐藏分组 —— 更新真值 + 按策略持久化。
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion, isHiddenGroupNotification(notification) else { return }
            groupExpanded = true
            persistExpansion(true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion, isHiddenGroupNotification(notification) else { return }
            groupExpanded = false
            persistExpansion(false)
        }

        private func isHiddenGroupNotification(_ notification: Notification) -> Bool {
            (notification.userInfo?["NSObject"] as? FileOutlineNode)?.isHiddenGroup == true
        }

        private func persistExpansion(_ expanded: Bool) {
            let mode = AppPreferences.hiddenGroupCollapseMode
            switch mode {
            case .alwaysCollapsed:
                break // 不记忆
            case .rememberPerFolder:
                AppPreferences.hiddenGroupExpandedFolders = FileBrowserOutline.updatedPerFolderExpanded(
                    AppPreferences.hiddenGroupExpandedFolders,
                    folderKey: currentFolderKey,
                    expanded: expanded,
                    mode: mode
                )
            case .globalSticky:
                AppPreferences.hiddenGroupGlobalExpanded = expanded
            }
        }

        // MARK: - 拖拽

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileOutlineNode, let fileItem = node.fileItem else { return nil }
            if !model.selection.contains(fileItem.id) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { applySelection(IndexSet(integer: row)) }
                DispatchQueue.main.async { [weak self] in
                    self?.model.selection = [fileItem.id]
                }
            }
            return fileItem.url as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : [.copy, .move]
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard fileDropDestination(item: item, childIndex: index) != nil else { return [] }
            return info.draggingSource as? NSOutlineView === outlineView ? .move : .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let destination = fileDropDestination(item: item, childIndex: index) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            model.dropFileURLs(
                urls,
                to: destination,
                shouldMove: info.draggingSource as? NSOutlineView === outlineView
            )
            return true
        }

        // MARK: - 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            selectClickedRowIfNeeded(in: outlineView)
            menu.removeAllItems()

            // 空白处 / 分组头右键（无有效文件行）的菜单瘦身：只留粘贴 + 在 Finder 中显示当前文件夹。
            // 选中文件才有意义的项（打开 / 解压 / 测试 / 哈希 / 复制剪切移动删除）没文件可作用就别出现。
            let clickedItem = outlineView.clickedRow >= 0 ? outlineView.item(atRow: outlineView.clickedRow) : nil
            let clickedFile = (clickedItem as? FileOutlineNode)?.fileItem
            guard clickedFile != nil else {
                menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
                menu.addItem(.separator())
                // 用 revealCurrentLocation 不用 revealSelected —— 用户右键空白处的意图是「打开我现在看的这个文件夹本身」。
                menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealCurrentLocation)))
                return
            }

            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            if let item = model.selectedFileItems.first, model.selectedFileItems.count == 1, model.canShowPackageContents(item) {
                menu.addItem(menuItem(L10n.text("file.showPackageContents"), systemImage: "folder", action: #selector(showPackageContents)))
            }
            // 选中单个 `.szs` 时多一项「以虚拟目录浏览」—— 走静默验签，OK 就直接进，有问题才弹 alert。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               item.url.pathExtension.lowercased() == SZSArchive.extensionName {
                menu.addItem(menuItem(L10n.text("szs.silentBrowse.menuItem"), systemImage: "folder.badge.questionmark", action: #selector(silentBrowseSelectedSZS)))
            }
            // 「以压缩包打开」—— 只在选中单个非目录、且不是已识别压缩包时显示。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               !ArchiveService.isSupportedArchive(item.url) {
                menu.addItem(menuItem(L10n.text("file.openAsArchive"), systemImage: "doc.zipper", action: #selector(openSelectedAsArchive)))
            }
            menu.addItem(menuItem(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square", action: #selector(addSelectedToArchive)))
            // 创建签名清单 —— 仅 GPG 启用 + 后端可用时出现。
            if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                menu.addItem(menuItem(L10n.text("szs.create.menuItem"), systemImage: "doc.text.badge.plus", action: #selector(createSignedManifestFromSelection)))
            }
            menu.addItem(menuItem(L10n.text("button.extractHere"), systemImage: "arrow.down.doc", action: #selector(extractSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashSelected)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("file.copy"), systemImage: "doc.on.doc", action: #selector(copySelected)))
            menu.addItem(menuItem(L10n.text("file.cut"), systemImage: "scissors", action: #selector(cutSelected)))
            menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
            menu.addItem(menuItem(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape", action: #selector(moveSelected)))
            menu.addItem(menuItem(L10n.text("file.delete"), systemImage: "trash", action: #selector(deleteSelected)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealSelected)))
        }

        @objc func doubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileOutlineNode else { return }
            if node.isHiddenGroup {
                // 双击分组头 = 切换展开（同样触发 didExpand/didCollapse → 更新真值 + 持久化）。
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
                return
            }
            if let item = node.fileItem {
                model.open(item)
            }
        }

        @objc private func openSelected() {
            if let item = model.selectedFileItems.first {
                model.open(item)
            }
        }

        @objc private func openSelectedAsArchive() {
            if let item = model.selectedFileItems.first {
                model.openAsArchive(item.url)
            }
        }

        @objc private func showPackageContents() {
            if let item = model.selectedFileItems.first {
                model.showPackageContents(item)
            }
        }

        @objc private func addSelectedToArchive() {
            model.createArchive()
        }

        @objc private func createSignedManifestFromSelection() {
            model.createSignedManifest()
        }

        @objc private func silentBrowseSelectedSZS() {
            if let url = model.selectedFileItems.first?.url {
                model.pendingSZSSilentVirtualBrowse = url
            }
        }

        @objc private func extractSelectedArchive() {
            model.extractArchive()
        }

        @objc private func testSelectedArchive() {
            model.testArchive()
        }

        @objc private func hashSelected() {
            model.calculateHash()
        }

        @objc private func revealSelected() {
            model.revealInFinder()
        }

        /// 空白处右键专用：reveal「我现在看的这个文件夹」本身，忽略 selection。
        @objc private func revealCurrentLocation() {
            model.revealCurrentLocationInFinder()
        }

        @objc private func copySelected() {
            model.copySelectedFiles()
        }

        @objc private func cutSelected() {
            model.cutSelectedFiles()
        }

        @objc private func pasteFiles() {
            model.pasteFiles()
        }

        @objc private func moveSelected() {
            model.moveSelectedFilesToFolder()
        }

        @objc private func deleteSelected() {
            model.deleteSelectedFiles()
        }

        // MARK: - 选择同步

        func applySelection() {
            guard let outlineView else { return }
            var indexes = IndexSet()
            for node in visibleNodes + hiddenNodes {
                guard let item = node.fileItem, model.selection.contains(item.id) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { indexes.insert(row) }
            }
            if outlineView.selectedRowIndexes != indexes {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let outlineView = self.outlineView, outlineView.selectedRowIndexes != indexes else { return }
                    self.applySelection(indexes)
                }
            }
        }

        private func selectClickedRowIfNeeded(in outlineView: NSOutlineView) {
            let row = outlineView.clickedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? FileOutlineNode, let item = node.fileItem else { return }
            if !model.selection.contains(item.id) {
                applySelection(IndexSet(integer: row))
                DispatchQueue.main.async { [weak self] in
                    self?.model.selection = [item.id]
                }
            }
        }

        private func applySelection(_ indexes: IndexSet) {
            guard let outlineView else { return }
            isApplyingSelection = true
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func menuItem(_ title: String, systemImage: String, action: Selector) -> NSMenuItem {
            makeTableMenuItem(title, systemImage: systemImage, action: action, target: self)
        }

        /// 拖放目标：拖到某个「非包目录」文件行上 → 进那个目录；否则（拖到空白 / 文件 / 分组头）→ 当前文件夹。
        private func fileDropDestination(item: Any?, childIndex index: Int) -> URL? {
            if index == NSOutlineViewDropOnItemIndex,
               let node = item as? FileOutlineNode,
               let fileItem = node.fileItem,
               fileItem.isDirectory,
               !model.canShowPackageContents(fileItem) {
                return fileItem.url
            }
            if case .folder(let url) = model.mode {
                return url
            }
            return nil
        }

        func headerMenu() -> NSMenu {
            makeColumnHeaderMenu(scope: .fileBrowser)
        }

        private func icon(for item: FileItem) -> NSImage {
            if item.isDirectory, !item.isSymbolicLink, !model.canShowPackageContents(item) {
                return NSWorkspace.shared.icon(for: .folder)
            }
            return NSWorkspace.shared.icon(forFile: item.url.path)
        }
    }
}

enum FileColumn: String, TableColumnDescriptor {
    case name
    case size
    case type
    case application
    case lastOpened
    case dateAdded
    case modified
    case created

    init?(identifier: String) {
        self.init(rawValue: identifier)
    }

    var identifier: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return L10n.text("column.name")
        case .size:
            return L10n.text("column.size")
        case .type:
            return L10n.text("column.kind")
        case .application:
            return L10n.text("column.application")
        case .lastOpened:
            return L10n.text("column.lastOpened")
        case .dateAdded:
            return L10n.text("column.dateAdded")
        case .modified:
            return L10n.text("column.modified")
        case .created:
            return L10n.text("column.created")
        }
    }

    var width: CGFloat {
        switch self {
        case .name:
            return 420
        case .size:
            return 110
        case .type:
            return 180
        case .application:
            return 160
        case .lastOpened, .dateAdded, .modified, .created:
            return 170
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:
            return 240
        case .size:
            return 90
        case .type:
            return 120
        case .application:
            return 120
        case .lastOpened, .dateAdded, .modified, .created:
            return 140
        }
    }

    func value(for item: FileItem) -> String {
        switch self {
        case .name:
            return item.displayName
        case .size:
            return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        case .type:
            return item.typeDescription
        case .application:
            return item.applicationName
        case .lastOpened:
            return item.lastOpened.map(Self.dateFormatter.string(from:)) ?? ""
        case .dateAdded:
            return item.dateAdded.map(Self.dateFormatter.string(from:)) ?? ""
        case .modified:
            return item.modified.map(Self.dateFormatter.string(from:)) ?? ""
        case .created:
            return item.created.map(Self.dateFormatter.string(from:)) ?? ""
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
