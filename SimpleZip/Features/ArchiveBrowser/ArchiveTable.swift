//
//  ArchiveTable.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 压缩包模式下的内容列表。底层使用 NSOutlineView：不分类时是扁平行，「按种类」分类时切成可折叠区块。
/// 压缩包没有「隐藏文件」概念，所以比文件浏览器简单：区块默认展开、可折叠、不持久化。
struct ArchiveTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showArchiveKindColumn) private var showKindColumn = true
    @AppStorage(AppPreferences.Key.showArchiveSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showArchiveModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showArchiveMethodColumn) private var showMethodColumn = true
    @AppStorage(AppPreferences.Key.showArchivePathColumn) private var showPathColumn = false
    @AppStorage(AppPreferences.Key.showArchiveEncryptedColumn) private var showEncryptedColumn = false
    @AppStorage(AppPreferences.Key.showArchivePackedSizeColumn) private var showPackedSizeColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCrcColumn) private var showCrcColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCreatedColumn) private var showCreatedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveAttributesColumn) private var showAttributesColumn = false
    // 观察分组方式 —— 在 Settings 改时靠它触发重渲染 → updateNSView → 重新分组。
    @AppStorage(AppPreferences.Key.archiveGroupBy) private var archiveGroupBy = BrowserGrouping.GroupBy.none.rawValue
    @AppStorage(AppPreferences.Key.rowDensity) private var rowDensity = FileBrowserOutline.RowDensity.standard.rawValue

    var body: some View {
        ZStack {
            ArchiveNSOutlineView(
                model: model,
                showKindColumn: showKindColumn,
                showSizeColumn: showSizeColumn,
                showModifiedColumn: showModifiedColumn,
                showMethodColumn: showMethodColumn,
                showPathColumn: showPathColumn,
                showEncryptedColumn: showEncryptedColumn,
                showPackedSizeColumn: showPackedSizeColumn,
                showCrcColumn: showCrcColumn,
                showCreatedColumn: showCreatedColumn,
                showAttributesColumn: showAttributesColumn,
                groupBy: archiveGroupBy,
                rowDensity: rowDensity
            )

            if model.archiveItems.isEmpty && model.isWorking {
                ProgressView(L10n.text("status.readingArchive"))
                    .padding()
            }
        }
    }
}

/// 大纲节点：一个归档条目行，或一个「按种类」分类区块。区块按 sectionKey 跨 reload 复用实例保展开身份。
@MainActor
private final class ArchiveOutlineNode {
    enum Kind {
        case item(ArchiveItem)
        case section
    }

    let kind: Kind
    let sectionKey: String
    var title: String
    var children: [ArchiveOutlineNode]

    private init(kind: Kind, sectionKey: String, title: String) {
        self.kind = kind
        self.sectionKey = sectionKey
        self.title = title
        self.children = []
    }

    static func item(_ item: ArchiveItem) -> ArchiveOutlineNode {
        ArchiveOutlineNode(kind: .item(item), sectionKey: "", title: "")
    }

    static func section(key: String) -> ArchiveOutlineNode {
        ArchiveOutlineNode(kind: .section, sectionKey: key, title: "")
    }

    var archiveItem: ArchiveItem? {
        if case .item(let item) = kind { return item }
        return nil
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }
}

