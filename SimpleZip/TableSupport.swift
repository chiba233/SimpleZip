//
//  TableSupport.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/16.
//

import AppKit

protocol TableColumnDescriptor {
    var identifier: String { get }
    var title: String { get }
    var width: CGFloat { get }
    var minWidth: CGFloat { get }
}

func makeTableScrollView(
    delegate: NSTableViewDelegate & NSTableViewDataSource & NSMenuDelegate,
    target: AnyObject,
    doubleAction: Selector,
    configure: (NSTableView) -> Void = { _ in }
) -> NSScrollView {
    let tableView = NSTableView()
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.allowsColumnReordering = true
    tableView.rowHeight = 28
    tableView.headerView = NSTableHeaderView()
    tableView.delegate = delegate
    tableView.dataSource = delegate
    tableView.doubleAction = doubleAction
    tableView.target = target
    configure(tableView)

    let menu = NSMenu()
    menu.delegate = delegate
    tableView.menu = menu

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = tableView
    scrollView.borderType = .noBorder
    return scrollView
}

func configureTableColumns<Column: TableColumnDescriptor>(_ columns: [Column], for tableView: NSTableView) {
    let columnIDs = columns.map(\.identifier)
    if tableView.tableColumns.map(\.identifier.rawValue) == columnIDs {
        return
    }

    tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
    columns.forEach { column in
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
        tableColumn.title = column.title
        tableColumn.width = column.width
        tableColumn.minWidth = column.minWidth
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: true)
        tableView.addTableColumn(tableColumn)
    }
}

func orderedColumns<Column: TableColumnDescriptor>(_ columns: [Column], key: String) -> [Column] {
    let order = AppPreferences.stringArray(forKey: key)
    guard !order.isEmpty else { return columns }
    let byID = Dictionary(uniqueKeysWithValues: columns.map { ($0.identifier, $0) })
    let ordered = order.compactMap { byID[$0] }
    return ordered + columns.filter { !order.contains($0.identifier) }
}

func makeTableCell(
    in tableView: NSTableView,
    owner: AnyObject,
    identifier: String,
    text: String,
    isPrimaryColumn: Bool,
    icon: NSImage?
) -> NSTableCellView {
    let cellID = NSUserInterfaceItemIdentifier(identifier)
    let cell = tableView.makeView(withIdentifier: cellID, owner: owner) as? NSTableCellView ?? NSTableCellView()
    cell.identifier = cellID
    cell.imageView?.removeFromSuperview()
    cell.textField?.removeFromSuperview()

    let textField = NSTextField(labelWithString: text)
    textField.lineBreakMode = .byTruncatingMiddle
    textField.textColor = isPrimaryColumn ? .labelColor : .secondaryLabelColor
    textField.translatesAutoresizingMaskIntoConstraints = false

    if let icon {
        let imageView = NSImageView(image: icon)
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

func makeTableMenuItem(_ title: String, systemImage: String, action: Selector, target: AnyObject) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = target
    item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    return item
}

func makeColumnSettingsMenu(action: Selector, target: AnyObject) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(makeTableMenuItem(
        L10n.text("settings.editColumns"),
        systemImage: "slider.horizontal.3",
        action: action,
        target: target
    ))
    return menu
}

func openColumnSettingsWindow() {
    SettingsNavigation.requestOpenColumns()
}
