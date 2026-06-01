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

/// 文件夹模式下的文件列表。底层使用 NSOutlineView：可见文件在顶层，OS 隐藏文件（dotfile / 隐藏标志）
/// 收进一个默认折叠的「隐藏文件」分组节点，点开才展开。保留 macOS 原生的拖动多选手感。
struct FileTable: View {
    @ObservedObject var model: ArchiveBrowserModel
    @AppStorage(AppPreferences.Key.showFileSizeColumn) private var showSizeColumn = true
    @AppStorage(AppPreferences.Key.showFileTypeColumn) private var showTypeColumn = true
    @AppStorage(AppPreferences.Key.showFileApplicationColumn) private var showApplicationColumn = true
    @AppStorage(AppPreferences.Key.showFileLastOpenedColumn) private var showLastOpenedColumn = true
    @AppStorage(AppPreferences.Key.showFileDateAddedColumn) private var showDateAddedColumn = true
    @AppStorage(AppPreferences.Key.showFileModifiedColumn) private var showModifiedColumn = true
    @AppStorage(AppPreferences.Key.showFileCreatedColumn) private var showCreatedColumn = true
    // 观察分组相关偏好 —— 在 Settings 改这些时靠这几个 @AppStorage 触发本视图重渲染，
    // 进而调 updateNSView → syncContent 重新分组（设置只翻 UserDefaults，本身不发通知）。
    @AppStorage(AppPreferences.Key.fileGroupingScope) private var fileGroupingScope = BrowserGrouping.GroupingScope.global.rawValue
    @AppStorage(AppPreferences.Key.fileGroupBy) private var fileGroupBy = BrowserGrouping.GroupBy.none.rawValue
    @AppStorage(AppPreferences.Key.hiddenWithGrouping) private var hiddenWithGrouping = BrowserGrouping.HiddenWithGrouping.separateGroup.rawValue
    // 显示密度：值变 → updateNSView 调整 rowHeight + 重画单元格。
    @AppStorage(AppPreferences.Key.rowDensity) private var rowDensity = FileBrowserOutline.RowDensity.standard.rawValue

    var body: some View {
        FileNSOutlineView(
            model: model,
            showSizeColumn: showSizeColumn,
            showTypeColumn: showTypeColumn,
            showApplicationColumn: showApplicationColumn,
            showLastOpenedColumn: showLastOpenedColumn,
            showDateAddedColumn: showDateAddedColumn,
            showModifiedColumn: showModifiedColumn,
            showCreatedColumn: showCreatedColumn,
            groupingScope: fileGroupingScope,
            groupBy: fileGroupBy,
            hiddenWithGrouping: hiddenWithGrouping,
            rowDensity: rowDensity
        )
    }
}

/// 大纲节点：要么是一个文件行（叶子），要么是一个可折叠区块（section）。
/// 区块涵盖两种来源：Group By 的分类组（如「图片」）和 #49 的「隐藏文件」组。
/// 用 class（引用类型）是因为 NSOutlineView 按对象身份跟踪展开状态 —— 区块实例按 sectionKey 跨 reload 复用。
@MainActor
private final class FileOutlineNode {
    enum Kind {
        case file(FileItem)
        case section
    }

    let kind: Kind
    /// section 稳定身份键（"hidden" / "kind:图片"），跨 reload 复用实例 + 折叠记忆都靠它。
    let sectionKey: String
    /// section 显示标题（含计数），如「隐藏文件 (3)」「图片 (5)」。
    var title: String
    /// section 的子文件节点。
    var children: [FileOutlineNode]
    /// 是否是「隐藏文件」组（GroupBy=none 时走 #49 折叠记忆策略；其余区块默认展开、不持久化）。
    let isHiddenSection: Bool

    private init(kind: Kind, sectionKey: String, title: String, isHiddenSection: Bool) {
        self.kind = kind
        self.sectionKey = sectionKey
        self.title = title
        self.children = []
        self.isHiddenSection = isHiddenSection
    }

    static func file(_ item: FileItem) -> FileOutlineNode {
        FileOutlineNode(kind: .file(item), sectionKey: "", title: "", isHiddenSection: false)
    }

    static func section(key: String, isHidden: Bool) -> FileOutlineNode {
        FileOutlineNode(kind: .section, sectionKey: key, title: "", isHiddenSection: isHidden)
    }

    var fileItem: FileItem? {
        if case .file(let item) = kind { return item }
        return nil
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }
}

