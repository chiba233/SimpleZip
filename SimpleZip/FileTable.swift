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
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.rowHeight = 28
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.target = context.coordinator
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        tableView.headerView?.menu = context.coordinator.headerMenu()
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.borderType = .noBorder

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
        let columnIDs = visibleColumns.map(\.identifier)
        if tableView.tableColumns.map(\.identifier.rawValue) == columnIDs {
            return
        }

        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        visibleColumns.forEach { column in
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
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
            let cellID = NSUserInterfaceItemIdentifier("FileCell-\(column.identifier)")

            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID
            cell.imageView?.removeFromSuperview()
            cell.textField?.removeFromSuperview()

            let textField = NSTextField(labelWithString: column.value(for: item))
            textField.lineBreakMode = .byTruncatingMiddle
            textField.textColor = column == .name ? .labelColor : .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false

            if column == .name {
                let imageView = NSImageView(image: icon(for: item))
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.addSubview(textField)
                cell.imageView = imageView
                cell.textField = textField

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            return cell
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

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            selectClickedRowIfNeeded(in: tableView)
            menu.removeAllItems()
            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", #selector(openSelected)))
            menu.addItem(menuItem(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square", #selector(addSelectedToArchive)))
            menu.addItem(menuItem(L10n.text("button.extractHere"), systemImage: "arrow.down.doc", #selector(extractSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", #selector(testSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", #selector(hashSelected)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("file.copy"), systemImage: "doc.on.doc", #selector(copySelected)))
            menu.addItem(menuItem(L10n.text("file.cut"), systemImage: "scissors", #selector(cutSelected)))
            menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", #selector(pasteFiles)))
            menu.addItem(menuItem(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape", #selector(moveSelected)))
            menu.addItem(menuItem(L10n.text("file.delete"), systemImage: "trash", #selector(deleteSelected)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", #selector(revealSelected)))
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

        private func menuItem(_ title: String, systemImage: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            return item
        }

        func headerMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem(L10n.text("settings.editColumns"), systemImage: "slider.horizontal.3", #selector(openColumnSettings)))
            return menu
        }

        @objc private func openColumnSettings() {
            NotificationCenter.default.post(name: .openSettingsColumns, object: nil)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }

        private func icon(for item: FileItem) -> NSImage {
            if item.isDirectory {
                return NSWorkspace.shared.icon(for: .folder)
            }
            return NSWorkspace.shared.icon(forFile: item.url.path)
        }
    }
}

private func orderedColumns(_ columns: [FileColumn], key: String) -> [FileColumn] {
    let order = AppPreferences.stringArray(forKey: key)
    guard !order.isEmpty else { return columns }
    let byID = Dictionary(uniqueKeysWithValues: columns.map { ($0.identifier, $0) })
    let ordered = order.compactMap { byID[$0] }
    return ordered + columns.filter { !order.contains($0.identifier) }
}

private enum FileColumn: String {
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
            return item.name
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
