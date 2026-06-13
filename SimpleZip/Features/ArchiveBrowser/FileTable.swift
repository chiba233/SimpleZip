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
    @AppStorage(AppPreferences.Key.showFileSymlinkColumn) private var showSymlinkColumn = false
    @AppStorage(AppPreferences.Key.showFilePermissionsColumn) private var showPermissionsColumn = false
    @AppStorage(AppPreferences.Key.showFileOwnerColumn) private var showOwnerColumn = false
    // 观察分组相关偏好 —— 在 Settings 改这些时靠这几个 @AppStorage 触发本视图重渲染，
    // 进而调 updateNSView → syncContent 重新分组（设置只翻 UserDefaults，本身不发通知）。
    @AppStorage(AppPreferences.Key.fileGroupingScope) private var fileGroupingScope = BrowserGrouping.GroupingScope.global.rawValue
    @AppStorage(AppPreferences.Key.fileGroupBy) private var fileGroupBy = BrowserGrouping.GroupBy.none.rawValue
    @AppStorage(AppPreferences.Key.hiddenWithGrouping) private var hiddenWithGrouping = BrowserGrouping.HiddenWithGrouping.separateGroup.rawValue
    // 显示密度：值变 → updateNSView 调整 rowHeight + 重画单元格。
    @AppStorage(AppPreferences.Key.rowDensity) private var rowDensity = FileBrowserOutline.RowDensity.standard.rawValue
    // 0.4.2 #4:分卷折叠开关 —— 观察它让 View 菜单切换即时重建(值经 configSignature 进指纹)。
    @AppStorage(AppPreferences.Key.collapseVolumeSets) private var collapseVolumeSets = true

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
            showSymlinkColumn: showSymlinkColumn,
            showPermissionsColumn: showPermissionsColumn,
            showOwnerColumn: showOwnerColumn,
            groupingScope: fileGroupingScope,
            groupBy: fileGroupBy,
            hiddenWithGrouping: hiddenWithGrouping,
            rowDensity: rowDensity
        )
        // 权限 / 属主列是惰性填充的（默认不 stat,避免对 Desktop/Downloads 触发 TCC）。
        // 用户刚启用某列时,当前已加载的 FileItem 还没有这份数据 —— 触发一次重载补齐。
        .onChange(of: showPermissionsColumn) { on in if on { model.reload() } }
        .onChange(of: showOwnerColumn) { on in if on { model.reload() } }
    }
}

/// 大纲节点：要么是一个文件行（叶子），要么是一个可折叠区块（section）。
/// 区块涵盖两种来源：Group By 的分类组（如「图片」）和 #49 的「隐藏文件」组。
/// 用 class（引用类型）是因为 NSOutlineView 按对象身份跟踪展开状态 —— 区块实例按 sectionKey 跨 reload 复用。
@MainActor
final class FileOutlineNode {
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
    /// 0.4.2 #4 分卷集折叠：首卷节点挂全家族成员(含自己)为子级;nil = 不是折叠首卷。
    var volumeChildren: [FileOutlineNode]?
    /// 折叠首卷的家族卷数(name 列徽记「· N 卷」);0 = 无徽记。
    var volumeBadgeCount = 0
    /// 0.4.1 文件夹原位展开：目录叶子的子级节点缓存。nil = 还没展开过。
    /// 子级 FileItem 的**真值在模型注册表**（expandedFolderChildrenByPath）—— 这里只是包成节点的视图缓存,
    /// reload 重建顶层节点后由 enforceExpansion 按记忆重新展开、重新从注册表构建。
    var folderChildren: [FileOutlineNode]?

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

struct FileNSOutlineView: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let showSizeColumn: Bool
    let showTypeColumn: Bool
    let showApplicationColumn: Bool
    let showLastOpenedColumn: Bool
    let showDateAddedColumn: Bool
    let showModifiedColumn: Bool
    let showCreatedColumn: Bool
    let showSymlinkColumn: Bool
    let showPermissionsColumn: Bool
    let showOwnerColumn: Bool
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
        context.coordinator.performPendingSelectionIfNeeded()
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
        if showSymlinkColumn { columns.append(.symlink) }
        if showPermissionsColumn { columns.append(.permissions) }
        if showOwnerColumn { columns.append(.owner) }
        return orderedColumns(columns, key: AppPreferences.Key.fileColumnOrder)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var model: ArchiveBrowserModel
        weak var outlineView: NSOutlineView?
        private var isApplyingSelection = false
        private var isSyncingExpansion = false
        // 正在内联重命名的文件；controlTextDidEndEditing 据此知道改的是哪个 item。
        var renamingItem: FileItem?
        /// Esc 取消标记 —— doCommandBy 里置位，controlTextDidEndEditing 据此跳过改名。
        var renameCancelled = false
        /// 内联重命名进行中时，外部内容变化（FSEvents 把新建文件的写入当成内容变化触发 reload）被推迟；
        /// 编辑结束后补刷一次。否则刚弹出的输入框会被 reloadData / endActiveRename 拆掉（用户报的新建文件输入框偶发消失）。
        var needsReloadAfterRename = false

        // 顶层节点：可能是文件叶子（不分类时）和/或区块（分类组 / 隐藏组）。
        // sectionNodesByKey 按 key 复用区块实例，保证展开状态跨 reloadData 不丢。
        private var topLevelNodes: [FileOutlineNode] = []
        private var sectionNodesByKey: [String: FileOutlineNode] = [:]

        // 展开状态：
        // - 分类区块默认展开，用户手动折叠的记进 userCollapsedSectionKeys（不持久化，配置变时清空）；
        // - 「隐藏文件」组（GroupBy=none）走 #49：hiddenGroupExpanded + 按折叠策略持久化。
        private var userCollapsedSectionKeys: Set<String> = []
        private var hiddenGroupExpanded = false
        /// 0.4.1 文件夹原位展开：当前展开的文件夹（标准化路径）。reloadData 重建节点后据此重展开
        /// （expandRememberedFolders）。会话内、当前文件夹内有效；换文件夹 / 改配置随 configSignature 重置。
        private var expandedFolderPaths: Set<String> = []
        /// 0.4.2 #4 跟进：已展开分卷集的首卷路径（用户报「分卷抽屉不会记忆是否收起」——
        /// reload 重建节点后由 enforceExpansion 按此回放,与文件夹展开记忆同机制;受设置开关门控）。
        private var expandedVolumeSetPaths: Set<String> = []
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
            "\(currentFolderKey)|\(AppPreferences.collapseVolumeSets)|\(AppPreferences.hiddenGroupCollapseMode.rawValue)|\(effectiveGroupBy.rawValue)|\(AppPreferences.fileGroupingScope.rawValue)|\(AppPreferences.hiddenWithGrouping.rawValue)|\(AppPreferences.folderInlineExpansion)|\(AppPreferences.rememberFolderExpansion)|\(AppPreferences.rememberVolumeSetExpansion)"
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

