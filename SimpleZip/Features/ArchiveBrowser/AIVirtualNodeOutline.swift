//
//  AIVirtualNodeOutline.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区内容的 **NSOutlineView 宿主**。和主文件浏览(`FileTable`)用**同一套**
//  `makeOutlineScrollView` + `ContentDragOutlineView`,于是交互与主视图完全一致 ——
//  多选 / 橡皮筋框选 / 方向键 / 空格展开折叠 / 回车改名 / 点空白取消选中 / 拖拽,全部白送、行为一致。
//
//  渲染 `AIVirtualNode`(**不伪造 FileItem**)。分组双击下钻走模型导航(返回/前进/上一级/地址栏);文件展开
//  调出 AI 建议;右键菜单含 打开 / 我很喜欢 / 我不喜欢 / 改名;拖一个成员到分组 = 把它移进那个虚拟分组
//  (`AIWorkspaceStore.moveNodes`,只动虚拟结构、绝不碰硬盘)。
//

import AppKit
import SwiftUI

struct AIVirtualNodeOutline: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    @ObservedObject var store: AIWorkspaceStore
    let workspaceID: UUID
    let nodes: [AIVirtualNode]
    let onDispatch: (AISuggestionAction) -> Void

    static let nodeDragType = NSPasteboard.PasteboardType("com.simplezip.aivirtualnode")

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, store: store, workspaceID: workspaceID, dispatch: onDispatch)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = makeOutlineScrollView(
            delegate: context.coordinator,
            target: context.coordinator,
            doubleAction: #selector(Coordinator.doubleClick(_:))
        ) { outlineView in
            outlineView.headerView = nil                       // 虚拟树不需要表头
            outlineView.indentationPerLevel = 16
            outlineView.registerForDraggedTypes([Self.nodeDragType])
            outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
            (outlineView as? ContentDragOutlineView)?.primaryColumnIdentifier = "name"
            // 选中分组按 Return 进入内联改名(虚拟文件夹可改名)。
            (outlineView as? ContentDragOutlineView)?.returnKeyAction = { [weak c = context.coordinator] in
                c?.beginRenameSelected() ?? false
            }
            context.coordinator.outlineView = outlineView
        }
        if let outlineView = scrollView.documentView as? NSOutlineView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.resizingMask = .autoresizingMask
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.rowHeight = 30
        }
        context.coordinator.rebuild(nodes: nodes, expandTopLevel: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.workspaceID = workspaceID
        context.coordinator.dispatch = onDispatch
        context.coordinator.rebuild(nodes: nodes, expandTopLevel: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                             NSMenuDelegate, NSTextFieldDelegate {
        var model: ArchiveBrowserModel
        let store: AIWorkspaceStore
        var workspaceID: UUID
        var dispatch: (AISuggestionAction) -> Void
        weak var outlineView: NSOutlineView?

        private var roots: [Item] = []
        private var signature = ""
        private var renamingItem: Item?
        private var renameCancelled = false

        init(model: ArchiveBrowserModel, store: AIWorkspaceStore, workspaceID: UUID,
             dispatch: @escaping (AISuggestionAction) -> Void) {
            self.model = model
            self.store = store
            self.workspaceID = workspaceID
            self.dispatch = dispatch
        }

        /// 一个大纲项(引用类型 = 稳定身份):指向一个虚拟节点,或一个「文件展开出的 AI 建议」行。
        final class Item {
            let id: String
            let node: AIVirtualNode?
            let suggestion: AIWorkspaceNodeAction?
            var children: [Item]
            init(id: String, node: AIVirtualNode?, suggestion: AIWorkspaceNodeAction?, children: [Item]) {
                self.id = id; self.node = node; self.suggestion = suggestion; self.children = children
            }
            var isGroup: Bool { node?.kind == .group }
        }

        // MARK: - 重建(保留展开 + 选中)

        func rebuild(nodes: [AIVirtualNode], expandTopLevel: Bool) {
            let sig = Self.signature(nodes) + "|" + workspaceID.uuidString
            guard sig != signature else { return }   // 内容没变 → 不 reload(免闪烁 / 别打断改名)
            signature = sig

            let expandedIDs = capturedExpandedIDs()
            let selectedIDs = capturedSelectedIDs()
            roots = nodes.map { buildItem($0) }
            outlineView?.reloadData()

            // 还原展开:首次只展开 **AI 标为重要(prominent → confidence≥0.7)** 的分组(AI 注意力:它希望你先看到的
            // 才提前展开,**绝不全部展开**);之后沿用用户手动的展开状态。
            guard let outlineView else { return }
            applyExpansion { item in
                if expandTopLevel { return item.node?.kind == .group && (item.node?.confidence ?? 0) >= 0.7 }
                return expandedIDs.contains(item.id)
            }
            // 还原选中。
            if !selectedIDs.isEmpty {
                var rows = IndexSet()
                for row in 0..<outlineView.numberOfRows {
                    if let item = outlineView.item(atRow: row) as? Item, selectedIDs.contains(item.id) {
                        rows.insert(row)
                    }
                }
                if !rows.isEmpty { outlineView.selectRowIndexes(rows, byExtendingSelection: false) }
            }
        }

        private func buildItem(_ node: AIVirtualNode) -> Item {
            // 子节点全部来自 `node.children`:分组的成员叶子 + builder 给叶子挂的**模型生成 `.action` 建议节点**。
            // **不再硬编码常驻建议** —— 节点有 AI 建议(.action 子)才可展开、才有箭头;没有就不展开。手动动作走右键。
            let children = node.children.map { buildItem($0) }
            return Item(id: "n-\(node.id)", node: node, suggestion: nil, children: children)
        }

        private static func signature(_ nodes: [AIVirtualNode]) -> String {
            func walk(_ ns: [AIVirtualNode]) -> String {
                ns.map { "\($0.id.uuidString):\($0.title):\(walk($0.children))" }.joined(separator: ",")
            }
            return walk(nodes)
        }

        private func capturedExpandedIDs() -> Set<String> {
            guard let outlineView else { return [] }
            var ids = Set<String>()
            for row in 0..<outlineView.numberOfRows {
                if let item = outlineView.item(atRow: row) as? Item, outlineView.isItemExpanded(item) {
                    ids.insert(item.id)
                }
            }
            return ids
        }

        private func capturedSelectedIDs() -> Set<String> {
            guard let outlineView else { return [] }
            return Set(outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? Item)?.id })
        }

        private func applyExpansion(_ shouldExpand: (Item) -> Bool) {
            guard let outlineView else { return }
            func walk(_ items: [Item]) {
                for item in items where !item.children.isEmpty {
                    if shouldExpand(item) { outlineView.expandItem(item) }
                    walk(item.children)
                }
            }
            walk(roots)
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Item)?.children.isEmpty ?? true)
        }

        // MARK: - NSOutlineViewDelegate(单元格)

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            if let suggestion = item.suggestion {
                let cell = makeTableCell(in: outlineView, owner: self, identifier: "ai.suggestion",
                                         text: L10n.text(suggestion.titleKey), isPrimaryColumn: false,
                                         icon: Self.symbol(suggestion.systemImage, tint: .controlAccentColor),
                                         iconSize: 14)
                return cell
            }
            guard let node = item.node else { return nil }
            let suggested = !node.sourceRefs.isEmpty
                && store.nodeIsAISuggested(workspaceID: workspaceID, refs: node.sourceRefs)
            let removed = !node.sourceRefs.isEmpty
                && store.nodeIsAutoRemoved(workspaceID: workspaceID, refs: node.sourceRefs)
            // 名字 + **来源目录**(很多文件同名如 README.md,必须显示在哪个目录才分得清)+ AI 角标。tooltip 给全路径。
            // 用 `AINodeCellView`:多段富文本要跟随选中高亮反色(选中行变深时文字/图标转白,不再深底深字看不清)。
            let cellID = NSUserInterfaceItemIdentifier("ai.node.v2")
            let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? AINodeCellView) ?? AINodeCellView()
            cell.identifier = cellID
            cell.toolTip = removed ? L10n.text("aiWorkspace.removed.reason")
                : (Self.resolvedPath(node) ?? (suggested ? L10n.text("aiWorkspace.node.aiSuggested") : node.reason))
            cell.configure(title: node.title, parent: Self.parentDisplay(node),
                           iconName: Self.symbolName(node.kind), kindTint: Self.tint(node.kind),
                           removed: removed, suggested: suggested)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
            false   // 改名只经 Return / 右键触发(beginRenameSelected),不让随手双击文字进编辑
        }

        // MARK: - 双击 / 选择

        @objc func doubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let item = sender.item(atRow: row) as? Item else { return }
            activate(item)
        }

        private func activate(_ item: Item) {
            if let suggestion = item.suggestion { dispatch(suggestion.action); return }
            guard let node = item.node else { return }
            openNode(node)
        }

        /// 「打开」一个节点 —— 复用主文件浏览的同一套 `open` 派发,不再用 reveal 定位冒充打开:
        /// 分组→下钻;真实文件/文件夹/归档(有路径)→`model.openPath`(默认 App / 进目录 / 开归档);
        /// 纯虚拟节点(任务/报告/动作,无真实路径)→既有 `primaryAction`(打开任务 / 报告 / 跑动作)。
        private func openNode(_ node: AIVirtualNode) {
            if node.kind == .group { model.drillIntoAIWorkspaceGroup(node); return }
            if let path = Self.resolvedPath(node) { model.openPath(URL(fileURLWithPath: path)); return }
            if let primary = node.primaryAction { dispatch(primary) }
        }

        // MARK: - 改名(虚拟分组)

        /// 选中**单个分组**时进入内联改名。返回是否真的开始编辑(供 returnKeyAction / 重压)。
        @discardableResult
        func beginRenameSelected() -> Bool {
            guard let outlineView, outlineView.numberOfSelectedRows == 1,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
                  item.isGroup, let node = item.node else { return false }
            let row = outlineView.row(forItem: item)
            guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let textField = cell.textField else { return false }
            renamingItem = item
            renameCancelled = false
            textField.isEditable = true
            textField.isSelectable = true
            textField.isBordered = true
            textField.drawsBackground = true
            textField.stringValue = node.title
            textField.delegate = self
            outlineView.window?.makeFirstResponder(textField)
            textField.selectText(nil)
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { renameCancelled = true }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField, let item = renamingItem, let node = item.node else { return }
            let newTitle = textField.stringValue
            renamingItem = nil
            textField.isEditable = false; textField.isSelectable = false
            textField.isBordered = false; textField.drawsBackground = false; textField.delegate = nil
            guard !renameCancelled else { textField.stringValue = node.title; return }
            store.renameGroup(workspaceID: workspaceID, groupID: node.id, to: newTitle)
        }

        // MARK: - 拖拽:把成员移进虚拟分组(只动虚拟结构)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // 只有「带 source ref 的成员」可拖动(分组容器本身不拖)。
            guard let item = item as? Item, let node = item.node, !node.sourceRefs.isEmpty, node.kind != .group,
                  let ref = node.sourceRefs.first else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(ref.kind.rawValue + "|" + ref.id, forType: AIVirtualNodeOutline.nodeDragType)
            return pb
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            // 只接受「拖到一个分组上」(index == -1 表示落在该项本身,而非插入到子项之间)。
            guard let target = item as? Item, target.isGroup, index == NSOutlineViewDropOnItemIndex else {
                return []
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let target = item as? Item, let group = target.node, group.kind == .group else { return false }
            let refs = draggedRefs(from: info.draggingPasteboard)
            guard !refs.isEmpty else { return false }
            store.moveNodes(workspaceID: workspaceID, refs: refs, toGroup: group.id)
            return true
        }

        private func draggedRefs(from pasteboard: NSPasteboard) -> [AIContextSourceRef] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { pbItem in
                guard let s = pbItem.string(forType: AIVirtualNodeOutline.nodeDragType) else { return nil }
                let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = AIContextSourceRef.Kind(rawValue: parts[0]) else { return nil }
                return AIContextSourceRef(kind: kind, id: parts[1])
            }
        }

        // MARK: - 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? Item, let node = item.node else { return }

            if node.kind == .group {
                add(menu, "aiWorkspace.node.open") { [weak self] in self?.model.drillIntoAIWorkspaceGroup(node) }
                add(menu, "aiWorkspace.node.rename") { [weak self] in
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self?.beginRenameSelected()
                }
                return
            }
            if node.primaryAction != nil {
                add(menu, "aiWorkspace.node.open") { [weak self] in self?.openNode(node) }
            }
            for s in AIWorkspaceNodeActions.suggestions(for: node) {
                add(menu, s.titleKey) { [weak self] in self?.dispatch(s.action) }
            }
            guard !node.sourceRefs.isEmpty else { return }
            menu.addItem(.separator())
            if store.nodeIsAutoRemoved(workspaceID: workspaceID, refs: node.sourceRefs) {
                add(menu, "aiWorkspace.removed.restore") { [weak self] in
                    self?.store.restoreAutoRemovedNode(workspaceID: self?.workspaceID ?? UUID(), refs: node.sourceRefs)
                }
                return
            }
            if store.nodeIsAISuggested(workspaceID: workspaceID, refs: node.sourceRefs) {
                add(menu, "aiWorkspace.node.like") { [weak self] in
                    self?.store.likeNode(workspaceID: self?.workspaceID ?? UUID(), refs: node.sourceRefs)
                }
            }
            add(menu, "aiWorkspace.node.dislike") { [weak self] in
                self?.store.dislikeNode(workspaceID: self?.workspaceID ?? UUID(), refs: node.sourceRefs)
            }
        }

        private func add(_ menu: NSMenu, _ titleKey: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: L10n.text(titleKey), action: #selector(runBlock(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = BlockBox(action)
            menu.addItem(mi)
        }

        @objc private func runBlock(_ sender: NSMenuItem) { (sender.representedObject as? BlockBox)?.run() }

        private final class BlockBox { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }

        // MARK: - 来源路径(同名文件靠目录区分)

        static func resolvedPath(_ node: AIVirtualNode) -> String? { AIWorkspaceNodeActions.resolvedPath(node) }

        /// 节点的来源目录(home 缩成 ~)。取不到路径(如任务 / 报告节点)→ nil。
        static func parentDisplay(_ node: AIVirtualNode) -> String? {
            guard let path = resolvedPath(node) else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != "/" else { return nil }
            let home = NSHomeDirectory()
            if parent == home { return "~" }
            if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
            return parent
        }

        // MARK: - 图标

        private static func symbol(_ name: String, tint: NSColor) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [tint])
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }

        private static func symbolName(_ kind: AIVirtualNode.Kind) -> String {
            switch kind {
            case .group, .folder: return "folder.fill"
            case .file: return "doc.fill"
            case .archive: return "doc.zipper"
            case .archiveEntry: return "doc.text.fill"
            case .task: return "checklist"
            case .report: return "doc.richtext.fill"
            case .action: return "bolt.fill"
            case .automation: return "wand.and.stars"
            case .note: return "text.bubble.fill"
            }
        }

        private static func tint(_ kind: AIVirtualNode.Kind) -> NSColor {
            switch kind {
            case .group: return .controlAccentColor
            case .file, .note: return .systemGray
            case .folder: return .systemBlue
            case .archive: return .systemIndigo
            case .archiveEntry: return .systemTeal
            case .task: return .systemOrange
            case .report: return .systemPurple
            case .action: return .systemGreen
            case .automation: return .systemMint
            }
        }
    }
}

