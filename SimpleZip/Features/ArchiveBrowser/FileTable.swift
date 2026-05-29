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

/// 普通文件夹模式下的文件列表。底层使用 NSTableView，以保留 macOS 原生的拖动多选手感。
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
        FileNSTableView(
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

private struct FileNSTableView: NSViewRepresentable {
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
        let scrollView = makeTableScrollView(
            delegate: context.coordinator,
            target: context.coordinator,
            doubleAction: #selector(Coordinator.doubleClick(_:))
        ) { tableView in
            tableView.registerForDraggedTypes([.fileURL])
            tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
            tableView.setDraggingSourceOperationMask(.move, forLocal: true)
            tableView.headerView?.menu = context.coordinator.headerMenu()
            context.coordinator.tableView = tableView
        }
        guard let tableView = scrollView.documentView as? NSTableView else { return scrollView }
        configureColumns(for: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.model = model
        configureColumns(for: tableView)
        tableView.reloadData()
        context.coordinator.applySelection(to: tableView)
    }

    private func configureColumns(for tableView: NSTableView) {
        configureTableColumns(visibleColumns, for: tableView)
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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: ArchiveBrowserModel
        weak var tableView: NSTableView?
        private var isApplyingSelection = false

        init(model: ArchiveBrowserModel) {
            self.model = model
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.fileItems.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < model.fileItems.count, let tableColumn else { return nil }
            let item = model.fileItems[row]
            let column = FileColumn(identifier: tableColumn.identifier.rawValue) ?? .name
            return makeTableCell(
                in: tableView,
                owner: self,
                identifier: "FileCell-\(column.identifier)",
                text: column.value(for: item),
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: item) : nil
            )
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else { return }
            guard let tableView = notification.object as? NSTableView else { return }
            var selection = Set<UUID>()
            for index in tableView.selectedRowIndexes where index < model.fileItems.count {
                selection.insert(model.fileItems[index].id)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selection != selection else { return }
                self.model.selection = selection
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortFileItems(by: key, ascending: descriptor.ascending)
            tableView.reloadData()
            applySelection(to: tableView)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            AppPreferences.setStringArray(tableView.tableColumns.map(\.identifier.rawValue), forKey: AppPreferences.Key.fileColumnOrder)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < model.fileItems.count else { return nil }
            let item = model.fileItems[row]
            if !model.selection.contains(item.id) {
                applySelection(IndexSet(integer: row), to: tableView)
                DispatchQueue.main.async { [weak self] in
                    self?.model.selection = [item.id]
                }
            }
            return item.url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : [.copy, .move]
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard fileDropDestination(in: tableView, row: row, operation: dropOperation) != nil else { return [] }
            tableView.setDropRow(row, dropOperation: dropOperation == .on ? .on : .above)
            return info.draggingSource as? NSTableView === tableView ? .move : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let destination = fileDropDestination(in: tableView, row: row, operation: dropOperation) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            model.dropFileURLs(
                urls,
                to: destination,
                shouldMove: info.draggingSource as? NSTableView === tableView
            )
            return true
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            selectClickedRowIfNeeded(in: tableView)
            menu.removeAllItems()

            // 空白处右键（clickedRow = -1）的菜单要瘦身 —— 像「打开」「以压缩包打开」「解压到这里」
            // 「测试」「哈希」「复制 / 剪切 / 移动 / 删除」这些选中文件才有意义的项，没文件可作用就别出现，
            // 否则用户点了之后要么没反应、要么作用在「之前残留的选中」上，体验诡异。
            // 空白菜单只留两项：粘贴（剪贴板里有内容时实际生效）+ 在 Finder 中显示当前文件夹。
            let clickedRow = tableView.clickedRow
            let hasClickedRow = clickedRow >= 0 && clickedRow < model.fileItems.count
            guard hasClickedRow else {
                menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
                menu.addItem(.separator())
                // 用 revealCurrentLocation 不用 revealSelected —— 后者会偏好「残留 selection」，
                // 但用户右键空白处的意图是「打开我现在看的这个文件夹本身」。
                menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealCurrentLocation)))
                return
            }

            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            if let item = model.selectedFileItems.first, model.selectedFileItems.count == 1, model.canShowPackageContents(item) {
                menu.addItem(menuItem(L10n.text("file.showPackageContents"), systemImage: "folder", action: #selector(showPackageContents)))
            }
            // 「以压缩包打开」—— 只在选中单个非目录、且这个文件本身不是已识别的压缩包时显示。
            // 已识别的压缩包用普通「打开」就够了；目录或多选时这个命令没意义。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               !ArchiveService.isSupportedArchive(item.url) {
                menu.addItem(menuItem(L10n.text("file.openAsArchive"), systemImage: "doc.zipper", action: #selector(openSelectedAsArchive)))
            }
            menu.addItem(menuItem(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square", action: #selector(addSelectedToArchive)))
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

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < model.fileItems.count else { return }
            model.open(model.fileItems[row])
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

        /// 空白处右键专用：reveal「我现在看的这个文件夹 / 压缩包文件」本身，忽略 selection。
        /// 不能复用 `revealSelected` —— 那个在 folder 模式下会优先 reveal 残留 selection，
        /// 用户右键空白处看到的却是「在 Finder 里高亮上次选中的文件」，不符合直觉。
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

        func applySelection(to tableView: NSTableView) {
            let indexes = IndexSet(model.fileItems.enumerated().compactMap { index, item in
                model.selection.contains(item.id) ? index : nil
            })
            if tableView.selectedRowIndexes != indexes {
                DispatchQueue.main.async { [weak self, weak tableView] in
                    guard let self, let tableView, tableView.selectedRowIndexes != indexes else { return }
                    self.applySelection(indexes, to: tableView)
                }
            }
        }

        private func selectClickedRowIfNeeded(in tableView: NSTableView) {
            let row = tableView.clickedRow
            guard row >= 0, row < model.fileItems.count else { return }
            let item = model.fileItems[row]
            if !model.selection.contains(item.id) {
                applySelection(IndexSet(integer: row), to: tableView)
                DispatchQueue.main.async { [weak self] in
                    self?.model.selection = [item.id]
                }
            }
        }

        private func applySelection(_ indexes: IndexSet, to tableView: NSTableView) {
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func menuItem(_ title: String, systemImage: String, action: Selector) -> NSMenuItem {
            makeTableMenuItem(title, systemImage: systemImage, action: action, target: self)
        }

        private func fileDropDestination(
            in tableView: NSTableView,
            row: Int,
            operation: NSTableView.DropOperation
        ) -> URL? {
            if operation == .on, row >= 0, row < model.fileItems.count {
                let item = model.fileItems[row]
                return item.isDirectory && !model.canShowPackageContents(item) ? item.url : nil
            }
            if case .folder(let url) = model.mode {
                return url
            }
            return nil
        }

        func headerMenu() -> NSMenu {
            makeColumnSettingsMenu(action: #selector(openColumnSettings), target: self)
        }

        @objc private func openColumnSettings() {
            openColumnSettingsWindow()
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