        /// 所有文件节点（递归进任意层区块 **和已展开文件夹的子级**），选择同步用。
        /// 展开文件夹的子行若不在名单里,applySelection 回放时会把刚选中的子行当「不在选区」反选掉,多选当场散架。
        func allFileNodes() -> [FileOutlineNode] {
            var result: [FileOutlineNode] = []
            func walk(_ nodes: [FileOutlineNode]) {
                for node in nodes {
                    if node.isSection {
                        walk(node.children)
                    } else {
                        result.append(node)
                        // 0.4.2 #4：展开后的分卷成员行也得在名单里,否则 applySelection 回放把刚选中的成员行反选掉
                        // （与下面文件夹子级同一坑）。成员都是文件叶子,不用再递归。
                        if let volumeChildren = node.volumeChildren { result.append(contentsOf: volumeChildren) }
                        if let folderChildren = node.folderChildren { walk(folderChildren) }
                    }
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
                    // 已展开文件夹的子级也找（内联重命名 / 删除后落选的目标可能在子层）。
                    if let folderChildren = node.folderChildren,
                       let found = walk(folderChildren, ancestors: ancestors + [node]) {
                        return found
                    }
                    // 0.4.2 #4：分卷成员行也找（删除单个成员后邻居落选可能是成员行）。
                    // 首卷自身的 path 与折叠行相同,上面 fileItem 分支已先命中折叠行,不会误下钻。
                    if let volumeChildren = node.volumeChildren,
                       let found = walk(volumeChildren, ancestors: ancestors + [node]) {
                        return found
                    }
                }
                return nil
            }
            return walk(topLevelNodes, ancestors: [])
        }

