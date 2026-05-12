//
//  ArchiveTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI

/// 压缩包模式下的内容列表。底层使用 NSTableView，支持鼠标拖动选择多行。
struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showMethodColumn = true

    var body: some View {
        ZStack {
            ArchiveNSTableView(
                model: model,
                showSizeColumn: showSizeColumn,
                showModifiedColumn: showModifiedColumn,
                showMethodColumn: showMethodColumn
            )

            if model.archiveItems.isEmpty && model.isWorking {
                ProgressView(L10n.text("status.readingArchive"))
                    .padding()
            }
        }
    }
}

private struct ArchiveNSTableView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let showSizeColumn: Bool
    let showModifiedColumn: Bool
    let showMethodColumn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 28
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.target = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
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
            tableView.addTableColumn(tableColumn)
        }
    }

    private var visibleColumns: [ArchiveColumn] {
        var columns: [ArchiveColumn] = [.name]
        if showSizeColumn { columns.append(.size) }
        if showModifiedColumn { columns.append(.modified) }
        if showMethodColumn { columns.append(.method) }
        return columns
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: ArchiveBrowserModel
        weak var tableView: NSTableView?
        private var isApplyingSelection = false

        init(model: ArchiveBrowserModel) {
            self.model = model
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.archiveItems.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < model.archiveItems.count, let tableColumn else { return nil }
            let item = model.archiveItems[row]
            let column = ArchiveColumn(identifier: tableColumn.identifier.rawValue) ?? .name
            let cellID = NSUserInterfaceItemIdentifier("ArchiveCell-\(column.identifier)")

            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID
            cell.imageView?.removeFromSuperview()
            cell.textField?.removeFromSuperview()

            let textField = NSTextField(labelWithString: column.value(for: item))
            textField.lineBreakMode = .byTruncatingMiddle
            textField.textColor = column == .name ? .labelColor : .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false

            if column == .name {
                let symbolName = item.isDirectory ? "folder.fill" : "doc"
                let imageView = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
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
            for index in tableView.selectedRowIndexes where index < model.archiveItems.count {
                selection.insert(model.archiveItems[index].id)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selectedArchiveRows != selection else { return }
                self.model.selectedArchiveRows = selection
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            selectClickedRowIfNeeded(in: tableView)
            menu.removeAllItems()
            menu.addItem(menuItem(L10n.text("button.open"), #selector(openSelected)))
            menu.addItem(menuItem(L10n.text("button.extractSelected"), #selector(extractSelected)))
            menu.addItem(menuItem(L10n.text("button.extract"), #selector(extractWholeArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), #selector(testArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), #selector(hashArchive)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), #selector(revealArchive)))
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < model.archiveItems.count else { return }
            model.open(model.archiveItems[row])
        }

        @objc private func openSelected() {
            if let item = model.selectedArchiveItems.first {
                model.open(item)
            }
        }

        @objc private func extractSelected() {
            model.extractSelectedArchiveItems()
        }

        @objc private func extractWholeArchive() {
            model.extractArchive()
        }

        @objc private func testArchive() {
            model.testArchive()
        }

        @objc private func hashArchive() {
            model.calculateHash()
        }

        @objc private func revealArchive() {
            model.revealInFinder()
        }

        func applySelection(to tableView: NSTableView) {
            let indexes = IndexSet(model.archiveItems.enumerated().compactMap { index, item in
                model.selectedArchiveRows.contains(item.id) ? index : nil
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
            guard row >= 0, row < model.archiveItems.count else { return }
            let item = model.archiveItems[row]
            if !model.selectedArchiveRows.contains(item.id) {
                applySelection(IndexSet(integer: row), to: tableView)
                DispatchQueue.main.async { [weak self] in
                    self?.model.selectedArchiveRows = [item.id]
                }
            }
        }

        private func applySelection(_ indexes: IndexSet, to tableView: NSTableView) {
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
    }
}

private enum ArchiveColumn: String {
    case name
    case size
    case modified
    case method

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
        case .modified:
            return L10n.text("column.modified")
        case .method:
            return L10n.text("column.method")
        }
    }

    var width: CGFloat {
        switch self {
        case .name:
            return 520
        case .size:
            return 120
        case .modified:
            return 180
        case .method:
            return 120
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:
            return 260
        case .size:
            return 90
        case .modified:
            return 140
        case .method:
            return 90
        }
    }

    func value(for item: ArchiveItem) -> String {
        switch self {
        case .name:
            return item.displayName
        case .size:
            return item.sizeText
        case .modified:
            return item.modifiedText
        case .method:
            return item.method
        }
    }
}
