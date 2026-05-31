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

/// 表头右键菜单的两种 scope —— 文件浏览 vs 压缩包浏览。
///
/// 0.1.10 之前用「Edit Columns…」一项打开 Settings columns pane；columns 整体迁到 View 菜单后，
/// 表头右键直接把同一组开关 inline 出来更符合 Finder 习惯，也省了用户「右键 → 弹设置窗 → 找 columns 分页」两步跳转。
enum ColumnHeaderMenuScope {
    case fileBrowser
    case archiveBrowser

    /// 该 scope 下顺序展示的 (L10n label key, UserDefaults key, 未设置时默认是否显示) 列表。
    /// 顺序跟 ViewMenu 子菜单一致，保证两处 UI 体验一致。
    /// `defaultsToTrue` —— 用来匹配各 Pref accessor 的 default 语义（defaultTrueBool vs 直接 defaults.bool），
    /// 否则首次右键时菜单 ✓ 会和列实际可见性脱钩。
    var entries: [(labelKey: String, defaultsKey: String, defaultsToTrue: Bool)] {
        switch self {
        case .fileBrowser:
            return [
                ("column.size", AppPreferences.Key.showFileSizeColumn, true),
                ("column.kind", AppPreferences.Key.showFileTypeColumn, true),
                ("column.application", AppPreferences.Key.showFileApplicationColumn, true),
                ("column.lastOpened", AppPreferences.Key.showFileLastOpenedColumn, true),
                ("column.dateAdded", AppPreferences.Key.showFileDateAddedColumn, true),
                ("column.modified", AppPreferences.Key.showFileModifiedColumn, true),
                ("column.created", AppPreferences.Key.showFileCreatedColumn, true)
            ]
        case .archiveBrowser:
            return [
                ("column.path", AppPreferences.Key.showArchivePathColumn, false),
                ("column.kind", AppPreferences.Key.showArchiveKindColumn, true),
                ("column.size", AppPreferences.Key.showArchiveSizeColumn, true),
                ("column.packedSize", AppPreferences.Key.showArchivePackedSizeColumn, false),
                ("column.modified", AppPreferences.Key.showArchiveModifiedColumn, true),
                ("column.created", AppPreferences.Key.showArchiveCreatedColumn, false),
                ("column.method", AppPreferences.Key.showArchiveMethodColumn, true),
                ("column.crc", AppPreferences.Key.showArchiveCrcColumn, false),
                ("column.attributes", AppPreferences.Key.showArchiveAttributesColumn, false),
                ("column.encrypted", AppPreferences.Key.showArchiveEncryptedColumn, false)
            ]
        }
    }
}

/// `representedObject` 不能直接装 Swift tuple，用一个轻量 NSObject 包 (defaultsKey, defaultsToTrue)。
@MainActor
final class ColumnHeaderMenuBinding: NSObject {
    let key: String
    let defaultsToTrue: Bool
    init(key: String, defaultsToTrue: Bool) {
        self.key = key
        self.defaultsToTrue = defaultsToTrue
    }
}

/// 表头右键菜单 item 的 target + menu delegate —— 每个 menu item 在 representedObject 里带上自己控制的 UserDefaults key，
/// 点击时翻转。AppStorage 自动监听 UserDefaults 变化触发 SwiftUI 重渲染，所以这里只需要 set，不需要 post 通知。
///
/// 同时实现 NSMenuDelegate：菜单是构造一次后挂在 headerView.menu 上反复使用，
/// 不在 menuNeedsUpdate 里重新读 UserDefaults，就会一直显示构造那一刻的 ✓，而不是当前真实状态。
///
/// 列可见性偏好走 default-true 语义（AppPreferences.defaultTrueBool）：键未写过时视为 true，列默认显示。
/// 这里读 / 翻转都必须遵循同一语义，否则首次右键时所有 ✓ 都会显示为「未勾选」，但表里列却是显示的 —— 状态不一致。
@MainActor
final class ColumnHeaderMenuTarget: NSObject, NSMenuDelegate {
    static let shared = ColumnHeaderMenuTarget()
    private override init() { super.init() }

    fileprivate func currentValue(for binding: ColumnHeaderMenuBinding) -> Bool {
        if UserDefaults.standard.object(forKey: binding.key) == nil {
            return binding.defaultsToTrue
        }
        return UserDefaults.standard.bool(forKey: binding.key)
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let binding = sender.representedObject as? ColumnHeaderMenuBinding else { return }
        UserDefaults.standard.set(!currentValue(for: binding), forKey: binding.key)
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            for item in menu.items {
                guard let binding = item.representedObject as? ColumnHeaderMenuBinding else { continue }
                item.state = currentValue(for: binding) ? .on : .off
            }
        }
    }
}

@MainActor
func makeColumnHeaderMenu(scope: ColumnHeaderMenuScope) -> NSMenu {
    let menu = NSMenu()
    menu.delegate = ColumnHeaderMenuTarget.shared
    for (labelKey, defaultsKey, defaultsToTrue) in scope.entries {
        let item = NSMenuItem(
            title: L10n.text(labelKey),
            action: #selector(ColumnHeaderMenuTarget.toggleColumn(_:)),
            keyEquivalent: ""
        )
        item.target = ColumnHeaderMenuTarget.shared
        item.representedObject = ColumnHeaderMenuBinding(key: defaultsKey, defaultsToTrue: defaultsToTrue)
        // 初始 state 在菜单首次弹出前由 menuNeedsUpdate 覆盖；这里不画也行。
        menu.addItem(item)
    }
    return menu
}
