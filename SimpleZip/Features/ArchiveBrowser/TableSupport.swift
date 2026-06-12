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
    // 0.3.3 UI 现代化：.inset = Big Sur+ 的现代表格样式（圆角选中条 + 两侧留白），
    // 默认 .automatic 在我们这种非 SwiftUI List 宿主里落到老式通栏选中，像旧 macOS。
    tableView.style = .inset
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

func makeOutlineScrollView(
    delegate: NSOutlineViewDelegate & NSOutlineViewDataSource & NSMenuDelegate,
    target: AnyObject,
    doubleAction: Selector,
    configure: (NSOutlineView) -> Void = { _ in }
) -> NSScrollView {
    let outlineView = ContentDragOutlineView()
    // 同上：现代圆角选中样式（文件浏览 / 压缩包浏览两张表共用这里）。
    outlineView.style = .inset
    outlineView.usesAlternatingRowBackgroundColors = false
    outlineView.allowsMultipleSelection = true
    outlineView.allowsEmptySelection = true
    outlineView.allowsColumnReordering = true
    outlineView.rowHeight = 28
    outlineView.indentationPerLevel = 14
    // 隐藏分组的 disclosure 三角跟着 name 列走（outlineTableColumn 在 configureTableColumns 之后设）。
    outlineView.headerView = NSTableHeaderView()
    outlineView.delegate = delegate
    outlineView.dataSource = delegate
    outlineView.doubleAction = doubleAction
    outlineView.target = target
    configure(outlineView)

    let menu = NSMenu()
    menu.delegate = delegate
    outlineView.menu = menu

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = outlineView
    scrollView.borderType = .noBorder
    return scrollView
}

func configureTableColumns<Column: TableColumnDescriptor>(_ columns: [Column], for tableView: NSTableView) {
    // 按 identifier 去重 —— 防御损坏的列顺序偏好（曾出现 fileColumnOrder 里堆了多个 "name"，
    // 导致拖动 / 切换列后出现 2~3 个重复的「名称」列）。即使 orderedColumns 已去重，这里再兜一层。
    var seenIdentifiers = Set<String>()
    let uniqueColumns = columns.filter { seenIdentifiers.insert($0.identifier).inserted }
    let columnIDs = uniqueColumns.map(\.identifier)
    let currentIDs = tableView.tableColumns.map(\.identifier.rawValue)
    // 已是目标列集**且当前没有重复 identifier** 才跳过。current 里若已混入重复列（见下方兜底说明），
    // 必须落到重建路径把它清掉，不能因为「列集看着对」就 return 把重复留着。
    let currentHasDuplicates = Set(currentIDs).count != currentIDs.count
    if currentIDs == columnIDs, !currentHasDuplicates {
        return
    }

    // NSOutlineView 拒绝删除当前 outlineTableColumn（name 列）—— 不先解绑，removeTableColumn 删不掉它，
    // 每次重建都残留旧 name 列再叠加一个新的，「名称」列越积越多。调用方（FileTable/ArchiveTable）
    // 在本函数返回后会重新把 outlineTableColumn 指回 name 列。
    (tableView as? NSOutlineView)?.outlineTableColumn = nil
    tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
    uniqueColumns.forEach { column in
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
        tableColumn.title = column.title
        tableColumn.width = column.width
        tableColumn.minWidth = column.minWidth
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: true)
        tableView.addTableColumn(tableColumn)
    }

    // 兜底去重（关键）：某些 macOS 版本下 `outlineTableColumn = nil` 不会真正解绑旧 name 列，
    // 上面的 removeTableColumn 删不掉它，于是重建后表里出现 2 个相同 identifier 的「名称」列。
    // 这里再扫一遍真实 tableColumns，把重复 identifier 的列删到每个只剩一个（保留先出现的）。
    var seenColumnIDs = Set<String>()
    let duplicateColumns = tableView.tableColumns.filter { !seenColumnIDs.insert($0.identifier.rawValue).inserted }
    if !duplicateColumns.isEmpty {
        (tableView as? NSOutlineView)?.outlineTableColumn = nil
        duplicateColumns.forEach { tableView.removeTableColumn($0) }
    }

    // 把每个幸存列的宽度按描述符钉回去。关键:去重「保留先出现的」——在 macOS 26 上 `outlineTableColumn = nil`
    // 删不掉的那个**旧 name 列**就是「先出现的」,被保留;新加的(宽度正确 420)反而被当重复删掉。旧 name 列带着
    // 上几轮 autoresize 累积的旧宽度,不重置就会**每切一次列越变越宽**(用户报「名称列特别长」)。这里统一钉回描述符宽度。
    let widthByID = Dictionary(uniqueKeysWithValues: uniqueColumns.map { ($0.identifier, $0) })
    for tableColumn in tableView.tableColumns {
        guard let descriptor = widthByID[tableColumn.identifier.rawValue] else { continue }
        tableColumn.width = descriptor.width
        tableColumn.minWidth = descriptor.minWidth
    }
}