private struct ArchiveNSOutlineView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let showKindColumn: Bool
    let showSizeColumn: Bool
    let showModifiedColumn: Bool
    let showMethodColumn: Bool
    let showPathColumn: Bool
    let showEncryptedColumn: Bool
    let showPackedSizeColumn: Bool
    let showCrcColumn: Bool
    let showCreatedColumn: Bool
    let showAttributesColumn: Bool
    // 仅作变化触发器：值变 → 重建 representable → updateNSView → 重新分组。真值由 coordinator 读 AppPreferences。
    let groupBy: String
    let rowDensity: String

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeOutlineScrollView(
            delegate: context.coordinator,
            target: context.coordinator,
            doubleAction: #selector(Coordinator.doubleClick(_:))
        ) { outlineView in
            outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
            // 拖动只在 name 列图标/文字上起手，行内空白处恢复橡皮筋复选。
            (outlineView as? ContentDragOutlineView)?.primaryColumnIdentifier = ArchiveColumn.name.identifier
            outlineView.headerView?.menu = context.coordinator.headerMenu()
            context.coordinator.outlineView = outlineView
        }
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return scrollView }
        configureColumns(for: outlineView)
        outlineView.rowHeight = AppPreferences.rowDensity.rowHeight
        context.coordinator.syncContent()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.model = model
        configureColumns(for: outlineView)
        // 只在真的变化时赋 rowHeight —— 赋同值也会标记重绘，框选时每帧都赋会加剧闪烁。
        let targetRowHeight = AppPreferences.rowDensity.rowHeight
        if outlineView.rowHeight != targetRowHeight {
            outlineView.rowHeight = targetRowHeight
        }
        context.coordinator.syncContent()
        context.coordinator.applySelection()
    }

    private func configureColumns(for outlineView: NSOutlineView) {
        configureTableColumns(visibleColumns, for: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ArchiveColumn.name.identifier))
    }

    private var visibleColumns: [ArchiveColumn] {
        var columns: [ArchiveColumn] = [.name]
        if showPathColumn { columns.append(.path) }
        if showKindColumn { columns.append(.kind) }
        if showSizeColumn { columns.append(.size) }
        if showPackedSizeColumn { columns.append(.packedSize) }
        if showModifiedColumn { columns.append(.modified) }
        if showCreatedColumn { columns.append(.created) }
        if showMethodColumn { columns.append(.method) }
        if showCrcColumn { columns.append(.crc) }
        if showAttributesColumn { columns.append(.attributes) }
        if showEncryptedColumn { columns.append(.encrypted) }
        return orderedColumns(columns, key: AppPreferences.Key.archiveColumnOrder)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: ArchiveBrowserModel
        weak var outlineView: NSOutlineView?
        private var isApplyingSelection = false
        private var isSyncingExpansion = false

        private var topLevelNodes: [ArchiveOutlineNode] = []
        private var sectionNodesByKey: [String: ArchiveOutlineNode] = [:]
        // 分类区块默认展开；用户手动折叠的记这里（不持久化，分类维度变时清空）。
        private var userCollapsedSectionKeys: Set<String> = []
        private var lastGroupBy: BrowserGrouping.GroupBy?
        // 上次真正 reloadData 时的「内容指纹」。选区变化不改它 → 跳过 reload，避免橡皮筋复选时闪烁 / 抽搐。
        private var lastContentSignature: Int?

        init(model: ArchiveBrowserModel) {
            self.model = model
        }

        func syncContent() {
            let groupBy = AppPreferences.effectiveArchiveGroupBy
            // 内容指纹 = 分组维度 + 行密度 + 可见列 + 当前 archiveItems 实例。**不含选区**。
            // 选区变化不改 archiveItems → 指纹不变 → 跳过 reloadData，避免橡皮筋复选闪烁 / 抽搐。
            var hasher = Hasher()
            hasher.combine(groupBy.rawValue)
            hasher.combine(AppPreferences.rowDensity.rawValue)
            hasher.combine(outlineView?.tableColumns.map { $0.identifier.rawValue }.joined(separator: ",") ?? "")
            for item in model.archiveItems { hasher.combine(item.id) }
            let contentSignature = hasher.finalize()
            guard contentSignature != lastContentSignature else { return }
            lastContentSignature = contentSignature

            if groupBy != lastGroupBy {
                lastGroupBy = groupBy
                userCollapsedSectionKeys = []
            }
            rebuildTopLevel(groupBy: groupBy)
            outlineView?.reloadData()
            enforceExpansion()
        }

        private func rebuildTopLevel(groupBy: BrowserGrouping.GroupBy) {
            var reused: [String: ArchiveOutlineNode] = [:]
            if groupBy.isGrouping {
                topLevelNodes = BrowserGrouping.group(model.archiveItems, by: groupBy, now: Date()).map { section in
                    let key = "g:\(section.title)"
                    let node = sectionNodesByKey[key] ?? ArchiveOutlineNode.section(key: key)
                    node.title = "\(section.title) (\(section.items.count))"
                    node.children = section.items.map { ArchiveOutlineNode.item($0) }
                    reused[key] = node
                    return node
                }
            } else {
                topLevelNodes = model.archiveItems.map { ArchiveOutlineNode.item($0) }
            }
            sectionNodesByKey = reused
        }

        private func allItemNodes() -> [ArchiveOutlineNode] {
            topLevelNodes.flatMap { $0.isSection ? $0.children : [$0] }
        }

        private func enforceExpansion() {
            guard let outlineView else { return }
            isSyncingExpansion = true
            for node in topLevelNodes where node.isSection {
                if userCollapsedSectionKeys.contains(node.sectionKey) {
                    outlineView.collapseItem(node)
                } else {
                    outlineView.expandItem(node)
                }
            }
            isSyncingExpansion = false
        }

        // MARK: - DataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? ArchiveOutlineNode else { return topLevelNodes.count }
            return node.isSection ? node.children.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? ArchiveOutlineNode else {
                return index < topLevelNodes.count ? topLevelNodes[index] : topLevelNodes
            }
            guard index < node.children.count else { return node }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ArchiveOutlineNode)?.isSection == true
        }

        // MARK: - Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ArchiveOutlineNode, let tableColumn else { return nil }
            let column = ArchiveColumn(identifier: tableColumn.identifier.rawValue) ?? .name
            let density = AppPreferences.rowDensity

            if node.isSection {
                guard column == .name else { return nil }
                return makeTableCell(
                    in: outlineView,
                    owner: self,
                    identifier: "ArchiveCell-section",
                    text: node.title,
                    isPrimaryColumn: true,
                    icon: NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2", accessibilityDescription: nil),
                    iconSize: density.iconSize,
                    font: .systemFont(ofSize: density.textPointSize)
                )
            }

            guard let item = node.archiveItem else { return nil }
            return makeTableCell(
                in: outlineView,
                owner: self,
                identifier: "ArchiveCell-\(column.identifier)",
                text: column.value(for: item),
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: item) : nil,
                iconSize: density.iconSize,
                font: .systemFont(ofSize: density.textPointSize)
            )
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outlineView else { return }
            var selection = Set<UUID>()
            for index in outlineView.selectedRowIndexes {
                if let node = outlineView.item(atRow: index) as? ArchiveOutlineNode, let item = node.archiveItem {
                    selection.insert(item.id)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selectedArchiveRows != selection else { return }
                self.model.selectedArchiveRows = selection
            }
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortArchiveItems(by: key, ascending: descriptor.ascending)
            syncContent()
            applySelection()
        }

        func outlineViewColumnDidMove(_ notification: Notification) {
            guard let outlineView else { return }
            AppPreferences.setStringArray(outlineView.tableColumns.map(\.identifier.rawValue), forKey: AppPreferences.Key.archiveColumnOrder)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion, let node = sectionNode(from: notification) else { return }
            userCollapsedSectionKeys.remove(node.sectionKey)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion, let node = sectionNode(from: notification) else { return }
            userCollapsedSectionKeys.insert(node.sectionKey)
        }

        private func sectionNode(from notification: Notification) -> ArchiveOutlineNode? {
            guard let node = notification.userInfo?["NSObject"] as? ArchiveOutlineNode, node.isSection else { return nil }
            return node
        }

        // MARK: - 拖拽（仅拖出，file promise）

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? ArchiveOutlineNode, let archiveItem = node.archiveItem else { return nil }
            // 按下点不在图标/文件名上 → 不提供拖动项，让 AppKit 回退到橡皮筋复选。
            if let dragView = outlineView as? ContentDragOutlineView, !dragView.dragAllowedFromMouseDown { return nil }
            if !model.selectedArchiveRows.contains(archiveItem.id) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { applySelection(IndexSet(integer: row)) }
                DispatchQueue.main.async { [weak self] in
                    self?.model.selectedArchiveRows = [archiveItem.id]
                }
            }
            let provider = NSFilePromiseProvider(fileType: promisedFileType(for: archiveItem), delegate: self)
            provider.userInfo = archiveItem
            return provider
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        // MARK: - 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            selectClickedRowIfNeeded(in: outlineView)
            menu.removeAllItems()
            // 区块头 / 空白处右键：没有有效条目就不出操作项。
            let clickedItem = outlineView.clickedRow >= 0 ? outlineView.item(atRow: outlineView.clickedRow) : nil
            guard (clickedItem as? ArchiveOutlineNode)?.archiveItem != nil else { return }

            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            menu.addItem(menuItem(L10n.text("button.extractSelected"), systemImage: "arrow.down.doc", action: #selector(extractSelected)))
            menu.addItem(menuItem(L10n.text("button.extract"), systemImage: "tray.and.arrow.down", action: #selector(extractWholeArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashArchive)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealArchive)))
        }

        @objc func doubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? ArchiveOutlineNode else { return }
            if node.isSection {
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
                return
            }
            if let item = node.archiveItem {
                model.open(item)
            }
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

        // MARK: - 选择同步

        func applySelection() {
            guard let outlineView else { return }
            // 鼠标按下（框选 / 拖动中）时不回灌选区，避免跟 live 橡皮筋打架（闪烁 / 抽搐）。松手后再同步。
            if NSEvent.pressedMouseButtons & 0x1 != 0 { return }
            var indexes = IndexSet()
            for node in allItemNodes() {
                guard let item = node.archiveItem, model.selectedArchiveRows.contains(item.id) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { indexes.insert(row) }
            }
            // 保留导航到的分组头行（无 archiveItem、不进选区），否则方向键碰到分组头选区归零、跨不过组。
            for row in outlineView.selectedRowIndexes where (outlineView.item(atRow: row) as? ArchiveOutlineNode)?.isSection == true {
                indexes.insert(row)
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
            guard row >= 0, let node = outlineView.item(atRow: row) as? ArchiveOutlineNode, let item = node.archiveItem else { return }
            if !model.selectedArchiveRows.contains(item.id) {
                applySelection(IndexSet(integer: row))
                // 同步更新（与 FileTable 同理）：menuNeedsUpdate 紧接着同步读 selectedArchiveItems 构建菜单，
                // 异步会导致菜单作用在上一次的选区上。
                model.selectedArchiveRows = [item.id]
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

        func headerMenu() -> NSMenu {
            makeColumnHeaderMenu(scope: .archiveBrowser)
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

@MainActor
extension ArchiveNSOutlineView.Coordinator: NSFilePromiseProviderDelegate {
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.model.exportArchiveItem(item, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

enum ArchiveColumn: String, TableColumnDescriptor {
    case name
    case kind
    case size
    case modified
    case method
    // 0.1.10 起的可选列。path / encrypted 不需要 parser 工作（ArchiveItem 已有字段），
    // packedSize / crc / created / attributes 走 7zz -slt 输出；zip 后备路径和 DMG 后端会留空。
    case path
    case encrypted
    case packedSize
    case crc
    case created
    case attributes

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
        case .path:
            return L10n.text("column.path")
        case .encrypted:
            return L10n.text("column.encrypted")
        case .packedSize:
            return L10n.text("column.packedSize")
        case .crc:
            return L10n.text("column.crc")
        case .created:
            return L10n.text("column.created")
        case .attributes:
            return L10n.text("column.attributes")
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
        case .path:
            return 280
        case .encrypted:
            return 80
        case .packedSize:
            return 120
        case .crc:
            return 110
        case .created:
            return 180
        case .attributes:
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
        case .path:
            return 160
        case .encrypted:
            return 60
        case .packedSize:
            return 90
        case .crc:
            return 80
        case .created:
            return 140
        case .attributes:
            return 80
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
        case .path:
            return item.name
        case .encrypted:
            // 用 SF Symbol 「锁」字符代替 Yes/No；空字符串明确「未加密」时不画。
            return item.isEncrypted ? "🔒" : ""
        case .packedSize:
            return item.packedSizeText
        case .crc:
            return item.crc
        case .created:
            return item.createdText
        case .attributes:
            return item.attributes
        }
    }
}