        /// 重建节点 + reload + 强制同步展开状态。make / update 都走这里。
        func syncContent() {
            // 异步列举的中间帧守卫(0.4.3):导航后 mode(=folderKey/配置)先变、items 还是旧的,
            // 这一帧不重建 —— 保持上一帧画面,applyLoadedFolder 同一事务提交 items+清标志后一帧成型。
            // 不更新 lastContentSignature,提交帧照常触发重建。旧同步版本天然没有中间帧(用户报闪烁的根因)。
            if model.folderListingInFlight { return }
            // 内容指纹 = 影响「画出来的行 / 列」的一切：config（folder/折叠/分类/共存）+ 行密度 +
            // 当前可见列 + 当前 fileItems 实例（按 id + 顺序）。**不含 selection**。
            // 选区变化不改 fileItems 实例 → 指纹不变 → 直接 return 不 reloadData ——
            // 否则橡皮筋复选时每次选区变动都 SwiftUI updateNSView → reloadData，打断拖选造成闪烁 / 选区疯狂抽搐。
            // 真正的内容变化（导航 / 自动刷新 / 排序 / 分组 / 密度 / 列开关）都会改 fileItems 实例或上述配置，照常刷新。
            var hasher = Hasher()
            hasher.combine(configSignature)
            hasher.combine(AppPreferences.rowDensity.rawValue)
            hasher.combine(outlineView?.tableColumns.map { $0.identifier.rawValue }.joined(separator: ",") ?? "")
            for item in model.displayedFileItems { hasher.combine(item.id) }
            // 展开子级的内容世代：顶层没变、只有展开层内容变（refreshExpandedFolderChildren 换了新实例并
            // objectWillChange）时,靠它判定「内容变了」并 reload。故意不哈希注册表本身 —— 首次展开的懒登记
            // 会改注册表但行已画出,算进指纹会让展开后的下一次 updateNSView 误触发全表 reload（闪烁）。
            hasher.combine(model.expandedChildrenGeneration)
            let contentSignature = hasher.finalize()
            guard contentSignature != lastContentSignature else { return }

            // 正在内联重命名时推迟刷新：新建文件 / 文件夹刚弹出输入框，FSEvents 又把这次写入当成内容变化触发
            // reload，reloadData + endActiveRename 会把输入框当场拆掉（偶发，取决于 watcher 时序）。
            // 这里不更新 lastContentSignature、不 reload，编辑结束后再补刷（见 controlTextDidEndEditing）。
            if renamingItem != nil {
                needsReloadAfterRename = true
                return
            }
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
                // 展开记忆**跨导航保留**（用户报「切换个路径就不工作了」）：记的是绝对路径,全局唯一,
                // 离开文件夹后留着,回来时 enforceExpansion 自然回放;别的文件夹根本匹配不上,无副作用。
                // 记忆开关关掉时才清(开关在 configSignature 里,关掉必走这支) —— 关掉 = 用户要「刷新即折叠」。
                if !AppPreferences.rememberFolderExpansion {
                    expandedFolderPaths = []
                }
                if !AppPreferences.rememberVolumeSetExpansion {
                    expandedVolumeSetPaths = []
                }
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
                node.children = volumeFoldedNodes(items)
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

            let split = FileBrowserOutline.split(model.displayedFileItems)
            let groupBy = effectiveGroupBy

            if groupBy.isGrouping {
                // 分组开启：忽略 #49 折叠策略（含 inline），改由共存策略决定隐藏文件去向。
                switch AppPreferences.hiddenWithGrouping {
                case .foldIntoGroups:
                    // 全部条目（含隐藏）一起按当前维度分组。
                    topLevelNodes = groupedSections(model.displayedFileItems, keyPrefix: "g:", groupBy: groupBy)
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
                    var nodes = volumeFoldedNodes(split.visible)
                    if !split.hidden.isEmpty { nodes.append(flatHiddenSection(split.hidden)) }
                    topLevelNodes = nodes
                } else {
                    // inline opt-out：全平铺。
                    topLevelNodes = volumeFoldedNodes(model.displayedFileItems)
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
            // 0.4.1 文件夹原位展开：reloadData 后文件节点全是新实例（全折叠）,按记忆把上次展开的文件夹
            // 重新展开 —— 上一版漏了这步,FSEvents 一刷新展开层连行带选区直接坍掉（revert 信里的「闪一下就没」）。
            expandRememberedFolders(in: topLevelNodes)
            isSyncingExpansion = false
            // 文件夹展开记忆关掉时,reload 后没被重展开的文件夹其注册表条目成了「隐形但可被选区命中」——
            // 把记忆名单之外的条目清掉(名单内 = 刚被 enforce 重展开的,如待重命名目标的祖先链)。
            if !AppPreferences.rememberFolderExpansion {
                model.pruneExpandedFolderRegistry(keeping: expandedFolderPaths)
            }
            // reload 后仍折叠的分卷集:落在隐形成员上的选区收回首卷(与手动折叠同款防误删)。
            recallSelectionFromCollapsedVolumeSets()
        }

        /// 递归重展开记忆中的文件夹**和分卷集**。**先展开父层**（expandItem 触发数据源,从模型注册表懒构建子节点）,
        /// 子层节点存在后才能继续下钻嵌套展开的子文件夹。折叠区块里的不展（区块开了再说）。
        private func expandRememberedFolders(in nodes: [FileOutlineNode]) {
            guard let outlineView, !(expandedFolderPaths.isEmpty && expandedVolumeSetPaths.isEmpty) else { return }
            for node in nodes {
                if node.isSection {
                    if outlineView.isItemExpanded(node) { expandRememberedFolders(in: node.children) }
                    continue
                }
                guard let item = node.fileItem else { continue }
                if node.volumeChildren != nil {
                    if expandedVolumeSetPaths.contains(item.url.standardizedFileURL.path) {
                        outlineView.expandItem(node)
                    }
                    continue
                }
                guard item.isDirectory,
                      expandedFolderPaths.contains(item.url.standardizedFileURL.path) else { continue }
                outlineView.expandItem(node)
                if let children = node.folderChildren { expandRememberedFolders(in: children) }
            }
        }

        /// reload 后处于折叠态的分卷集（记忆关闭 / 本就没展开）：把落在隐形成员行上的选区收回首卷。
        /// 成员是真实顶层 FileItem,折叠不会把它们移出 selectedFileItems 的解析池 —— 不收回的话
        /// Delete / 菜单仍会作用在看不见的成员上（与 outlineViewItemDidCollapse 的防护同源）。
        private func recallSelectionFromCollapsedVolumeSets() {
            guard let outlineView else { return }
            var selection = model.selection
            var changed = false
            func walk(_ nodes: [FileOutlineNode]) {
                for node in nodes {
                    if node.isSection { walk(node.children); continue }
                    if let firstVolume = node.fileItem, let volumes = node.volumeChildren,
                       !outlineView.isItemExpanded(node) {
                        let memberIDs = Set(volumes.compactMap { $0.fileItem?.id }).subtracting([firstVolume.id])
                        let hidden = selection.intersection(memberIDs)
                        if !hidden.isEmpty {
                            selection.subtract(hidden)
                            selection.insert(firstVolume.id)
                            changed = true
                        }
                    }
                    if let children = node.folderChildren { walk(children) }
                }
            }
            walk(topLevelNodes)
            guard changed else { return }
            let newSelection = selection
            DispatchQueue.main.async { [weak self] in
                self?.model.selection = newSelection
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileOutlineNode else { return topLevelNodes.count }
            if node.isSection { return node.children.count }
            if let volumes = node.volumeChildren { return volumes.count }
            if isExpandableFolder(node) { return loadedFolderChildren(of: node).count }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileOutlineNode else {
                return index < topLevelNodes.count ? topLevelNodes[index] : topLevelNodes
            }
            let children = node.isSection ? node.children : (node.volumeChildren ?? loadedFolderChildren(of: node))
            guard index < children.count else { return node }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileOutlineNode else { return false }
            return node.isSection || node.volumeChildren != nil || isExpandableFolder(node)
        }

        // MARK: - 0.4.1 文件夹原位展开（子级真值在模型注册表,这里只做节点缓存 + 展开记忆）

        /// 文件夹叶子可展开：偏好开着（设置→浏览,可整体关闭回平铺列表）、是目录、
        /// 不是包（包要么双击进入要么交给系统打开）、不是符号链接
        /// （符号链接展开可能成环 a/link/a/link/…,Finder 列表视图同样不给符号链接展开箭头）。
        private func isExpandableFolder(_ node: FileOutlineNode) -> Bool {
            guard AppPreferences.folderInlineExpansion, let item = node.fileItem else { return false }
            return item.isDirectory && !item.isSymbolicLink && !model.canShowPackageContents(item)
        }

        /// 0.4.2 #4：把同目录的分卷家族（.001/.002… / part1.rar…）折叠成首卷一行,
        /// 全家族(含首卷)挂成子级 —— 展开箭头看成员、双击首卷=照常打开、右键合并照常认首卷。
        /// 识别复用 Core SplitVolumeSet（与右键「分卷集」信息行同源）。开关:View 菜单「折叠分卷集」。
        private func volumeFoldedNodes(_ items: [FileItem]) -> [FileOutlineNode] {
            guard AppPreferences.collapseVolumeSets else { return items.map { FileOutlineNode.file($0) } }
            let fileNames = items.filter { !$0.isDirectory }.map { $0.url.lastPathComponent }
            guard fileNames.count >= 2 else { return items.map { FileOutlineNode.file($0) } }
            var memberToFirst: [String: String] = [:]
            var firstToFamily: [String: [String]] = [:]
            var seenFamilies = Set<String>()
            for name in fileNames {
                guard let set = FileSplitCombine.volumeSet(forMemberNamed: name, among: fileNames),
                      set.volumeCount >= 2,
                      !seenFamilies.contains(set.baseName),
                      let first = set.presentNames.first else { continue }
                seenFamilies.insert(set.baseName)
                firstToFamily[first] = set.presentNames
                for member in set.presentNames.dropFirst() {
                    memberToFirst[member] = first
                }
            }
            guard !firstToFamily.isEmpty else { return items.map { FileOutlineNode.file($0) } }
            let byName = Dictionary(items.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
            var nodes: [FileOutlineNode] = []
            for item in items {
                let name = item.url.lastPathComponent
                if memberToFirst[name] != nil { continue }   // 非首卷成员:从顶层抽走,挂进首卷子级
                let node = FileOutlineNode.file(item)
                if let family = firstToFamily[name] {
                    node.volumeChildren = family.compactMap { byName[$0] }.map { FileOutlineNode.file($0) }
                    node.volumeBadgeCount = family.count
                }
                nodes.append(node)
            }
            return nodes
        }

        /// 懒构建文件夹子级节点：子级 FileItem 从**模型注册表**取（没列过会现列 + 登记）。
        /// 模型登记是这次重做的核心 —— 选区解析 / FSEvents 重映射 / 操作目标全从模型走,
        /// 节点树只是视图缓存,跨 reload 由 enforceExpansion 重建。
        private func loadedFolderChildren(of node: FileOutlineNode) -> [FileOutlineNode] {
            if let cached = node.folderChildren { return cached }
            guard let item = node.fileItem else { return [] }
            let children = volumeFoldedNodes(model.expandedChildren(of: item.url))
            node.folderChildren = children
            return children
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
            // 0.4.2 #4：折叠首卷的名称带「· N 卷」徽记。
            var cellText = column.value(for: fileItem)
            if column == .name, node.volumeBadgeCount > 0 {
                cellText = L10n.format("file.volumeBadge", cellText, "\(node.volumeBadgeCount)")
            }
            return makeTableCell(
                in: outlineView,
                owner: self,
                identifier: "FileCell-\(column.identifier)",
                text: cellText,
                isPrimaryColumn: column == .name,
                icon: column == .name ? icon(for: fileItem, size: density.iconSize) : nil,
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
            // 按 identifier 去重再存 —— 绝不把重复列（历史上的「名称」列堆叠 bug）写回偏好。
            var seen = Set<String>()
            let ids = outlineView.tableColumns.map(\.identifier.rawValue).filter { seen.insert($0).inserted }
            AppPreferences.setStringArray(ids, forKey: AppPreferences.Key.fileColumnOrder)
        }

        // 用户手动展开 / 折叠某区块或文件夹 —— 更新真值
        // （隐藏组按 #49 持久化；分类组只记本次会话；文件夹进展开记忆 + 模型注册表）。
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion else { return }
            if let node = sectionNode(from: notification) {
                setSectionExpanded(node, true)
                return
            }
            // 0.4.2 #4 跟进：分卷集展开进记忆（记忆开关关掉则不记,reload 后回到折叠）。
            if let node = notification.userInfo?["NSObject"] as? FileOutlineNode,
               node.volumeChildren != nil, let item = node.fileItem {
                if AppPreferences.rememberVolumeSetExpansion {
                    expandedVolumeSetPaths.insert(item.url.standardizedFileURL.path)
                }
                return
            }
            if let item = expandedFolderNode(from: notification)?.fileItem, AppPreferences.rememberFolderExpansion {
                expandedFolderPaths.insert(item.url.standardizedFileURL.path)
                // 模型注册表由数据源的 loadedFolderChildren → model.expandedChildren 在展开时已登记,这里不必重复。
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion else { return }
            if let node = sectionNode(from: notification) {
                setSectionExpanded(node, false)
                return
            }
            // 0.4.2 #4：折叠分卷集时,落在成员行上的选区收回首卷（Finder 折叠文件夹同款）——
            // 成员不再可见,不应再被 Delete / 菜单悄悄作用。展开记忆同步遗忘。
            if let node = notification.userInfo?["NSObject"] as? FileOutlineNode,
               let firstVolume = node.fileItem, let volumes = node.volumeChildren {
                expandedVolumeSetPaths.remove(firstVolume.url.standardizedFileURL.path)
                let memberIDs = Set(volumes.compactMap { $0.fileItem?.id }).subtracting([firstVolume.id])
                let hiddenSelected = model.selection.intersection(memberIDs)
                if !hiddenSelected.isEmpty {
                    let newSelection = model.selection.subtracting(hiddenSelected).union([firstVolume.id])
                    DispatchQueue.main.async { [weak self] in
                        self?.model.selection = newSelection
                    }
                }
                return
            }
            guard let node = expandedFolderNode(from: notification), let item = node.fileItem else { return }
            let path = item.url.standardizedFileURL.path
            // 连同其下层展开的子孙一起忘掉（折叠父层后子孙的展开状态作废,Finder 同款）。
            expandedFolderPaths.remove(path)
            expandedFolderPaths = expandedFolderPaths.filter { !$0.hasPrefix(path + "/") }
            // 丢节点缓存 + 模型注册表出表：折叠后子级不再可见,不应再可被选中 / 操作；重新展开时现列最新内容。
            node.folderChildren = nil
            model.folderDidCollapse(item.url)
        }

        private func expandedFolderNode(from notification: Notification) -> FileOutlineNode? {
            guard let node = notification.userInfo?["NSObject"] as? FileOutlineNode,
                  let item = node.fileItem, item.isDirectory else { return nil }
            return node
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
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            // 0.4.2 #4：拖动折叠首卷 = 拖整组。pasteboardWriter 一项只能写一个 URL（首卷已写入），
            // 这里把家族其余成员补进拖拽剪贴板 —— 拖去 Finder / 应用内移动读到的就是全家族。
            // 展开箭头后拖单个成员行（节点无 volumeChildren）不扩,尊重字面选择。
            var seenPaths = Set((session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).map(\.path))
            var missingMembers: [NSURL] = []
            for case let node as FileOutlineNode in draggedItems {
                guard let volumes = node.volumeChildren else { continue }
                for member in volumes.compactMap(\.fileItem) where seenPaths.insert(member.url.path).inserted {
                    missingMembers.append(member.url as NSURL)
                }
            }
            if !missingMembers.isEmpty {
                session.draggingPasteboard.writeObjects(missingMembers)
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // 只读虚拟浏览（.gpg / .szs 解密出的临时内容）不收任何拖入。
            guard model.manifestVirtualMode == nil else { return [] }

            // Finder 语义（用户报「不会正确捕获」的修复）：
            // - 精确悬停在「文件夹行」上 → 定点投递进该文件夹（系统高亮那一行）；
            // - 悬停在文件行 / 行间 / 空白 → **重定向**为「放进当前浏览的文件夹」（整表高亮）。
            //   旧实现不重定向，悬在文件行上目标解析失败 → 直接显示禁止符，列表大半是死区。
            let folderRowURL: URL? = {
                guard index == NSOutlineViewDropOnItemIndex,
                      let node = item as? FileOutlineNode,
                      let fileItem = node.fileItem,
                      fileItem.isDirectory,
                      !model.canShowPackageContents(fileItem) else { return nil }
                return fileItem.url
            }()

            let destination: URL
            if let folderRowURL {
                destination = folderRowURL
            } else if case .folder(let url) = model.mode {
                destination = url
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                return []
            }

            let draggedURLs = cachedDraggedURLs(from: info)
            // 防呆（Finder 同款）：不许把项目拖进它自己 / 它的子孙。
            if draggedURLs.contains(where: { destination.path == $0.path || (destination.path + "/").hasPrefix($0.path + "/") }) {
                return []
            }
            let isInternalMove = info.draggingSource as? NSOutlineView === outlineView
            // 应用内移动到「它本来就在的文件夹」= 无操作，直接不允许（避免误触发自我移动）。
            if isInternalMove, !draggedURLs.isEmpty,
               draggedURLs.allSatisfy({ $0.deletingLastPathComponent().path == destination.path }) {
                return []
            }
            return isInternalMove ? .move : .copy
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
            // `.gpg` / `.szs` 解密出的是**临时只读内容**（manifestVirtualMode）。像浏览压缩包内容一样受限：
            // 不提供任何会改动 / 删除临时内容的操作（新建 / 粘贴 / 重命名 / 副本 / 符号链接 / 剪切 / 移动 / 删除），
            // 也不提供「压缩 / 签名 / 加密」这类完整文件管理项 —— 只留查看、导出、校验。
            let isVirtualBrowse = model.manifestVirtualMode != nil

            let clickedFile = (clickedItem as? FileOutlineNode)?.fileItem
            guard clickedFile != nil else {
                if !isVirtualBrowse {
                    appendNewItemMenu(to: menu)
                    menu.addItem(.separator())
                    menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
                    menu.addItem(.separator())
                }
                // #10:当前文件夹里 ≥2 个受支持归档 → 空白处也给「查找疑似重复归档」入口。
                if !isVirtualBrowse,
                   model.fileItems.filter({ !$0.isDirectory && ArchiveService.isSupportedArchive($0.url) }).count >= 2 {
                    menu.addItem(menuItem(L10n.text("dupArchives.menu"), systemImage: "doc.on.doc", action: #selector(findDuplicateArchives)))
                    menu.addItem(.separator())
                }
                // 用 revealCurrentLocation 不用 revealSelected —— 用户右键空白处的意图是「打开我现在看的这个文件夹本身」。
                menu.addItem(menuItem(L10n.text("help.refresh"), systemImage: "arrow.clockwise", action: #selector(refreshBrowser)))
                menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealCurrentLocation)))
                appendFolderGroupingMenu(to: menu)
                return
            }

            // 受限「归档式」菜单（虚拟只读浏览）：查看 / 导出 / 校验，仅此而已。
            if isVirtualBrowse {
                menu.addItem(menuItem(L10n.text("button.open"), systemImage: "arrow.turn.up.right", action: #selector(openSelected)))
                if model.selectedFileItems.count == 1, let item = model.selectedFileItems.first, canOpenInNewBrowser(item) {
                    menu.addItem(menuItem(L10n.text("file.openInNewTab"), systemImage: "plus.rectangle.on.rectangle", action: #selector(openSelectedInNewTab)))
                    menu.addItem(menuItem(L10n.text("file.openInNewWindow"), systemImage: "macwindow.badge.plus", action: #selector(openSelectedInNewWindow)))
                }
                if let first = model.selectedFileItems.first, !FileBrowserService.isNavigableDirectory(first) {
                    appendOpenWithMenu(to: menu)
                }
                menu.addItem(menuItem(L10n.text("file.quickLook"), systemImage: "eye", action: #selector(quickLookSelected)))
                if let item = model.selectedFileItems.first, model.selectedFileItems.count == 1, model.canShowPackageContents(item) {
                    menu.addItem(menuItem(L10n.text("file.showPackageContents"), systemImage: "folder", action: #selector(showPackageContents)))
                }
                menu.addItem(.separator())
                menu.addItem(menuItem(L10n.text("button.hash"), systemImage: "number.square", action: #selector(hashSelected)))
                // 复制 = 导出到剪贴板（只读，不改动临时内容）。不提供剪切 / 粘贴 / 移动 / 删除。
                menu.addItem(menuItem(L10n.text("file.copy"), systemImage: "doc.on.doc", action: #selector(copySelected)))
                menu.addItem(.separator())
                menu.addItem(menuItem(L10n.text("file.getInfo"), systemImage: "info.circle", action: #selector(getInfoSelected)))
                menu.addItem(menuItem(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app", action: #selector(revealSelected)))
                return
            }

            // 右键菜单按「分类」分组，组间用分隔线；低频工具折进二级菜单（用户反馈：太长太长太长）。
            // 分组顺序：① 打开 / 查看 → ② 添加 / 解压 + 签名与加密 ▸ / 归档工具 ▸ / 校验 ▸ → ③ 编辑（文件管理）
            // → ④ 简介 / 在 Finder 中显示 / 分组。各项的显示条件与原来完全一致，只调整了归属与分隔。

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
                // 0.4.2 #26：.szs 当快照用 —— 清单 vs 目录现状的结构比较（新增=未签名新文件）。
                menu.addItem(menuItem(L10n.text("szs.compareWithFolder.menuItem"), systemImage: "arrow.left.arrow.right.circle", action: #selector(compareSZSWithFolder)))
            }
            // 「以压缩包打开」—— 只在选中单个非目录、且不是已识别压缩包时显示。
            if let item = model.selectedFileItems.first,
               model.selectedFileItems.count == 1,
               !item.isDirectory,
               !ArchiveService.isSupportedArchive(item.url) {
                menu.addItem(menuItem(L10n.text("file.openAsArchive"), systemImage: "doc.zipper", action: #selector(openSelectedAsArchive)))
            }

            // ② 压缩 / 归档工具（用户反馈菜单太长 → 同类项折进二级菜单；高频的「添加 / 解压」留一级）。
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("button.addToArchive"), systemImage: "plus.square.on.square", action: #selector(addSelectedToArchive)))
            menu.addItem(menuItem(L10n.text("button.extractHere"), systemImage: "arrow.down.doc", action: #selector(extractSelectedArchive)))
            // 「签名与加密 ▸」—— 仅 GPG 启用 + 后端可用时出现（A4：关了主开关整个子菜单不渲染）。
            if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                let gpgMenu = NSMenu()
                gpgMenu.addItem(menuItem(L10n.text("szs.create.menuItem"), systemImage: "signature", action: #selector(createSignedManifestFromSelection)))
                gpgMenu.addItem(menuItem(L10n.text("file.encrypt.gpg"), systemImage: "lock.doc", action: #selector(encryptSelectedToGPG)))
                menu.addItem(submenuItem(L10n.text("file.submenu.signEncrypt"), systemImage: "lock.shield", submenu: gpgMenu))
            }
            // 「归档工具 ▸」—— 测试 / 比较 / 发布检查 / 空间分析 / 转换 / 拆分合并，各项显示条件不变。
            let toolsMenu = NSMenu()
            // 0.4.2 批量测试：选中 ≥2 个受支持归档时，「测试」变成整批测试 + 活动中心逐包汇总。
            let selectedArchiveCount = model.selectedFileItems.filter { !$0.isDirectory && ArchiveService.isSupportedArchive($0.url) }.count
            if selectedArchiveCount >= 2 {
                toolsMenu.addItem(menuItem(L10n.format("file.batchTest", "\(selectedArchiveCount)"), systemImage: "checkmark.seal", action: #selector(batchTestArchives)))
                // #10:选中 ≥2 个归档 → 按结构指纹/条目数/大小找疑似同包。
                toolsMenu.addItem(menuItem(L10n.text("dupArchives.menu"), systemImage: "doc.on.doc", action: #selector(findDuplicateArchives)))
            } else {
                toolsMenu.addItem(menuItem(L10n.text("button.test"), systemImage: "checkmark.seal", action: #selector(testSelectedArchive)))
            }
            // #111 比较：恰好选中 2 个可比对项（归档或文件夹，0.4.2 #25）→ 直接比；
            // 单选 1 个归档 / 文件夹 → 再挑一个比（面板可选文件夹）。
            let comparableCount = model.selectedFileItems.filter { $0.isDirectory || ArchiveService.isSupportedArchive($0.url) }.count
            if comparableCount == 2, model.selectedFileItems.count == 2 {
                toolsMenu.addItem(menuItem(L10n.text("file.compareArchives"), systemImage: "arrow.left.arrow.right.circle", action: #selector(compareArchivesSelected)))
            } else if comparableCount == 1, model.selectedFileItems.count == 1 {
                toolsMenu.addItem(menuItem(L10n.text("file.compareArchives.withOther"), systemImage: "arrow.left.arrow.right.circle", action: #selector(compareArchivesSelected)))
            }
            // 0.4.2 #15：发布包检查 —— 单选受支持归档时出现。
            if selectedArchiveCount == 1, model.selectedFileItems.count == 1 {
                toolsMenu.addItem(menuItem(L10n.text("inspect.menu"), systemImage: "checklist", action: #selector(inspectArchiveForRelease)))
                // #8:空间分析 —— 同样单选受支持归档时出现。
                toolsMenu.addItem(menuItem(L10n.text("space.menu"), systemImage: "chart.pie", action: #selector(analyzeArchiveSpace)))
            } else if model.selectedFileItems.count == 1, let only = model.selectedFileItems.first,
                      only.isDirectory, only.url.pathExtension.lowercased() == "app" {
                // #6:单选 .app 目录 → 专项发布检查(Info.plist/codesign/Gatekeeper)。
                toolsMenu.addItem(menuItem(L10n.text("inspect.menu"), systemImage: "checklist", action: #selector(inspectArchiveForRelease)))
            } else if model.selectedFileItems.count == 1, let only = model.selectedFileItems.first,
                      only.isDirectory, !only.isPackage {
                // 0.4.4 #11:单选普通文件夹 → 发布目录完整性检查(SHA256SUMS/.szs/公钥/孤儿)。
                toolsMenu.addItem(menuItem(L10n.text("dirAudit.menu"), systemImage: "folder.badge.questionmark", action: #selector(auditReleaseDirectory)))
            }
            // #112 转换格式：选中项全是支持的归档时出现，弹格式选择 sheet 批量转换。
            if model.canConvertSelectedArchives {
                toolsMenu.addItem(menuItem(L10n.text("file.convert.menuItem"), systemImage: "arrow.triangle.2.circlepath", action: #selector(convertArchivesSelected)))
            }
            // 拆分 / 合并分卷（字节级，对齐官方 7-Zip 的 Split / Combine）：单选非目录文件可拆；
            // 选中 .001 首卷多一项「合并分卷」。
            if model.selectedFileItems.count == 1, let item = model.selectedFileItems.first, !item.isDirectory {
                toolsMenu.addItem(.separator())
                // 0.4.2 分卷集识别：右键任意一卷显示「第 N 卷，共 M 卷 · 总大小」+ 缺卷警告（信息行，不可点）。
                appendVolumeSetInfo(to: toolsMenu, for: item.url)
                // #15:检测到缺卷 → 「搜索缺失分卷…」(另选目录递归搜,找齐自动补齐+合并+测试)。
                if let siblings = try? FileManager.default.contentsOfDirectory(atPath: item.url.deletingLastPathComponent().path),
                   let volumeSet = FileSplitCombine.volumeSet(forMemberNamed: item.url.lastPathComponent, among: siblings),
                   !volumeSet.missingIndices.isEmpty {
                    toolsMenu.addItem(menuItem(L10n.text("missingVolumes.menu"), systemImage: "magnifyingglass.circle", action: #selector(searchMissingVolumes)))
                }
                if FileSplitCombine.isFirstVolume(item.url) {
                    toolsMenu.addItem(menuItem(L10n.text("file.combine.menuItem"), systemImage: "arrow.triangle.merge", action: #selector(combineVolumesSelected)))
                }
                toolsMenu.addItem(menuItem(L10n.text("file.split.menuItem"), systemImage: "rectangle.split.2x1", action: #selector(splitFileSelected)))
            }
            menu.addItem(submenuItem(L10n.text("file.submenu.archiveTools"), systemImage: "wrench.and.screwdriver", submenu: toolsMenu))
            // 「校验 ▸」—— 完整哈希家族(全部 + 各算法,与菜单栏「哈希 ▸」同款) / 生成 SHA256SUMS / 验证。
            let checksumMenu = NSMenu()
            checksumMenu.addItem(menuItem(L10n.text("hash.all"), systemImage: "number.square", action: #selector(hashSelected)))
            for algorithm in HashAlgorithm.allCases {
                let algorithmItem = NSMenuItem(title: algorithm.title, action: #selector(hashSelectedWithAlgorithm(_:)), keyEquivalent: "")
                algorithmItem.target = self
                algorithmItem.representedObject = algorithm.rawValue
                checksumMenu.addItem(algorithmItem)
            }
            checksumMenu.addItem(.separator())
            // 0.4.3 #11:校验文件 —— 选中含文件给「生成 SHA256SUMS」;单选校验文件给「验证」。
            if model.selectedFileItems.contains(where: { !$0.isDirectory }) {
                checksumMenu.addItem(menuItem(L10n.text("checksum.generate.menu"), systemImage: "number.square.fill", action: #selector(generateChecksumFile)))
            }
            if model.selectedFileItems.count == 1, let only = model.selectedFileItems.first,
               !only.isDirectory, ChecksumFile.isChecksumFileName(only.name) {
                checksumMenu.addItem(menuItem(L10n.text("checksum.verify.menu"), systemImage: "checkmark.seal", action: #selector(verifyChecksumFileSelected)))
            }
            menu.addItem(submenuItem(L10n.text("file.submenu.checksums"), systemImage: "number.square", submenu: checksumMenu))

            // ③ 编辑 / 文件管理（重命名归到这里，跟复制剪切移动删除一组）
            menu.addItem(.separator())
            // 0.4.2：文件浏览批量重命名（≥2 选中;与归档内共用引擎与 sheet）。
            if model.selectedFileItems.count >= 2 {
                menu.addItem(menuItem(L10n.text("archive.batchRename.menu"), systemImage: "pencil.line", action: #selector(batchRenameFiles)))
            }
            if model.selectedFileItems.count == 1 {
                menu.addItem(menuItem(L10n.text("file.rename"), systemImage: "pencil", action: #selector(renameSelected)))
            }
            menu.addItem(menuItem(L10n.text("file.duplicate"), systemImage: "plus.square.on.square", action: #selector(duplicateSelected)))
            menu.addItem(menuItem(L10n.text("file.makeSymlink"), systemImage: "link", action: #selector(makeSymbolicLinkSelected)))
            menu.addItem(menuItem(L10n.text("file.copy"), systemImage: "doc.on.doc", action: #selector(copySelected)))
            menu.addItem(menuItem(L10n.text("file.cut"), systemImage: "scissors", action: #selector(cutSelected)))
            menu.addItem(menuItem(L10n.text("file.paste"), systemImage: "clipboard", action: #selector(pasteFiles)))
            menu.addItem(menuItem(L10n.text("file.moveTo"), systemImage: "folder.badge.gearshape", action: #selector(moveSelected)))
            // 标签视图专属：从当前标签移除（文件本体不动）—— 用户报「无法从标签里移除」的补全。
            if case .tag(let tagName) = model.mode {
                menu.addItem(menuItem(L10n.format("file.removeFromTag", tagName), systemImage: "tag.slash", action: #selector(removeFromTagSelected)))
            }
            menu.addItem(menuItem(L10n.text("file.delete"), systemImage: "trash", action: #selector(deleteSelected)))

            // ④ 在 Finder 中显示 / 简介 / 分组
            menu.addItem(.separator())
            menu.addItem(menuItem(L10n.text("file.getInfo"), systemImage: "info.circle", action: #selector(getInfoSelected)))
            // 权限与属主（chmod / chown）—— 真实文件浏览才有意义（虚拟只读浏览上面已 return）。
            menu.addItem(menuItem(L10n.text("file.permissions.menuItem"), systemImage: "lock.shield", action: #selector(editPermissionsSelected)))
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
            menu.addItem(menuItem(L10n.text("help.refresh"), systemImage: "arrow.clockwise", action: #selector(refreshBrowser)))
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

        @objc private func refreshBrowser() {
            model.reload()
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

        @objc private func encryptSelectedToGPG() {
            model.encryptSelectionToGPG()
        }

        @objc private func batchRenameFiles() {
            model.requestBatchRenameFiles()
        }

        @objc private func compareSZSWithFolder() {
            model.compareSelectedSZSWithFolder()
        }

        @objc private func silentBrowseSelectedSZS() {
            if let url = model.selectedFileItems.first?.url {
                model.pendingSZSSilentVirtualBrowse = url
            }
        }

        @objc private func extractSelectedArchive() {
            model.extractArchive()
        }

        /// 0.4.2 分卷集意识：识别选中文件所属的分卷家族，往菜单里加「分卷集 …」信息行
        /// （disabled —— 纯展示）和缺卷警告。识别基于同目录的**全部**文件名（不受隐藏过滤影响）。
        private func appendVolumeSetInfo(to menu: NSMenu, for url: URL) {
            let directory = url.deletingLastPathComponent()
            guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  let set = FileSplitCombine.volumeSet(forMemberNamed: url.lastPathComponent, among: siblings) else { return }

            let totalBytes = set.presentNames.reduce(Int64(0)) { sum, name in
                let path = directory.appendingPathComponent(name).path
                return sum + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0)
            }
            let sizeText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let info = NSMenuItem(
                title: L10n.format("volumeSet.info", set.baseName, "\(set.memberIndex)", "\(set.volumeCount)", sizeText),
                action: nil,
                keyEquivalent: ""
            )
            info.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            info.isEnabled = false
            menu.addItem(info)

            if !set.missingIndices.isEmpty {
                let shown = set.missingIndices.prefix(6).map { String(format: "%03d", $0) }.joined(separator: ", ")
                let suffix = set.missingIndices.count > 6 ? L10n.format("volumeSet.missing.more", "\(set.missingIndices.count - 6)") : ""
                let warning = NSMenuItem(
                    title: L10n.format("volumeSet.missing", shown + suffix),
                    action: nil,
                    keyEquivalent: ""
                )
                warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                warning.isEnabled = false
                menu.addItem(warning)
            }
        }

        @objc private func batchTestArchives() {
            model.batchTestSelectedArchives()
        }

        @objc private func inspectArchiveForRelease() {
            model.inspectSelectedArchiveForRelease()
        }

        @objc private func analyzeArchiveSpace() {
            model.analyzeSelectedArchiveSpace()
        }

        @objc private func auditReleaseDirectory() {
            model.auditSelectedReleaseDirectory()
        }

        @objc private func findDuplicateArchives() {
            model.findDuplicateArchivesInFolder()
        }

        @objc private func searchMissingVolumes() {
            model.searchMissingVolumesForSelection()
        }

        @objc private func testSelectedArchive() {
            model.testArchive()
        }

        @objc private func compareArchivesSelected() {
            model.compareSelectedArchives()
        }

        @objc private func hashSelected() {
            model.calculateHash()
        }

        /// 校验子菜单的单算法哈希(representedObject = HashAlgorithm.rawValue)。
        @objc private func hashSelectedWithAlgorithm(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let algorithm = HashAlgorithm(rawValue: raw) else { return }
            model.calculateHash(algorithms: [algorithm])
        }

        @objc private func generateChecksumFile() {
            model.generateChecksumFileForSelection()
        }

        @objc private func verifyChecksumFileSelected() {
            guard let item = model.selectedFileItems.first else { return }
            model.verifyChecksumFile(item)
        }

        @objc private func revealSelected() {
            model.revealInFinder()
        }

        @objc private func quickLookSelected() {
            (outlineView as? ContentDragOutlineView)?.presentQuickLook()
        }

        /// 「显示简介」—— 右键菜单入口，复用 model 上那份实现（菜单栏 File 菜单也走它，避免两份逻辑漂移）。
        @objc private func getInfoSelected() {
            model.showGetInfoForSelection()
        }

        @objc private func editPermissionsSelected() {
            model.editSelectedPermissions()
        }

        @objc private func splitFileSelected() {
            model.splitSelectedFile()
        }

        @objc private func combineVolumesSelected() {
            model.combineSelectedVolumes()
        }

        @objc private func convertArchivesSelected() {
            model.requestConvertSelectedArchives()
        }

        @objc private func removeFromTagSelected() {
            model.removeSelectedFromCurrentTag()
        }

        /// 空白处右键专用：reveal「我现在看的这个文件夹」本身，忽略 selection。
        @objc private func revealCurrentLocation() {
            model.revealCurrentLocationInFinder()
        }

        @objc private func duplicateSelected() {
            model.duplicateSelectedFiles()
        }

        @objc private func makeSymbolicLinkSelected() {
            model.createSymbolicLinkForSelection()
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

        // MARK: - 选择同步

        func applySelection() {
            guard let outlineView else { return }
            // 内联重命名进行中：**不要**回灌选区。selectRowIndexes 会结束正在编辑的字段编辑器，
            // 让刚弹出的新建文件 / 文件夹输入框瞬间消失。外部 FSEvents 刷新会按 URL 重映射 selection（id 全是新 UUID、
            // 集合内容必变），于是每次都触发 applySelection → 百分百拆掉编辑。编辑结束后的 updateNSView 会再正常同步。
            if renamingItem != nil { return }
            // 用户正按着鼠标（橡皮筋框选 / 拖动中）时，**不要**把 model.selection 回灌到表上：
            // 框选每一帧都 表→model→SwiftUI→updateNSView→applySelection，此时 model.selection 比 live 选区滞后一拍，
            // selectRowIndexes 会把选区猛拽回旧值 → 闪烁 / 疯狂抽搐。松手后下一次 updateNSView（按钮已抬起）再正常同步。
            if NSEvent.pressedMouseButtons & 0x1 != 0 { return }
            var indexes = IndexSet()
            // 0.4.2 #4：首卷在「折叠行」和「展开后的成员行」是两个节点、同一个 FileItem id。
            // 同 id 命中多行时只回放用户当前实际选着的那几行;都没选（如外部刷新重映射）才取最上面那行 ——
            // 否则点折叠行会把展开里的首卷成员行也点亮成双选。
            var rowsByItemID: [UUID: [Int]] = [:]
            for node in allFileNodes() {
                guard let item = node.fileItem, model.selection.contains(item.id) else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 { rowsByItemID[item.id, default: []].append(row) }
            }
            let liveSelection = outlineView.selectedRowIndexes
            for rows in rowsByItemID.values {
                let alreadySelected = rows.filter { liveSelection.contains($0) }
                if alreadySelected.isEmpty {
                    if let topmost = rows.min() { indexes.insert(topmost) }
                } else {
                    for row in alreadySelected { indexes.insert(row) }
                }
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
                rememberAncestorExpanded(ancestor)
            }
            let row = outlineView.row(forItem: found.node)
            guard row >= 0 else { return }
            model.selection = [item.id]
            applySelection(IndexSet(integer: row))
            if beginRename(item) {
                model.pendingInlineRenameURL = nil
            }
        }

        /// 展开「目标所在的祖先链」时更新对应真值：区块走原有记忆；文件夹进展开记忆（否则下次 reload 又缩回去）。
        private func rememberAncestorExpanded(_ ancestor: FileOutlineNode) {
            if ancestor.isSection {
                setSectionExpanded(ancestor, true)
            } else if let item = ancestor.fileItem, item.isDirectory {
                expandedFolderPaths.insert(item.url.standardizedFileURL.path)
            }
        }

        /// 删除后把光标落到邻居：选中 pendingSelectionURL 对应的行，并把第一响应者交回 outline，
        /// 这样删一项后方向键能从邻居继续，而不是丢焦点、回到列表顶端。
        /// 邻居还没刷出来（reload 未完成）→ 不清空，下次 updateNSView 再试。
        func performPendingSelectionIfNeeded() {
            guard renamingItem == nil else { return }
            guard let url = model.pendingSelectionURL else { return }
            guard let outlineView,
                  let found = fileNodeAndAncestors(for: url),
                  let item = found.node.fileItem else { return }
            for ancestor in found.ancestors {
                outlineView.expandItem(ancestor)
                rememberAncestorExpanded(ancestor)
            }
            let row = outlineView.row(forItem: found.node)
            guard row >= 0 else { return }
            model.selection = [item.id]
            applySelection(IndexSet(integer: row))
            outlineView.scrollRowToVisible(row)
            outlineView.window?.makeFirstResponder(outlineView)
            model.pendingSelectionURL = nil
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

        /// 二级菜单的父项（无 action，仅挂 submenu）—— 带图标对齐同级普通项。
        private func submenuItem(_ title: String, systemImage: String, submenu: NSMenu) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            parent.submenu = submenu
            return parent
        }

        /// 拖放目标：拖到某个「非包目录」文件行上 → 进那个目录；否则（拖到空白 / 文件 / 分组头）→ 当前文件夹。
        /// 拖动会话内的 URL 缓存：validateDrop 在拖动时每次鼠标移动都会触发，
        /// 每次都 readObjects 解整个剪贴板很浪费 —— 按 draggingSequenceNumber 缓存一份。
        private var dragURLsCache: (sequence: Int, urls: [URL])?

        private func cachedDraggedURLs(from info: NSDraggingInfo) -> [URL] {
            if let cache = dragURLsCache, cache.sequence == info.draggingSequenceNumber {
                return cache.urls
            }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            dragURLsCache = (info.draggingSequenceNumber, urls)
            return urls
        }

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

        // MARK: - 图标异步缓存（#16 /Applications 卡顿修复）

        /// `icon(forFile:)` 取多分辨率 ICNS + 在 cell 里按 18pt 真正绘制（解码），/Applications 101 项实测
        /// 107ms + 236ms，全落在主线程 cell 构建。改为：命中缓存直接用预栅格化位图；未命中先给类型级
        /// 占位图标（实测 ~0.2ms/项），后台取真图标并栅格化（解码一并搬离主线程），回主线程原位刷新可见行。
        private func icon(for item: FileItem, size: CGFloat) -> NSImage {
            if item.isDirectory, !item.isSymbolicLink, !model.canShowPackageContents(item) {
                return NSWorkspace.shared.icon(for: .folder)
            }
            let key = Self.iconCacheKey(for: item, size: size)
            if let cached = Self.fileIconCache.object(forKey: key) {
                return cached
            }
            scheduleIconFetch(path: item.url.path, size: size, cacheKey: key)
            return Self.placeholderIcon(for: item)
        }

        /// path|尺寸|mtime → 预栅格化图标位图。mtime 进 key：文件被替换后旧图标自动失效；
        /// 跨窗口共享，NSCache 内存压力自动回收 + 条数上限兜底。
        private static let fileIconCache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 4096
            return cache
        }()
        /// 正在后台取的 key —— 同一行在图标到位前反复重绘时不重复入队。
        private var iconFetchesInFlight: Set<String> = []

        private static func iconCacheKey(for item: FileItem, size: CGFloat) -> NSString {
            "\(item.url.path)|\(Int(size))|\(item.modified?.timeIntervalSinceReferenceDate ?? 0)" as NSString
        }

        /// 类型级占位：按扩展名取 UTType 通用图标（系统缓存，不解码 ICNS），真图标到位后原位替换。
        private static func placeholderIcon(for item: FileItem) -> NSImage {
            let ext = item.url.pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: item.isDirectory ? .folder : .data)
        }

        private func scheduleIconFetch(path: String, size: CGFloat, cacheKey: NSString) {
            let key = cacheKey as String
            guard !iconFetchesInFlight.contains(key) else { return }
            iconFetchesInFlight.insert(key)
            Task.detached(priority: .userInitiated) { [weak self] in
                let rasterized = Self.rasterizedFileIcon(path: path, pointSize: size)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    Self.fileIconCache.setObject(rasterized, forKey: cacheKey)
                    self.iconFetchesInFlight.remove(key)
                    self.applyFetchedIcon(rasterized, path: path)
                }
            }
        }

        /// 后台线程：取真图标并按目标尺寸栅格化成独立位图（2x，Retina 不糊）。
        /// NSGraphicsContext.current 是线程局部的，后台绘制安全；产物不与他处共享表示，主线程画它零解码。
        private nonisolated static func rasterizedFileIcon(path: String, pointSize: CGFloat) -> NSImage {
            let icon = NSWorkspace.shared.icon(forFile: path)
            let pixels = Int(pointSize * 2)
            guard pixels > 0,
                  let rep = NSBitmapImageRep(
                      bitmapDataPlanes: nil,
                      pixelsWide: pixels,
                      pixelsHigh: pixels,
                      bitsPerSample: 8,
                      samplesPerPixel: 4,
                      hasAlpha: true,
                      isPlanar: false,
                      colorSpaceName: .deviceRGB,
                      bytesPerRow: 0,
                      bitsPerPixel: 0
                  ) else { return icon }
            rep.size = NSSize(width: pointSize, height: pointSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(
                in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            let result = NSImage(size: NSSize(width: pointSize, height: pointSize))
            result.addRepresentation(rep)
            return result
        }

        /// 真图标到位：只原位更新**可见行**里仍显示该文件的 name 列 cell；
        /// 不 reloadData（会拆重命名输入框 / 抖选区），滚出可视区的行下次构建直接命中缓存。
        private func applyFetchedIcon(_ icon: NSImage, path: String) {
            guard let outlineView else { return }
            let nameColumn = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.identifier))
            guard nameColumn >= 0 else { return }
            let visible = outlineView.rows(in: outlineView.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                guard let node = outlineView.item(atRow: row) as? FileOutlineNode,
                      node.fileItem?.url.path == path,
                      let cell = outlineView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView else { continue }
                cell.imageView?.image = icon
            }
        }
    }
}