func orderedColumns<Column: TableColumnDescriptor>(_ columns: [Column], key: String) -> [Column] {
    let rawOrder = AppPreferences.stringArray(forKey: key)
    guard !rawOrder.isEmpty else { return columns }
    // 去掉重复 identifier —— 修复曾经被 outlineTableColumn bug 污染成 ["name","name",…] 的存量偏好，
    // 否则 compactMap 会把同一列映射出多份，重建时又冒出重复「名称」列。
    var seen = Set<String>()
    let order = rawOrder.filter { seen.insert($0).inserted }
    let byID = Dictionary(uniqueKeysWithValues: columns.map { ($0.identifier, $0) })
    let ordered = order.compactMap { byID[$0] }
    return ordered + columns.filter { !order.contains($0.identifier) }
}

/// makeTableCell 的真复用载体：记录构建时的布局参数（有无图标 / 图标尺寸），
/// 复用时结构匹配才走「只刷内容」快路径。结构由 identifier（列）+ 这两个参数共同决定；
/// 行密度切换会改 iconSize，此时回退到完整重建分支，旧约束不会被错误沿用。
private final class ReusableTableCellView: NSTableCellView {
    var configuredIconSize: CGFloat = -1
}

func makeTableCell(
    in tableView: NSTableView,
    owner: AnyObject,
    identifier: String,
    text: String,
    isPrimaryColumn: Bool,
    icon: NSImage?,
    iconSize: CGFloat = 18,
    font: NSFont = .systemFont(ofSize: 13)
) -> NSTableCellView {
    let cellID = NSUserInterfaceItemIdentifier(identifier)
    let reused = tableView.makeView(withIdentifier: cellID, owner: owner) as? NSTableCellView
    // 真复用快路径：以前这里对复用 cell 也全拆 textField/imageView 重建 + 重新 activate 约束，
    // 复用名存实亡 —— /Applications 滚动时每行每列每帧都在重建视图树（#16 实测主线程大头之一）。
    // 同 identifier ⇒ 同列同布局，结构参数匹配时只更新内容。
    let wantedIconSize = icon == nil ? CGFloat(0) : iconSize
    if let reusable = reused as? ReusableTableCellView,
       reusable.configuredIconSize == wantedIconSize,
       let textField = reusable.textField {
        // 防御内联重命名残留：beginRename 会把 textField 改成可编辑带边框（以前靠整体重建自动重置）。
        if textField.isEditable {
            textField.isEditable = false
            textField.isSelectable = false
            textField.isBordered = false
            textField.drawsBackground = false
            textField.delegate = nil
        }
        textField.stringValue = text
        textField.font = font
        textField.textColor = isPrimaryColumn ? .labelColor : .secondaryLabelColor
        reusable.imageView?.image = icon
        return reusable
    }

    let cell = reused as? ReusableTableCellView ?? ReusableTableCellView()
    cell.identifier = cellID
    cell.configuredIconSize = wantedIconSize
    cell.imageView?.removeFromSuperview()
    cell.textField?.removeFromSuperview()

    let textField = NSTextField(labelWithString: text)
    textField.lineBreakMode = .byTruncatingMiddle
    textField.font = font
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
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
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
                ("column.created", AppPreferences.Key.showFileCreatedColumn, true),
                ("column.symlink", AppPreferences.Key.showFileSymlinkColumn, false),
                ("column.permissions", AppPreferences.Key.showFilePermissionsColumn, false),
                ("column.owner", AppPreferences.Key.showFileOwnerColumn, false)
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
                ("column.accessed", AppPreferences.Key.showArchiveAccessedColumn, false),
                ("column.hostOS", AppPreferences.Key.showArchiveHostOSColumn, false),
                ("column.characteristics", AppPreferences.Key.showArchiveCharacteristicsColumn, false),
                ("column.symlink", AppPreferences.Key.showArchiveSymlinkColumn, false),
                ("column.comment", AppPreferences.Key.showArchiveCommentColumn, false),
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
