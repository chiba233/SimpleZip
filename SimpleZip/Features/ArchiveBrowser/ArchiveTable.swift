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
    @AppStorage(AppPreferences.Key.showArchiveAccessedColumn) private var showAccessedColumn = false
    @AppStorage(AppPreferences.Key.showArchiveHostOSColumn) private var showHostOSColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCharacteristicsColumn) private var showCharacteristicsColumn = false
    @AppStorage(AppPreferences.Key.showArchiveSymlinkColumn) private var showSymlinkColumn = false
    @AppStorage(AppPreferences.Key.showArchiveCommentColumn) private var showCommentColumn = false
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
                showAccessedColumn: showAccessedColumn,
                showHostOSColumn: showHostOSColumn,
                showCharacteristicsColumn: showCharacteristicsColumn,
                showSymlinkColumn: showSymlinkColumn,
                showCommentColumn: showCommentColumn,
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
    let showAccessedColumn: Bool
    let showHostOSColumn: Bool
    let showCharacteristicsColumn: Bool
    let showSymlinkColumn: Bool
    let showCommentColumn: Bool
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
            // Return 键 + 重压文字区 → 内联重命名（跟文件浏览器同一 idiom）。可编辑归档里才会真正进入编辑。
            (outlineView as? ContentDragOutlineView)?.returnKeyAction = { [weak coordinator = context.coordinator] in
                coordinator?.beginRenameSelectedArchiveEntry() ?? false
            }
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
        if showAccessedColumn { columns.append(.accessed) }
        if showHostOSColumn { columns.append(.hostOS) }
        if showCharacteristicsColumn { columns.append(.characteristics) }
        if showSymlinkColumn { columns.append(.symlink) }
        if showCommentColumn { columns.append(.comment) }
        if showEncryptedColumn { columns.append(.encrypted) }
        return orderedColumns(columns, key: AppPreferences.Key.archiveColumnOrder)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var model: ArchiveBrowserModel
        weak var outlineView: NSOutlineView?
        private var isApplyingSelection = false
        /// 内联重命名进行中的条目（跟文件浏览器同一 idiom）。
        private var renamingArchiveItem: ArchiveItem?
        /// Esc 取消标记 —— `control(_:textView:doCommandBy:)` 置位，`controlTextDidEndEditing` 据此跳过改名。
        private var renameCancelled = false
        private var isSyncingExpansion = false

        private var topLevelNodes: [ArchiveOutlineNode] = []
        private var sectionNodesByKey: [String: ArchiveOutlineNode] = [:]
        // 分类区块默认展开；用户手动折叠的记这里（不持久化，分类维度变时清空）。
        private var userCollapsedSectionKeys: Set<String> = []
        private var lastGroupBy: BrowserGrouping.GroupBy?
        // 上次真正 reloadData 时的「内容指纹」。选区变化不改它 → 跳过 reload，避免橡皮筋复选时闪烁 / 抽搐。
        private var lastContentSignature: Int?

        // 拖出解压（file promise）的**后台**串行队列。
        // ⚠️ 必须有:不提供时 AppKit 会在**主线程**等承诺完成,而我们的 `writePromiseTo` 用
        // `Task { @MainActor }` 跑解压(也要主线程)→ 主线程被占住、Task 永远跑不了 → `completionHandler`
        // 永不调用 → 拖拽 spinner 永久卡死(含安全弹窗 `runModal` 嵌套在拖拽流程里的叠加死锁)。
        // 放到后台队列后,AppKit 在此队列等待,主线程空出来跑解压 + 必要的安全确认弹窗,不再死锁。
        private let filePromiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.simplezip.archive.filePromise"
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

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
            for item in model.displayedArchiveItems { hasher.combine(item.id) }
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
            performPendingInlineRenameIfNeeded()
        }

        /// 新建归档条目后自动进入内联重命名（跟文件夹模式 pendingInlineRenameURL 同一 idiom）。
        private func performPendingInlineRenameIfNeeded() {
            guard renamingArchiveItem == nil, let entryPath = model.pendingInlineRenameArchiveEntry else { return }
            // 目录条目的 name 可能带尾斜杠 → 去掉再比。
            func normalize(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
            guard let node = allItemNodes().first(where: { ($0.archiveItem?.name).map(normalize) == normalize(entryPath) }),
                  let item = node.archiveItem,
                  let outlineView, outlineView.row(forItem: node) >= 0 else { return }  // 还没出现 → 留着下次 reload 再试
            model.selectedArchiveRows = [item.id]
            applySelection(IndexSet(integer: outlineView.row(forItem: node)))
            if beginInlineRename(item) {
                model.pendingInlineRenameArchiveEntry = nil
            }
        }

        private func rebuildTopLevel(groupBy: BrowserGrouping.GroupBy) {
            var reused: [String: ArchiveOutlineNode] = [:]
            if groupBy.isGrouping {
                topLevelNodes = BrowserGrouping.group(model.displayedArchiveItems, by: groupBy, now: Date()).map { section in
                    let key = "g:\(section.title)"
                    let node = sectionNodesByKey[key] ?? ArchiveOutlineNode.section(key: key)
                    node.title = "\(section.title) (\(section.items.count))"
                    node.children = section.items.map { ArchiveOutlineNode.item($0) }
                    reused[key] = node
                    return node
                }
            } else {
                topLevelNodes = model.displayedArchiveItems.map { ArchiveOutlineNode.item($0) }
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
            // 按 identifier 去重再存 —— 绝不把重复列写回偏好（与文件表同一防护）。
            var seen = Set<String>()
            let ids = outlineView.tableColumns.map(\.identifier.rawValue).filter { seen.insert($0).inserted }
            AppPreferences.setStringArray(ids, forKey: AppPreferences.Key.archiveColumnOrder)
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
            let clickedItem = outlineView.clickedRow >= 0 ? outlineView.item(atRow: outlineView.clickedRow) : nil
            let clickedArchiveItem = (clickedItem as? ArchiveOutlineNode)?.archiveItem

            // 空白处 / 区块头右键：可编辑归档给完整「添加 / 粘贴 / 新建 / 注释 / 清理 / 重复检测」入口；
            // 只读归档(tar/rar/嵌套/临时)仅给只读分析入口（重复检测 + 刷新）—— 这些不写归档,任何格式都该可用。
            guard let item = clickedArchiveItem else {
                if model.canDropIntoOpenArchive {
                    appendArchiveBlankAreaMenu(to: menu)
                } else {
                    menu.addItem(menuItem(L10n.text("duplicates.menu"), systemImage: "doc.on.doc", action: #selector(findDuplicateFiles)))
                    menu.addItem(menuItem(L10n.text("contentSearch.menu"), systemImage: "text.magnifyingglass", action: #selector(searchArchiveContents)))
                    menu.addItem(menuItem(L10n.text("security.report.title"), systemImage: "shield.lefthalf.filled", action: #selector(showSecurityReport)))
                    menu.addItem(menuItem(L10n.text("help.refresh"), systemImage: "arrow.clockwise", action: #selector(refreshArchive)))
                    menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealArchive)))
                }
                return
            }

            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            // 「打开方式 ▸」—— 单选时出现，**不白名单**：任何格式的条目解出来都能用外部 app 打开。
            if model.selectedArchiveItems.count == 1, !item.isDirectory {
                appendArchiveOpenWithMenu(to: menu, for: item)
            }
            // 0.4.2 #10：快速预览（解到临时副本，关归档自动清理）+ 单文件「保存副本到…」。
            if !item.isDirectory {
                menu.addItem(menuItem(L10n.text("file.quickLook"), systemImage: "eye", action: #selector(quickLookArchiveEntry)))
            }
            if model.selectedArchiveItems.count == 1, !item.isDirectory {
                menu.addItem(menuItem(L10n.text("archive.saveCopyAs"), systemImage: "square.and.arrow.down", action: #selector(saveArchiveEntryCopy)))
            }
            menu.addItem(menuItem(L10n.text("button.extractSelected"), systemImage: "arrow.down.doc", action: #selector(extractSelected)))
            menu.addItem(menuItem(L10n.text("button.extract"), systemImage: "tray.and.arrow.down", action: #selector(extractWholeArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashArchive)))

            // 编辑类操作（增 / 删 / 改名 / 粘贴）—— **白名单**：仅对可编辑的真实 zip/7z 顶层归档显示，
            // 不支持的格式（tar/rar/嵌套/临时）整段不出现（#109）。
            if model.canDropIntoOpenArchive {
                menu.addItem(.separator())
                menu.addItem(menuItem(L10n.text("archive.addFiles"), systemImage: "plus.rectangle.on.folder", action: #selector(addFilesToArchive)))
                if model.clipboardHasFileURLsForArchivePaste {
                    menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteIntoArchive)))
                }
                // 重命名仅单个普通文件；多选文件 → 批量重命名（0.4.2 #11）。
                if model.selectedArchiveItems.count == 1, model.selectedArchiveItems.first?.isDirectory == false {
                    menu.addItem(menuItem(L10n.text("file.rename"), systemImage: "pencil", action: #selector(renameArchiveEntry)))
                } else if model.selectedArchiveItems.filter({ !$0.isDirectory }).count >= 2 {
                    menu.addItem(menuItem(L10n.text("archive.batchRename.menu"), systemImage: "pencil.line", action: #selector(batchRenameEntries)))
                }
                menu.addItem(menuItem(L10n.text("file.delete"), systemImage: "trash", action: #selector(deleteArchiveEntries)))
            }

            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealArchive)))
        }

        /// 空白处右键菜单（可编辑归档）：添加文件 / 粘贴 / 新建文件夹 / 新建文件 / Reveal。
        private func appendArchiveBlankAreaMenu(to menu: NSMenu) {
            menu.addItem(menuItem(L10n.text("archive.addFiles"), systemImage: "plus.rectangle.on.folder", action: #selector(addFilesToArchive)))
            if model.clipboardHasFileURLsForArchivePaste {
                menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteIntoArchive)))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("file.newFolder"), systemImage: "folder.badge.plus", action: #selector(newArchiveFolder)))
            // 「新建文件 ▸」复用文件浏览器的 NewFileTemplate 模板子菜单（空 / 文本 / Markdown / JSON）。
            let newFileParent = NSMenuItem(title: L10n.text("file.newFile"), action: nil, keyEquivalent: "")
            newFileParent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            let submenu = NSMenu()
            for template in ArchiveBrowserModel.NewFileTemplate.allCases {
                let mi = NSMenuItem(title: template.title, action: #selector(newArchiveFile(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = template.rawValue
                mi.image = NSImage(systemSymbolName: template.systemImage, accessibilityDescription: nil)
                submenu.addItem(mi)
            }
            newFileParent.submenu = submenu
            menu.addItem(newFileParent)
            menu.addItem(.separator())
            // 0.4.2：zip 归档级注释编辑（EOCD 原生改写）。没有注释时这是唯一的「添加注释」入口。
            if model.canEditArchiveComment {
                menu.addItem(menuItem(L10n.text("archive.comment.menu"), systemImage: "text.bubble", action: #selector(editArchiveComment)))
            } else if model.canDropIntoOpenArchive {
                // 0.4.3 #13:可写包但非 zip —— 显式解释「注释仅 ZIP 支持」,不再静默消失留人疑惑。
                let unavailable = NSMenuItem(title: L10n.text("archive.comment.zipOnly.menu"), action: nil, keyEquivalent: "")
                unavailable.isEnabled = false
                menu.addItem(unavailable)
            }
            // 0.4.2 #24：包内重复文件检测（只读分析，任何归档都可用）。
            menu.addItem(menuItem(L10n.text("duplicates.menu"), systemImage: "doc.on.doc", action: #selector(findDuplicateFiles)))
            // #11:内容搜索(只文本/限大小/主动触发/临时区即用即删)。
            menu.addItem(menuItem(L10n.text("contentSearch.menu"), systemImage: "text.magnifyingglass", action: #selector(searchArchiveContents)))
            // 0.4.2 #7 跟进：路径安全报告(只读分析,干净包显示绿色全清) —— 之前只在动态工具栏/操作菜单,右键孤儿。
            menu.addItem(menuItem(L10n.text("security.report.title"), systemImage: "shield.lefthalf.filled", action: #selector(showSecurityReport)))
            // 0.4.4 #13:归档元数据报告(头部块属性 + 条目聚合,只读)。
            menu.addItem(menuItem(L10n.text("metadata.menu"), systemImage: "info.square", action: #selector(showMetadataReport)))
            // 0.4.2 #16：清理 macOS 元数据 —— 有垃圾条目时显示（带数量），删掉走安全写回。
            let junkCount = model.archiveJunkEntryCount
            if junkCount > 0 {
                menu.addItem(menuItem(L10n.format("archive.cleanJunk.menu", "\(junkCount)"), systemImage: "paintbrush", action: #selector(cleanJunkEntries)))
            }
            menu.addItem(menuItem(L10n.text("help.refresh"), systemImage: "arrow.clockwise", action: #selector(refreshArchive)))
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealArchive)))
        }

        /// 「打开方式 ▸」子菜单 —— 用条目扩展名探测能打开此类型的 app（条目还在归档里、没有真实 URL）。
        private func appendArchiveOpenWithMenu(to menu: NSMenu, for item: ArchiveItem) {
            let submenu = NSMenu()
            for appURL in OpenWithService.applicationURLs(forFileNamed: item.displayName) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                let mi = NSMenuItem(title: name, action: #selector(openArchiveItemWithApp(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = appURL
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
                submenu.addItem(mi)
            }
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            let other = NSMenuItem(title: L10n.text("file.openWith.other"), action: #selector(openArchiveItemWithOtherApp), keyEquivalent: "")
            other.target = self
            submenu.addItem(other)
            let parent = NSMenuItem(title: L10n.text("file.openWith"), action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        @objc private func openArchiveItemWithApp(_ sender: NSMenuItem) {
            guard let appURL = sender.representedObject as? URL, let item = model.selectedArchiveItems.first else { return }
            model.openArchiveItemExternally(item, openWith: .app(appURL))
        }

        @objc private func openArchiveItemWithOtherApp() {
            guard let item = model.selectedArchiveItems.first else { return }
            model.openArchiveItemExternally(item, openWith: .chooseApp)
        }

        @objc private func newArchiveFolder() {
            model.createNewFolderAndBeginRename()   // 同一 API,归档模式自动走加条目分支
        }

        @objc private func newArchiveFile(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let template = ArchiveBrowserModel.NewFileTemplate(rawValue: raw) else { return }
            model.createNewFileAndBeginRename(template: template)
        }

        @objc private func addFilesToArchive() {
            model.addArchiveFilesViaPanel()
        }

        @objc private func pasteIntoArchive() {
            model.pasteIntoOpenArchive()
        }

        @objc private func renameArchiveEntry() {
            beginRenameSelectedArchiveEntry()
        }

        // MARK: - 内联重命名（复用文件浏览器同一 idiom：把名字列的 textField 变可编辑，不弹窗）

        /// 开始内联重命名选中条目（仅普通文件）。返回是否真的进入了编辑（给 returnKeyAction / 重压用——文件浏览器同款）。
        @discardableResult
        func beginRenameSelectedArchiveEntry() -> Bool {
            guard model.canDropIntoOpenArchive,
                  model.selectedArchiveItems.count == 1,
                  let item = model.selectedArchiveItems.first, !item.isDirectory else { return false }
            return beginInlineRename(item)
        }

        /// 内联重命名核心 —— 把指定条目名字列的 textField 变可编辑。新建条目后的「建完进重命名」也走这条（含文件夹）。
        @discardableResult
        private func beginInlineRename(_ item: ArchiveItem) -> Bool {
            guard let outlineView,
                  let nameColIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ArchiveColumn.name.identifier }),
                  let node = allItemNodes().first(where: { $0.archiveItem?.id == item.id })
            else { return false }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return false }
            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: nameColIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let textField = cell.textField else { return false }

            renamingArchiveItem = item
            textField.isEditable = true
            textField.isSelectable = true
            textField.isBordered = true
            textField.bezelStyle = .squareBezel
            textField.drawsBackground = true
            textField.delegate = self
            textField.stringValue = item.displayName
            outlineView.window?.makeFirstResponder(textField)
            // 像 Finder：默认选中不含扩展名的主名。
            if let editor = textField.currentEditor() {
                let name = item.displayName
                let stem = (name as NSString).deletingPathExtension
                let length = stem.isEmpty ? (name as NSString).length : (stem as NSString).length
                editor.selectedRange = NSRange(location: 0, length: length)
            }
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField, let item = renamingArchiveItem else { return }
            renamingArchiveItem = nil
            let cancelled = renameCancelled
            renameCancelled = false
            let newName = textField.stringValue

            // 还原成 label 外观（成功 rename 后 reload 会换成新名）。
            textField.isEditable = false
            textField.isSelectable = false
            textField.isBordered = false
            textField.drawsBackground = false
            textField.delegate = nil
            textField.stringValue = item.displayName

            let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? NSTextMovement.other.rawValue
            guard !cancelled, movement != NSTextMovement.cancel.rawValue else { return }
            model.renameArchiveEntry(item, to: newName)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard renamingArchiveItem != nil else { return false }
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                renameCancelled = true
                outlineView?.window?.makeFirstResponder(outlineView)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                outlineView?.window?.makeFirstResponder(outlineView)
                return true
            default:
                return false
            }
        }

        @objc private func deleteArchiveEntries() {
            model.deleteSelectedArchiveEntries()
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

        @objc private func refreshArchive() {
            model.reload()
        }

        @objc private func editArchiveComment() {
            model.showsArchiveCommentEditor = true
        }

        @objc private func quickLookArchiveEntry() {
            model.quickLookSelectedArchiveItems { [weak self] urls in
                (self?.outlineView as? ContentDragOutlineView)?.presentQuickLook(urls: urls)
            }
        }

        @objc private func saveArchiveEntryCopy() {
            model.saveSelectedArchiveItemCopy()
        }

        @objc private func batchRenameEntries() {
            model.requestBatchRename()
        }

        @objc private func cleanJunkEntries() {
            model.cleanArchiveJunkEntries()
        }

        @objc private func findDuplicateFiles() {
            model.findDuplicateFilesInArchive()
        }

        @objc private func searchArchiveContents() {
            model.promptContentSearch()
        }

        @objc private func showMetadataReport() {
            model.showArchiveMetadataReport()
        }

        @objc private func showSecurityReport() {
            model.showsArchiveSecurityReport = true
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
            // 内联重命名进行中：不回灌选区，否则 selectRowIndexes 会结束字段编辑、输入框瞬间消失。
            if renamingArchiveItem != nil { return }
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
    /// 承诺写出跑在**后台**队列 —— 见 `filePromiseQueue` 注释:不提供会让 AppKit 在主线程死等、
    /// 与主线程上的解压 / 安全弹窗互锁,拖出永久卡死。
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        filePromiseQueue
    }

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
