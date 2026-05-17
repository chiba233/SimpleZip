//
//  ArchiveTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 压缩包模式下的内容列表。底层使用 NSTableView，支持鼠标拖动选择多行。
struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showArchiveKindColumn) private var showKindColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showMethodColumn = true

    var body: some View {
        ZStack {
            ArchiveNSTableView(
                model: model,
                showKindColumn: showKindColumn,
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
    let showKindColumn: Bool
    let showSizeColumn: Bool
    let showModifiedColumn: Bool
    let showMethodColumn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeTableScrollView(
            delegate: context.coordinator,
            target: context.coordinator,
            doubleAction: #selector(Coordinator.doubleClick(_:))
        ) { tableView in
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
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

    private var visibleColumns: [ArchiveColumn] {
        var columns: [ArchiveColumn] = [.name]
        if showKindColumn { columns.append(.kind) }
        if showSizeColumn { columns.append(.size) }
        if showModifiedColumn { columns.append(.modified) }
        if showMethodColumn { columns.append(.method) }
        return orderedColumns(columns, key: AppPreferences.Key.archiveColumnOrder)
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
            return makeTableCell(
                in: tableView,
                owner: self,
                identifier: "ArchiveCell-\(column.identifier)",
                text: column.value(for: item),
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: item) : nil
            )
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

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortArchiveItems(by: key, ascending: descriptor.ascending)
            tableView.reloadData()
            applySelection(to: tableView)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            AppPreferences.setStringArray(tableView.tableColumns.map(\.identifier.rawValue), forKey: AppPreferences.Key.archiveColumnOrder)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < model.archiveItems.count else { return nil }
            let item = model.archiveItems[row]
            if !model.selectedArchiveRows.contains(item.id) {
                applySelection(IndexSet(integer: row), to: tableView)
                DispatchQueue.main.async { [weak self] in
                    self?.model.selectedArchiveRows = [item.id]
                }
            }
            let provider = NSFilePromiseProvider(fileType: promisedFileType(for: item), delegate: self)
            provider.userInfo = item
            return provider
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            selectClickedRowIfNeeded(in: tableView)
            menu.removeAllItems()
            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            menu.addItem(menuItem(L10n.text("button.extractSelected"), systemImage: "arrow.down.doc", action: #selector(extractSelected)))
            menu.addItem(menuItem(L10n.text("button.extract"), systemImage: "tray.and.arrow.down", action: #selector(extractWholeArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashArchive)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealArchive)))
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

        private func menuItem(_ title: String, systemImage: String, action: Selector) -> NSMenuItem {
            makeTableMenuItem(title, systemImage: systemImage, action: action, target: self)
        }

        func headerMenu() -> NSMenu {
            makeColumnSettingsMenu(action: #selector(openColumnSettings), target: self)
        }

        @objc private func openColumnSettings() {
            openColumnSettingsWindow()
        }

        private func icon(for item: ArchiveItem) -> NSImage {
            if item.isDirectory {
                return NSWorkspace.shared.icon(for: .folder)
            }
            let ext = URL(fileURLWithPath: item.displayName).pathExtension
            if let contentType = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: contentType)
            }
            return NSImage(systemSymbolName: "doc", accessibilityDescription: item.displayName) ?? NSImage()
        }

        private func promisedFileType(for item: ArchiveItem) -> String {
            if item.isDirectory {
                return UTType.folder.identifier
            }
            let ext = URL(fileURLWithPath: item.displayName).pathExtension
            return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        }
    }
}

extension ArchiveNSTableView.Coordinator: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let item = filePromiseProvider.userInfo as? ArchiveItem else {
            return L10n.text("type.file")
        }
        return item.displayName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let item = filePromiseProvider.userInfo as? ArchiveItem else {
            completionHandler(ArchiveError.extractedItemNotFound)
            return
        }
        Task { @MainActor [model] in
            do {
                try await model.exportArchiveItem(item, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

private enum ArchiveColumn: String, TableColumnDescriptor {
    case name
    case kind
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
        case .kind:
            return L10n.text("column.kind")
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
            return 400
        case .kind:
            return 160
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
        case .kind:
            return 120
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
        case .kind:
            return item.typeDescription
        case .size:
            return item.sizeText
        case .modified:
            return item.modifiedText
        case .method:
            return item.method
        }
    }
}