private struct FileNSOutlineView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let showSizeColumn: Bool
    let showTypeColumn: Bool
    let showApplicationColumn: Bool
    let showLastOpenedColumn: Bool
    let showDateAddedColumn: Bool
    let showModifiedColumn: Bool
    let showCreatedColumn: Bool
    // 仅作为「变化触发器」：值变 → SwiftUI 重建本 representable → updateNSView → syncContent 重新分组。
    // 真值仍由 coordinator 直接读 AppPreferences（@AppStorage 与 UserDefaults 始终一致）。
    let groupingScope: String
    let groupBy: String
    let hiddenWithGrouping: String
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
            outlineView.registerForDraggedTypes([.fileURL])
            outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
            outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
            // 拖动只在 name 列图标/文字上起手，行内空白处恢复橡皮筋复选。
            (outlineView as? ContentDragOutlineView)?.primaryColumnIdentifier = FileColumn.name.identifier
            // 选中单个文件按 Return 进入内联重命名。
            (outlineView as? ContentDragOutlineView)?.returnKeyAction = { [weak coordinator = context.coordinator] in
                coordinator?.beginRenameSelected() ?? false
            }
            // 快速查看（空格 / 重压图标 / 右键）预览当前选中文件。
            // 读 outlineView 的实时 selectedRowIndexes 而不是 model.selectedFileItems —— 后者异步更新，
            // 重压时还没跟上，会预览到「之前选中的文件」（用户反馈）。直接读视图选区是同步的、最新的。
            (outlineView as? ContentDragOutlineView)?.quickLookURLsProvider = { [weak outlineView] in
                guard let outlineView else { return [] }
                return outlineView.selectedRowIndexes.compactMap {
                    (outlineView.item(atRow: $0) as? FileOutlineNode)?.fileItem?.url
                }
            }
            // URL → 行号映射（供 QL 缩放动画定位图标）。放这里因为 FileOutlineNode 对 ContentDragOutlineView 不可见。
            (outlineView as? ContentDragOutlineView)?.quickLookRowForURL = { [weak outlineView] url in
                guard let outlineView else { return nil }
                for row in 0..<outlineView.numberOfRows where (outlineView.item(atRow: row) as? FileOutlineNode)?.fileItem?.url == url {
                    return row
                }
                return nil
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
        // 密度变化：rowHeight 改了要 reloadData 才会按新行高 + 新图标/字号重画（syncContent 内部已 reload）。
        // 只在真的变化时赋值 —— 赋同一个值也会把表标记为需重绘，框选时每帧都赋会加剧闪烁。
        let targetRowHeight = AppPreferences.rowDensity.rowHeight
        if outlineView.rowHeight != targetRowHeight {
            outlineView.rowHeight = targetRowHeight
        }
        context.coordinator.syncContent()
        context.coordinator.applySelection()
        context.coordinator.performPendingInlineRenameIfNeeded()
    }

    private func configureColumns(for outlineView: NSOutlineView) {
        configureTableColumns(visibleColumns, for: outlineView)
        // 「隐藏文件」分组的 disclosure 三角挂在 name 列上。
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.identifier))
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
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var model: ArchiveBrowserModel
        weak var outlineView: NSOutlineView?
        private var isApplyingSelection = false
        private var isSyncingExpansion = false
        // 正在内联重命名的文件；controlTextDidEndEditing 据此知道改的是哪个 item。
        private var renamingItem: FileItem?
        /// Esc 取消标记 —— doCommandBy 里置位，controlTextDidEndEditing 据此跳过改名。
        private var renameCancelled = false

        // 顶层节点：可能是文件叶子（不分类时）和/或区块（分类组 / 隐藏组）。
        // sectionNodesByKey 按 key 复用区块实例，保证展开状态跨 reloadData 不丢。
        private var topLevelNodes: [FileOutlineNode] = []
        private var sectionNodesByKey: [String: FileOutlineNode] = [:]

        // 展开状态：
        // - 分类区块默认展开，用户手动折叠的记进 userCollapsedSectionKeys（不持久化，配置变时清空）；
        // - 「隐藏文件」组（GroupBy=none）走 #49：hiddenGroupExpanded + 按折叠策略持久化。
        private var userCollapsedSectionKeys: Set<String> = []
        private var hiddenGroupExpanded = false
        // folder / 折叠策略 / GroupBy / 共存策略 任一变 → 重置展开状态。
        private var lastConfigSignature: String?
        // 上次真正 reloadData 时的「内容指纹」。选区变化不改它 → 跳过 reload，避免橡皮筋复选时闪烁 / 抽搐。
        private var lastContentSignature: Int?
        private var menuGroupFileItems: [FileItem] = []

        init(model: ArchiveBrowserModel) {
            self.model = model
        }

        /// 当前位置的 key，用于 `.rememberPerFolder` 记忆。
        private var currentFolderKey: String {
            switch model.mode {
            case .folder(let url): return url.standardizedFileURL.path
            case .tag(let tag): return "tag:\(tag)"
            case .archive(let url): return "archive:\(url.standardizedFileURL.path)"
            }
        }

        /// 当前文件夹实际生效的分组维度（全局默认或按文件夹覆盖）。
        private var effectiveGroupBy: BrowserGrouping.GroupBy {
            AppPreferences.effectiveFileGroupBy(forFolderKey: currentFolderKey)
        }

        private var configSignature: String {
            "\(currentFolderKey)|\(AppPreferences.hiddenGroupCollapseMode.rawValue)|\(effectiveGroupBy.rawValue)|\(AppPreferences.fileGroupingScope.rawValue)|\(AppPreferences.hiddenWithGrouping.rawValue)"
        }

        /// 所有区块节点，父在子前（top-down）—— enforceExpansion 需要先展开父再展开子。支持嵌套（隐藏组里再分子组）。
        private func allSectionNodes() -> [FileOutlineNode] {
            var result: [FileOutlineNode] = []
            func walk(_ nodes: [FileOutlineNode]) {
                for node in nodes where node.isSection {
                    result.append(node)
                    walk(node.children)
                }
            }
            walk(topLevelNodes)
            return result
        }

        /// 所有文件叶子节点（递归进任意层区块），选择同步用。
        private func allFileNodes() -> [FileOutlineNode] {
            var result: [FileOutlineNode] = []
            func walk(_ nodes: [FileOutlineNode]) {
                for node in nodes {
                    if node.isSection { walk(node.children) } else { result.append(node) }
                }
            }
            walk(topLevelNodes)
            return result
        }

        private func fileNodeAndAncestors(for url: URL) -> (node: FileOutlineNode, ancestors: [FileOutlineNode])? {
            // 按规范化 path 比对，而非整 URL 相等：目录在列表里的 URL 带尾部斜杠（`…/NewFolder/`），
            // 而 `pendingInlineRenameURL` 经 appendingPathComponent 没有斜杠（`…/NewFolder`），
            // `standardizedFileURL` 又不抹平尾斜杠 —— 直接 `==` 会漏掉新建文件夹，导致它不触发重命名（新建文件无此问题）。
            let targetPath = url.standardizedFileURL.path
            func walk(_ nodes: [FileOutlineNode], ancestors: [FileOutlineNode]) -> (FileOutlineNode, [FileOutlineNode])? {
                for node in nodes {
                    if let item = node.fileItem, item.url.standardizedFileURL.path == targetPath {
                        return (node, ancestors)
                    }
                    if node.isSection, let found = walk(node.children, ancestors: ancestors + [node]) {
                        return found
                    }
                }
                return nil
            }
            return walk(topLevelNodes, ancestors: [])
        }

        /// 重建节点 + reload + 强制同步展开状态。make / update 都走这里。
        func syncContent() {
            // 内容指纹 = 影响「画出来的行 / 列」的一切：config（folder/折叠/分类/共存）+ 行密度 +
            // 当前可见列 + 当前 fileItems 实例（按 id + 顺序）。**不含 selection**。
            // 选区变化不改 fileItems 实例 → 指纹不变 → 直接 return 不 reloadData ——
            // 否则橡皮筋复选时每次选区变动都 SwiftUI updateNSView → reloadData，打断拖选造成闪烁 / 选区疯狂抽搐。
            // 真正的内容变化（导航 / 自动刷新 / 排序 / 分组 / 密度 / 列开关）都会改 fileItems 实例或上述配置，照常刷新。
            var hasher = Hasher()
            hasher.combine(configSignature)
            hasher.combine(AppPreferences.rowDensity.rawValue)
            hasher.combine(outlineView?.tableColumns.map { $0.identifier.rawValue }.joined(separator: ",") ?? "")
            for item in model.fileItems { hasher.combine(item.id) }
            let contentSignature = hasher.finalize()
            guard contentSignature != lastContentSignature else { return }
            lastContentSignature = contentSignature

            rebuildTopLevel()

            // 配置（folder / 策略 / 分类维度 / 共存）变化时重置展开状态：
            // 分类区块回到默认全展开（清空 userCollapsed）；隐藏组按 #49 策略重新 seed。
            // 这样设置一改、主窗口经 browserPreferencesChanged → reload 立即生效，不用手动刷新；
            // 同一配置内的增量 reload（如选区变化）则保留用户当前的展开/折叠。
            let signature = configSignature
            if signature != lastConfigSignature {
                lastConfigSignature = signature
                userCollapsedSectionKeys = []
                hiddenGroupExpanded = FileBrowserOutline.initialExpanded(
                    mode: AppPreferences.hiddenGroupCollapseMode,
                    folderKey: currentFolderKey,
                    perFolderExpanded: AppPreferences.hiddenGroupExpandedFolders,
                    globalExpanded: AppPreferences.hiddenGroupGlobalExpanded
                )
            }

            // 内容要重画前先收掉重命名输入框（切文件夹 / 自动刷新 / 排序分组变化）：
            // 否则编辑中的字段编辑器会悬在被复用的 cell 上、留个空输入框（用户反馈「切文件夹还赖着」）。
            endActiveRename()
            outlineView?.reloadData()
            enforceExpansion()
            performPendingInlineRenameIfNeeded()
        }

        /// 按 GroupBy + 共存策略组装顶层节点。复用 sectionNodesByKey 里同 key 的实例保身份。
        private func rebuildTopLevel() {
            var reused: [String: FileOutlineNode] = [:]
            // 创建 / 复用一个区块节点（不设 children，交给调用方）；按 key 复用保展开身份。
            func reuseSection(key: String, isHidden: Bool, title: String) -> FileOutlineNode {
                let node = sectionNodesByKey[key] ?? FileOutlineNode.section(key: key, isHidden: isHidden)
                node.title = title
                reused[key] = node
                return node
            }
            // 一个「标题 → 文件」的叶子区块。
            func fileSection(key: String, isHidden: Bool, title: String, items: [FileItem]) -> FileOutlineNode {
                let node = reuseSection(key: key, isHidden: isHidden, title: title)
                node.children = items.map { FileOutlineNode.file($0) }
                return node
            }
            // 把一组文件按某维度切成「标题 (n)」叶子区块。
            func groupedSections(_ items: [FileItem], keyPrefix: String, groupBy: BrowserGrouping.GroupBy) -> [FileOutlineNode] {
                BrowserGrouping.group(items, by: groupBy, now: Date()).map {
                    fileSection(key: "\(keyPrefix)\($0.title)", isHidden: false, title: "\($0.title) (\($0.items.count))", items: $0.items)
                }
            }
            // 「隐藏文件 (N)」组（平铺，不分组时用）。
            func flatHiddenSection(_ items: [FileItem]) -> FileOutlineNode {
                fileSection(key: "hidden", isHidden: true, title: L10n.format("file.hiddenGroup", items.count), items: items)
            }

            let split = FileBrowserOutline.split(model.fileItems)
            let groupBy = effectiveGroupBy

            if groupBy.isGrouping {
                // 分组开启：忽略 #49 折叠策略（含 inline），改由共存策略决定隐藏文件去向。
                switch AppPreferences.hiddenWithGrouping {
                case .foldIntoGroups:
                    // 全部条目（含隐藏）一起按当前维度分组。
                    topLevelNodes = groupedSections(model.fileItems, keyPrefix: "g:", groupBy: groupBy)
                case .separateGroup:
                    // 可见文件按维度分组 + 隐藏文件单独成一个组，且组内再按同一维度分子组（嵌套）。
                    var nodes = groupedSections(split.visible, keyPrefix: "g:", groupBy: groupBy)
                    if !split.hidden.isEmpty {
                        let parent = reuseSection(key: "hidden", isHidden: true, title: L10n.format("file.hiddenGroup", split.hidden.count))
                        parent.children = groupedSections(split.hidden, keyPrefix: "hidden/g:", groupBy: groupBy)
                        nodes.append(parent)
                    }
                    topLevelNodes = nodes
                }
            } else {
                // GroupBy=none：复用 #49 行为，受 hiddenGroupCollapseMode 的 inline 影响。
                if AppPreferences.hiddenGroupCollapseMode.groupsHiddenFiles {
                    var nodes = split.visible.map { FileOutlineNode.file($0) }
                    if !split.hidden.isEmpty { nodes.append(flatHiddenSection(split.hidden)) }
                    topLevelNodes = nodes
                } else {
                    // inline opt-out：全平铺。
                    topLevelNodes = model.fileItems.map { FileOutlineNode.file($0) }
                }
            }

            sectionNodesByKey = reused
        }

        /// 某区块当前是否应展开。
        /// 「隐藏文件」父组**永远**走折叠策略（hiddenGroupExpanded）—— 哪怕开了 Group By 也一样，
        /// 否则分组一开隐藏文件就默认展开、重新糊脸，违背 #49 的产品灵魂。
        /// 父组内部按维度切出的子分类区块（hidden/g:今天 等）不是 isHiddenSection，仍默认展开 ——
        /// 即「隐藏组折叠；展开后里面的子分类默认都展开」。
        private func isSectionExpanded(_ node: FileOutlineNode) -> Bool {
            if node.isHiddenSection {
                return hiddenGroupExpanded
            }
            return !userCollapsedSectionKeys.contains(node.sectionKey)
        }

        private func enforceExpansion() {
            guard let outlineView else { return }
            isSyncingExpansion = true
            for node in allSectionNodes() {
                if isSectionExpanded(node) {
                    outlineView.expandItem(node)
                } else {
                    outlineView.collapseItem(node)
                }
            }
            isSyncingExpansion = false
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileOutlineNode else { return topLevelNodes.count }
            return node.isSection ? node.children.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileOutlineNode else {
                return index < topLevelNodes.count ? topLevelNodes[index] : topLevelNodes
            }
            guard index < node.children.count else { return node }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileOutlineNode)?.isSection == true
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileOutlineNode, let tableColumn else { return nil }
            let column = FileColumn(identifier: tableColumn.identifier.rawValue) ?? .name
            let density = AppPreferences.rowDensity

            if node.isSection {
                // 区块头只在 name 列画标题 + 图标；其它列留空。
                guard column == .name else { return nil }
                let symbol = node.isHiddenSection ? "eye.slash" : "square.grid.3x1.below.line.grid.1x2"
                return makeTableCell(
                    in: outlineView,
                    owner: self,
                    identifier: "FileCell-section",
                    text: node.title,
                    isPrimaryColumn: true,
                    icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    iconSize: density.iconSize,
                    font: .systemFont(ofSize: density.textPointSize)
                )
            }

            guard let fileItem = node.fileItem else { return nil }
            return makeTableCell(
                in: outlineView,
                owner: self,
                identifier: "FileCell-\(column.identifier)",
                text: column.value(for: fileItem),
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: fileItem) : nil,
                iconSize: density.iconSize,
                font: .systemFont(ofSize: density.textPointSize)
            )
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outlineView else { return }
            var selection = Set<UUID>()
            for index in outlineView.selectedRowIndexes {
                if let node = outlineView.item(atRow: index) as? FileOutlineNode, let item = node.fileItem {
                    selection.insert(item.id)
                }
            }
            // 点到别的行（选区移开正在重命名的项）→ 提交并收掉输入框（Finder：点开别处即提交）。
            // 重压重命名时 selectRowIndexes 在 beginRename 之前触发、那会儿 renamingItem 还是 nil，不会误收。
            if let renaming = renamingItem, !selection.contains(renaming.id) {
                endActiveRename()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.selection != selection else { return }
                self.model.selection = selection
            }
        }

        func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            var fileRows = IndexSet()
            var sectionRows = IndexSet()
            for row in proposedSelectionIndexes {
                guard let node = outlineView.item(atRow: row) as? FileOutlineNode else { continue }
                if node.isSection {
                    sectionRows.insert(row)
                } else {
                    fileRows.insert(row)
                }
            }
            if !fileRows.isEmpty {
                return fileRows
            }
            if let firstSection = sectionRows.first {
                return IndexSet(integer: firstSection)
            }
            return proposedSelectionIndexes
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sortFileItems(by: key, ascending: descriptor.ascending)
            syncContent()
            applySelection()
        }

        func outlineViewColumnDidMove(_ notification: Notification) {
            guard let outlineView else { return }
            AppPreferences.setStringArray(outlineView.tableColumns.map(\.identifier.rawValue), forKey: AppPreferences.Key.fileColumnOrder)
        }

        // 用户手动展开 / 折叠某区块 —— 更新真值（隐藏组按 #49 持久化，分类组只记本次会话）。
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion, let node = sectionNode(from: notification) else { return }
            setSectionExpanded(node, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion, let node = sectionNode(from: notification) else { return }
            setSectionExpanded(node, false)
        }

        private func sectionNode(from notification: Notification) -> FileOutlineNode? {
            guard let node = notification.userInfo?["NSObject"] as? FileOutlineNode, node.isSection else { return nil }
            return node
        }

        private func setSectionExpanded(_ node: FileOutlineNode, _ expanded: Bool) {
            // 与 isSectionExpanded 对称：隐藏文件父组永远更新 + 持久化折叠策略（无视是否分组）。
            if node.isHiddenSection {
                hiddenGroupExpanded = expanded
                persistExpansion(expanded)
            } else if expanded {
                userCollapsedSectionKeys.remove(node.sectionKey)
            } else {
                userCollapsedSectionKeys.insert(node.sectionKey)
            }
        }

        private func persistExpansion(_ expanded: Bool) {
            let mode = AppPreferences.hiddenGroupCollapseMode
            switch mode {
            case .alwaysCollapsed, .inline:
                break // 不记忆（.inline 根本没有分组可记）
            case .rememberPerFolder:
                AppPreferences.hiddenGroupExpandedFolders = FileBrowserOutline.updatedPerFolderExpanded(
                    AppPreferences.hiddenGroupExpandedFolders,
                    folderKey: currentFolderKey,
                    expanded: expanded,
                    mode: mode
                )
            case .globalSticky:
                AppPreferences.hiddenGroupGlobalExpanded = expanded
            }
        }

        // MARK: - 此文件夹分组（仅「按文件夹」范围 + folder 模式时出现在右键里）

        /// 往菜单追加「此文件夹分组」子菜单：跟随全局默认 / 不分组 / 种类 / 修改时间 / 文件与文件夹，✓ 当前项。
        private func appendFolderGroupingMenu(to menu: NSMenu) {
            guard AppPreferences.fileGroupingScope == .perFolder, case .folder = model.mode else { return }
            menu.addItem(.separator())
            let parent = NSMenuItem(title: L10n.text("file.folderGrouping"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let current = AppPreferences.fileFolderGroupBy(forKey: currentFolderKey)

            let follow = makeTableMenuItem(L10n.text("file.folderGrouping.followDefault"), systemImage: "arrow.uturn.backward", action: #selector(setFolderGroupingFollowDefault), target: self)
            follow.state = current == nil ? .on : .off
            submenu.addItem(follow)
            submenu.addItem(.separator())

            for option in BrowserGrouping.GroupBy.allCases {
                let item = NSMenuItem(title: option.title, action: #selector(setFolderGrouping(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.rawValue
                item.state = current == option ? .on : .off
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        @objc private func setFolderGroupingFollowDefault() {
            AppPreferences.setFileFolderGroupBy(nil, forKey: currentFolderKey)
            syncContent()
        }

        @objc private func setFolderGrouping(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String else { return }
            AppPreferences.setFileFolderGroupBy(BrowserGrouping.GroupBy.parse(raw), forKey: currentFolderKey)
            syncContent()
        }

        // MARK: - 拖拽

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileOutlineNode, let fileItem = node.fileItem else { return nil }
            // 按下点不在图标/文件名上 → 不提供拖动项，让 AppKit 回退到橡皮筋复选。
            if let dragView = outlineView as? ContentDragOutlineView, !dragView.dragAllowedFromMouseDown { return nil }
            if !model.selection.contains(fileItem.id) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { applySelection(IndexSet(integer: row)) }
                DispatchQueue.main.async { [weak self] in
                    self?.model.selection = [fileItem.id]
                }
            }
            return fileItem.url as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : [.copy, .move]
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard fileDropDestination(item: item, childIndex: index) != nil else { return [] }
            return info.draggingSource as? NSOutlineView === outlineView ? .move : .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let destination = fileDropDestination(item: item, childIndex: index) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            model.dropFileURLs(
                urls,
                to: destination,
                shouldMove: info.draggingSource as? NSOutlineView === outlineView
            )
            return true
        }

        // MARK: - 右键菜单

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            selectClickedRowIfNeeded(in: outlineView)
            menu.removeAllItems()
            menuGroupFileItems = []

            // 空白处右键（无有效文件行）的菜单瘦身：只留粘贴 + 在 Finder 中显示当前文件夹。
            // 选中文件才有意义的项（打开 / 解压 / 测试 / 哈希 / 复制剪切移动删除）没文件可作用就别出现。
            let clickedItem = outlineView.clickedRow >= 0 ? outlineView.item(atRow: outlineView.clickedRow) : nil
            if let clickedNode = clickedItem as? FileOutlineNode, clickedNode.isSection {
                appendSectionMenu(to: menu, for: clickedNode)
                return
            }
            let clickedFile = (clickedItem as? FileOutlineNode)?.fileItem
            guard clickedFile != nil else {
                appendNewItemMenu(to: menu)
                menu.addItem(.separator())
                menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
                menu.addItem(.separator())
                // 用 revealCurrentLocation 不用 revealSelected —— 用户右键空白处的意图是「打开我现在看的这个文件夹本身」。
                menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealCurrentLocation)))
                appendFolderGroupingMenu(to: menu)
                return
            }

            // 右键菜单按「分类」分组，组间用分隔线，方便扫读（用户反馈：项目太多、乱、找不到）。
            // 分组顺序：① 打开 / 查看 → ② 压缩 / 校验 → ③ 编辑（文件管理）→ ④ 在 Finder 中显示 / 分组。
            // 各项的显示条件与原来完全一致，只调整了顺序与分隔。

            // ① 打开 / 查看
            menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
            // 「在新标签 / 新窗口打开」—— 单选且可浏览（文件夹 / 受支持压缩包 / .siz / .szs）时出现。
            if model.selectedFileItems.count == 1, let item = model.selectedFileItems.first, canOpenInNewBrowser(item) {
                menu.addItem(menuItem(L10n.text("file.openInNewTab"), systemImage: "plus.rectangle.on.rectangle", action: #selector(openSelectedInNewTab)))
                menu.addItem(menuItem(L10n.text("file.openInNewWindow"), systemImage: "macwindow.badge.plus", action: #selector(openSelectedInNewWindow)))
            }
            // 「打开方式 ▸」—— 选中项不是普通文件夹时出现（文件 / 包都可以）。列出系统注册的可用 App + 末尾「其他…」。
            if let first = model.selectedFileItems.first, !FileBrowserService.isNavigableDirectory(first) {
                appendOpenWithMenu(to: menu)
            }
            // 快速查看（与空格 / 重压图标同一动作）。
            menu.addItem(menuItem(L10n.text("file.quickLook"), systemImage: "eye", action: #selector(quickLookSelected)))
            if let item = model.selectedFileItems.first, model.selectedFileItems.count == 1, model.canShowPackageContents(item) {
                menu.addItem(menuItem(L10n.text("file.showPackageContents"), systemImage: "folder", action: #selector(showPackageContents)))
            }
            // 选中单个 `.szs` 时多一项「以虚拟目录浏览」—— 走静默验签，OK 就直接进，有问题才弹 alert。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               item.url.pathExtension.lowercased() == SZSArchive.extensionName {
                menu.addItem(menuItem(L10n.text("szs.silentBrowse.menuItem"), systemImage: "folder.badge.questionmark", action: #selector(silentBrowseSelectedSZS)))
            }
            // 「以压缩包打开」—— 只在选中单个非目录、且不是已识别压缩包时显示。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               !ArchiveService.isSupportedArchive(item.url) {
                menu.addItem(menuItem(L10n.text("file.openAsArchive"), systemImage: "doc.zipper", action: #selector(openSelectedAsArchive)))
            }

            // ② 压缩 / 校验
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square", action: #selector(addSelectedToArchive)))
            // 创建签名清单 —— 仅 GPG 启用 + 后端可用时出现。
            if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                menu.addItem(menuItem(L10n.text("szs.create.menuItem"), systemImage: "signature", action: #selector(createSignedManifestFromSelection)))
            }
            menu.addItem(menuItem(L10n.text("button.extractHere"), systemImage: "arrow.down.doc", action: #selector(extractSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testSelectedArchive)))
            menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashSelected)))

            // ③ 编辑 / 文件管理（重命名归到这里，跟复制剪切移动删除一组）
            menu.addItem(.separator())
            if model.selectedFileItems.count == 1 {
                menu.addItem(menuItem(L10n.text("file.rename"), systemImage: "pencil", action: #selector(renameSelected)))
            }
            menu.addItem(menuItem(L10n.text("file.duplicate"), systemImage: "plus.square.on.square", action: #selector(duplicateSelected)))
            menu.addItem(menuItem(L10n.text("file.copy"), systemImage: "doc.on.doc", action: #selector(copySelected)))
            menu.addItem(menuItem(L10n.text("file.cut"), systemImage: "scissors", action: #selector(cutSelected)))
            menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
            menu.addItem(menuItem(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape", action: #selector(moveSelected)))
            menu.addItem(menuItem(L10n.text("file.delete"), systemImage: "trash", action: #selector(deleteSelected)))

            // ④ 在 Finder 中显示 / 简介 / 分组
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("file.getInfo"), systemImage: "info.circle", action: #selector(getInfoSelected)))
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealSelected)))
            appendFolderGroupingMenu(to: menu)
        }

        private func appendSectionMenu(to menu: NSMenu, for node: FileOutlineNode) {
            let items = fileItems(in: node)
            menuGroupFileItems = items
            appendNewItemMenu(to: menu)
            menu.addItem(.separator())
            let copy = menuItem(L10n.text("file.group.copyAll"), systemImage: "doc.on.doc", action: #selector(copyGroupFiles))
            copy.isEnabled = !items.isEmpty
            menu.addItem(copy)
            let cut = menuItem(L10n.text("file.group.cutAll"), systemImage: "scissors", action: #selector(cutGroupFiles))
            cut.isEnabled = !items.isEmpty
            menu.addItem(cut)
            menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealCurrentLocation)))
            appendFolderGroupingMenu(to: menu)
        }

        private func fileItems(in node: FileOutlineNode) -> [FileItem] {
            if let item = node.fileItem { return [item] }
            return node.children.flatMap(fileItems(in:))
        }

        @objc func doubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileOutlineNode else { return }
            if node.isSection {
                // 双击区块头 = 切换展开（同样触发 didExpand/didCollapse → 更新真值 + 持久化）。
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
                return
            }
            if let item = node.fileItem {
                model.open(item)
            }
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

        /// 「在新标签 / 新窗口打开」是否适用于该项：可浏览的文件夹、受支持压缩包、或 .siz/.szs。
        private func canOpenInNewBrowser(_ item: FileItem) -> Bool {
            if FileBrowserService.isNavigableDirectory(item) { return true }
            let ext = item.url.pathExtension.lowercased()
            if ext == SIZArchive.extensionName || ext == SZSArchive.extensionName { return true }
            return ArchiveService.isSupportedArchive(item.url)
        }

        @objc private func openSelectedInNewTab() {
            guard let url = model.selectedFileItems.first?.url else { return }
            MainWindowFactory.open(asTab: true, openURL: url)
        }

        @objc private func openSelectedInNewWindow() {
            guard let url = model.selectedFileItems.first?.url else { return }
            MainWindowFactory.open(asTab: false, openURL: url)
        }

        /// 「打开方式 ▸」子菜单：用 LaunchServices 列出能打开所有选中文件的共同 App（默认 App 排在最前并标注），
        /// 末尾「其他…」可手动挑任意 App。选择后把所有选中项一起交给那个 App 打开。
        ///
        /// 走 view 层直接 `NSWorkspace.open` 而不经 model —— 这是「唤起外部 App」的纯 workspace 动作，
        /// 不属于压缩 / 文件系统业务，没必要往 ArchiveBrowserModel 里加新 ownership（沿用 revealInFinder 之外的轻量惯例）。
        private func appendOpenWithMenu(to menu: NSMenu) {
            let urls = model.selectedFileItems.map(\.url)
            guard let first = urls.first else { return }
            let submenu = NSMenu()
            let defaultAppPath = NSWorkspace.shared.urlForApplication(toOpen: first)?.path
            for appURL in OpenWithService.commonApplicationURLs(toOpen: urls) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                let title = appURL.path == defaultAppPath ? L10n.format("file.openWith.default", name) : name
                let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = appURL
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                submenu.addItem(item)
            }
            if !submenu.items.isEmpty {
                submenu.addItem(.separator())
            }
            let other = NSMenuItem(title: L10n.text("file.openWith.other"), action: #selector(openWithOtherApp), keyEquivalent: "")
            other.target = self
            submenu.addItem(other)

            let parent = NSMenuItem(title: L10n.text("file.openWith"), action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        @objc private func openWithApp(_ sender: NSMenuItem) {
            guard let appURL = sender.representedObject as? URL else { return }
            let urls = model.selectedFileItems.map(\.url)
            OpenWithService.open(urls, withApplicationAt: appURL)
        }

        @objc private func openWithOtherApp() {
            let urls = model.selectedFileItems.map(\.url)
            OpenWithService.chooseApplicationAndOpen(urls)
        }

        private func appendNewItemMenu(to menu: NSMenu) {
            guard case .folder = model.mode else { return }
            menu.addItem(menuItem(L10n.text("file.newFolder"), systemImage: "folder.badge.plus", action: #selector(createNewFolder)))

            let parent = NSMenuItem(title: L10n.text("file.newFile"), action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            let submenu = NSMenu()
            for template in ArchiveBrowserModel.NewFileTemplate.allCases {
                let item = NSMenuItem(title: template.title, action: #selector(createNewFile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = template.rawValue
                item.image = NSImage(systemSymbolName: template.systemImage, accessibilityDescription: nil)
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        @objc private func createNewFolder() {
            model.createNewFolderAndBeginRename()
        }

        @objc private func createNewFile(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let template = ArchiveBrowserModel.NewFileTemplate(rawValue: raw) else { return }
            model.createNewFileAndBeginRename(template: template)
        }

        @objc private func showPackageContents() {
            if let item = model.selectedFileItems.first {
                model.showPackageContents(item)
            }
        }

        @objc private func addSelectedToArchive() {
            model.createArchive()
        }

        @objc private func createSignedManifestFromSelection() {
            model.createSignedManifest()
        }

        @objc private func silentBrowseSelectedSZS() {
            if let url = model.selectedFileItems.first?.url {
                model.pendingSZSSilentVirtualBrowse = url
            }
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

        @objc private func quickLookSelected() {
            (outlineView as? ContentDragOutlineView)?.presentQuickLook()
        }

        /// 「显示简介」—— 调起 Finder 原生的 Get Info 窗口（AppleScript 控制 Finder）。
        /// app 未沙盒、非硬化运行时，只需 Info.plist 里的 NSAppleEventsUsageDescription；
        /// 首次会弹「SimpleZip 想要控制 Finder」自动化授权，拒绝则失败提示。
        @objc private func getInfoSelected() {
            let urls = model.selectedFileItems.map(\.url)
            guard !urls.isEmpty else { return }
            do {
                try FinderInfoService.openInfoWindows(for: urls)
            } catch {
                model.errorMessage = L10n.format("file.getInfo.failed", error.localizedDescription)
            }
        }

        /// 空白处右键专用：reveal「我现在看的这个文件夹」本身，忽略 selection。
        @objc private func revealCurrentLocation() {
            model.revealCurrentLocationInFinder()
        }

        @objc private func duplicateSelected() {
            model.duplicateSelectedFiles()
        }

        @objc private func copySelected() {
            model.copySelectedFiles()
        }

        @objc private func cutSelected() {
            model.cutSelectedFiles()
        }

        @objc private func copyGroupFiles() {
            model.copyFileURLs(menuGroupFileItems.map(\.url))
        }

        @objc private func cutGroupFiles() {
            model.cutFileURLs(menuGroupFileItems.map(\.url))
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

        // MARK: - 内联重命名

        @objc private func renameSelected() {
            _ = beginRenameSelected()
        }

        /// 给 Return 键 / 右键菜单共用：选中恰好一个文件时进入内联编辑。返回是否已处理。
        @discardableResult
        func beginRenameSelected() -> Bool {
            guard case .folder = model.mode,
                  model.selectedFileItems.count == 1,
                  let item = model.selectedFileItems.first else { return false }
            model.pendingInlineRenameURL = nil
            return beginRename(item)
        }

        @discardableResult
        private func beginRename(_ item: FileItem) -> Bool {
            let itemURL = item.url.standardizedFileURL
            guard let outlineView,
                  let nameColIndex = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileColumn.name.identifier }),
                  let node = allFileNodes().first(where: { $0.fileItem?.url.standardizedFileURL == itemURL }),
                  let currentItem = node.fileItem else { return false }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return false }
            outlineView.scrollRowToVisible(row)
            guard let cell = outlineView.view(atColumn: nameColIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let textField = cell.textField else { return false }

            renamingItem = currentItem
            // 编辑真实磁盘名（不是 displayName），让用户改的就是最终文件名。
            let fullName = currentItem.url.lastPathComponent
            textField.isEditable = true
            textField.isSelectable = true
            textField.isBordered = true
            textField.bezelStyle = .squareBezel
            textField.drawsBackground = true
            textField.delegate = self
            textField.stringValue = fullName
            outlineView.window?.makeFirstResponder(textField)
            // 像 Finder：文件默认选中不含扩展名的主名；目录全选。
            if let editor = textField.currentEditor() {
                let stem = currentItem.isDirectory ? fullName : (fullName as NSString).deletingPathExtension
                let length = stem.isEmpty ? (fullName as NSString).length : (stem as NSString).length
                editor.selectedRange = NSRange(location: 0, length: length)
            }
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField, let item = renamingItem else { return }
            renamingItem = nil
            let cancelled = renameCancelled
            renameCancelled = false
            let newName = textField.stringValue

            // 还原成 label 外观；显示回原名，成功 rename 时下面 reload 会换成新名。
            textField.isEditable = false
            textField.isSelectable = false
            textField.isBordered = false
            textField.drawsBackground = false
            textField.delegate = nil
            textField.stringValue = item.displayName

            // Escape 取消（cancel 移动 / 我们的 Esc 标记）→ 不改名。
            let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? NSTextMovement.other.rawValue
            guard !cancelled, movement != NSTextMovement.cancel.rawValue else { return }
            model.renameFile(item, to: newName)
        }

        /// 回车提交 / Esc 取消 —— 显式结束字段编辑，避免某些情况下 Esc 不触发 endEditing、
        /// 输入框赖着不走（用户反馈：只能回车消、Esc 取消都不灵）。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard renamingItem != nil else { return false }
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

        /// 结束当前正在进行的内联重命名（提交）。用于「点开别处 / 切文件夹 / 列表 reload」时
        /// 把输入框收掉 —— 把第一响应者交回 outline 会触发 controlTextDidEndEditing 提交并还原外观。
        private func endActiveRename() {
            guard renamingItem != nil, let outlineView else { return }
            outlineView.window?.makeFirstResponder(outlineView)
        }

        // MARK: - 选择同步

        func applySelection() {
            guard let outlineView else { return }
            // 用户正按着鼠标（橡皮筋框选 / 拖动中）时，**不要**把 model.selection 回灌到表上：
            // 框选每一帧都 表→model→SwiftUI→updateNSView→applySelection，此时 model.selection 比 live 选区滞后一拍，
            // selectRowIndexes 会把选区猛拽回旧值 → 闪烁 / 疯狂抽搐。松手后下一次 updateNSView（按钮已抬起）再正常同步。
            if NSEvent.pressedMouseButtons & 0x1 != 0 { return }
            var indexes = IndexSet()
            for node in allFileNodes() {
                guard let item = node.fileItem, model.selection.contains(item.id) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { indexes.insert(row) }
            }
            // 保留用户用上下方向键 / 点击导航到的「分组头」行 —— 分组头没有 fileItem、不进 model.selection，
            // 若不保留，下面的 reapply 会把它清掉：方向键一碰到分组头选择就归零，光标卡在组里跨不过去（用户反馈）。
            for row in outlineView.selectedRowIndexes where (outlineView.item(atRow: row) as? FileOutlineNode)?.isSection == true {
                indexes.insert(row)
            }
            if outlineView.selectedRowIndexes != indexes {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let outlineView = self.outlineView, outlineView.selectedRowIndexes != indexes else { return }
                    self.applySelection(indexes)
                }
            }
        }

        func performPendingInlineRenameIfNeeded() {
            guard renamingItem == nil else { return }
            guard let pendingURL = model.pendingInlineRenameURL else { return }
            let target = pendingURL.standardizedFileURL
            guard let outlineView,
                  let found = fileNodeAndAncestors(for: target),
                  let item = found.node.fileItem else { return }
            for ancestor in found.ancestors {
                outlineView.expandItem(ancestor)
                setSectionExpanded(ancestor, true)
            }
            let row = outlineView.row(forItem: found.node)
            guard row >= 0 else { return }
            model.selection = [item.id]
            applySelection(IndexSet(integer: row))
            if beginRename(item) {
                model.pendingInlineRenameURL = nil
            }
        }

        private func selectClickedRowIfNeeded(in outlineView: NSOutlineView) {
            let row = outlineView.clickedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? FileOutlineNode else { return }
            guard let item = node.fileItem else {
                applySelection(IndexSet(integer: row))
                model.selection = []
                return
            }
            if !model.selection.contains(item.id) {
                applySelection(IndexSet(integer: row))
                // **必须同步**：menuNeedsUpdate 调用本方法后会立刻同步读 model.selectedFileItems 来构建菜单。
                // 若这里用 DispatchQueue.main.async 异步更新选区，菜单会用上一次的旧选区构建 —— 表现为
                // 「右键 A 却弹出上一个选中文件 B 的菜单」「同一位置连点两次菜单不一样」。
                // 本方法由右键事件（menuNeedsUpdate）触发，不在 SwiftUI 更新周期内，同步改 @Published 是安全的。
                model.selection = [item.id]
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

        /// 拖放目标：拖到某个「非包目录」文件行上 → 进那个目录；否则（拖到空白 / 文件 / 分组头）→ 当前文件夹。
        private func fileDropDestination(item: Any?, childIndex index: Int) -> URL? {
            if index == NSOutlineViewDropOnItemIndex,
               let node = item as? FileOutlineNode,
               let fileItem = node.fileItem,
               fileItem.isDirectory,
               !model.canShowPackageContents(fileItem) {
                return fileItem.url
            }
            if case .folder(let url) = model.mode {
                return url
            }
            return nil
        }

        func headerMenu() -> NSMenu {
            makeColumnHeaderMenu(scope: .fileBrowser)
        }

        private func icon(for item: FileItem) -> NSImage {
            if item.isDirectory, !item.isSymbolicLink, !model.canShowPackageContents(item) {
                return NSWorkspace.shared.icon(for: .folder)
            }
            return NSWorkspace.shared.icon(forFile: item.url.path)
        }
    }
}