/// AI 节点行的 cell:标题 + 来源目录 + 角标(✦ / 已移除)是多段富文本,**必须跟随选中高亮反色** ——
/// 选中行背景变深时,文字和图标转成选中前景色(白),否则深底深字 + 深图标全看不清。
/// FileTable 的 `makeTableCell` 走 `textField.textColor`,NSTableCellView 会自动反色;这里因为要多段着色
/// 只能用 attributedString,得自己在 `backgroundStyle` 变化时重绘。
private final class AINodeCellView: NSTableCellView {
    /// 文件名独占主 `textField`(= `ContentDragOutlineView.hitRegion` 的可拖拽命中区只覆盖文件名,
    /// 和文件浏览的 name 列一致)。来源路径 / 角标放**另一个** label,**不**赋给 `textField` →
    /// 不计入拖拽命中区 → 路径区域和右侧空白都能框选 / 拖选多行,不再「一拖就拖文件」。
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var titleText = ""
    private var parentText: String?
    private var iconName = "doc.fill"
    private var kindTint: NSColor = .systemGray
    private var removed = false
    private var suggested = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(image)
        addSubview(nameLabel)
        addSubview(detailLabel)
        imageView = image
        textField = nameLabel    // 只有文件名是主 textField → 拖拽命中区只覆盖文件名
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 17),
            image.heightAnchor.constraint(equalToConstant: 17),
            nameLabel.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configure(title: String, parent: String?, iconName: String,
                   kindTint: NSColor, removed: Bool, suggested: Bool) {
        self.titleText = title
        self.parentText = parent
        self.iconName = iconName
        self.kindTint = kindTint
        self.removed = removed
        self.suggested = suggested
        applyStyle()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let emphasized = backgroundStyle == .emphasized
        let selectedFG = NSColor.alternateSelectedControlTextColor
        let base: NSColor = removed
            ? (emphasized ? selectedFG.withAlphaComponent(0.7) : .secondaryLabelColor)
            : (emphasized ? selectedFG : .labelColor)
        let secondary: NSColor = emphasized ? selectedFG.withAlphaComponent(0.75) : .secondaryLabelColor
        // 文件名:普通 stringValue + textColor(本身就短,撑不满行 → 后面留出框选 / 拖选的空间)。
        nameLabel.stringValue = titleText
        nameLabel.textColor = base
        // 来源目录 + 已移除角标 + ✦:都在 detailLabel,**不**进拖拽命中区。
        let s = NSMutableAttributedString()
        if let parentText {
            s.append(NSAttributedString(string: parentText,
                attributes: [.foregroundColor: secondary, .font: NSFont.systemFont(ofSize: 11)]))
        }
        if removed {
            if s.length > 0 { s.append(NSAttributedString(string: "   ")) }
            s.append(NSAttributedString(string: L10n.text("aiWorkspace.removed.badge"),
                attributes: [.foregroundColor: emphasized ? selectedFG : NSColor.systemOrange,
                             .font: NSFont.systemFont(ofSize: 11)]))
        }
        if suggested {
            if s.length > 0 { s.append(NSAttributedString(string: "  ")) }
            s.append(NSAttributedString(string: "✦",
                attributes: [.foregroundColor: emphasized ? selectedFG : NSColor.controlAccentColor]))
        }
        detailLabel.attributedStringValue = s
        let tint = emphasized ? selectedFG : kindTint
        let cfg = NSImage.SymbolConfiguration(paletteColors: [tint])
        imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}
