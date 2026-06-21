//
//  ArchiveBrowserModel.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  0.1.10：原 2330 行 ArchiveBrowserModel.swift 按功能切成 9 个 extension 文件，本文件
//  只保留 class 声明 + @Published state + inner types + init/deinit + UI-facing 计算属性。
//  其余按域分到同目录 ArchiveBrowserModel+*.swift —— 跨 extension 用的私有成员一律降级到 internal，
//  类是 final 没有继承面积，模块内可见无副作用。
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 主界面的状态模型：负责文件浏览、压缩/解压动作和状态提示。
@MainActor
final class ArchiveBrowserModel: ObservableObject {
    @Published var mode: BrowserMode {
        didSet { recordAIWorkspaceViewingTransition(from: oldValue, to: mode) }
    }
    /// 异步文件夹列举进行中(0.4.3):mode 已发布、新 items 未到 —— FileTable 见此标志跳过
    /// 中间帧重建(否则「新 folderKey + 旧 items」闪一帧未分组视图,用户报的分组闪烁)。
    /// **故意不是 @Published**:FSEvents 在桌面/下载这类目录上每 ~120ms 静默 reload 一次,
    /// 标志每轮 true→false;发布它 = 把「菜单栏被相同值通知风暴冲掉」的老 bug 原样招回来
    /// (上线当天用户实测复发,改回普通 var 后归零)。渲染由 mode / fileItems 自己驱动,
    /// 中间帧守卫只需要在渲染那一刻**读到值**,不需要值的变化去触发渲染。
    /// 只在 +Loading 的 loadFolder / applyLoadedFolder / 错误分支改动。
    var folderListingInFlight = false
    @Published var fileItems: [FileItem] = []
    @Published var archiveItems: [ArchiveItem] = []
    /// 0.4.1 #114：当前打开归档的**归档级**注释（zip / rar 头部 Comment）。
    /// 空 = 没有注释或非归档模式。loadArchive 成功后从 ArchiveService 旁路缓存取。
    /// 0.4.2 起 zip 可编辑（EOCD 原生改写，见 `saveArchiveComment`）。
    @Published var archiveHeaderComment = ""
    /// 归档注释编辑 sheet flag（0.4.2）。横幅铅笔按钮 / 空白区右键置 true → ContentView 弹编辑 sheet。
    @Published var showsArchiveCommentEditor = false
    /// 0.4.2 #7：当前归档的路径安全发现（打开成功后后台分析）。空 = 干净 / 非归档模式。
    /// 只**告知**（横幅 + 报告 sheet），不改变解压 / 打开时既有的安全拦截与确认。
    @Published var archiveSecurityFindings: [ArchiveSecurityFinding] = []
    /// 安全报告 sheet flag。横幅「查看报告」置 true。
    @Published var showsArchiveSecurityReport = false
    /// 0.4.3 #3：当前归档列表对应的磁盘状态戳（size/mtime/inode，列出成功时记录）。
    /// 写回前传给写引擎核对 —— 打开后被 Finder / 其他 App 改过的包,写入会被拦下而不是覆盖外部改动。
    /// 非 @Published：纯写回守门数据,不驱动 UI。
    var archiveListingStamp: FileStateStamp?
    /// 0.4.4 #11:已打开归档被外部(Finder / 其他 App)改写 / 移动 / 删除时的横幅状态。
    /// **事件驱动**(NSFilePresenter 回调里跟 `archiveListingStamp` 比对、相等不发布),
    /// 绝不在 reload / applyLoadedFolder 路径上变动 —— 不触 A17 的 @Published 风暴。nil = 无外部改动。
    @Published var openArchiveExternalChange: OpenArchiveExternalChange?
    /// 盯当前打开归档文件的 presenter(普通 var)。开档时挂、离档 / 换档时停。
    /// 非 private:begin/stop 方法在 +Loading.swift 扩展里(跨文件同类型需 internal)。
    var openArchivePresenter: OpenArchiveFilePresenter?
    /// 0.4.4 #41:打开大归档时**后台预热**的空间分析,按 load generation 标记新鲜度。
    /// 非 @Published(用户点「空间分析」时按需读,不驱动渲染 → A17 安全);命中且同代 = 报告瞬开、
    /// 且不在主线程现算(大包 10 万条 analyze 不再卡点击那一下)。换档 generation 变 → 自动作废。
    var prewarmedSpaceAnalysis: (generation: Int, analysis: ArchiveSpaceAnalysis)?
    /// 0.4.2 #11：批量重命名 sheet（非 nil = 显示）。右键多选文件条目触发。
    @Published var batchRenameRequest: BatchRenameRequest?
    /// 0.4.2 #15：发布包检查报告 sheet（非 nil = 显示）。右键单个归档触发，检查跑完赋值。
    @Published var releaseInspectionReport: ReleaseInspectionReport?
    /// 0.4.4 #11:发布目录检查报告(用户主动触发,非 reload 路径 —— A17 不适用)。
    @Published var releaseDirectoryAuditReport: ReleaseDirectoryAuditReport?
    /// 0.4.4 #43:可复现构建深度报告 sheet(右键文件夹触发,双打包比对完赋值)。
    @Published var reproducibilityReport: ReproducibilityReport?
    /// 0.4.4 #13:归档元数据报告(同上,用户主动触发)。
    @Published var archiveMetadataReport: ArchiveMetadataReport?
    /// 0.4.4 #7:归档体检批处理报告(同上)。
    @Published var archiveCheckupReport: ArchiveCheckupReport?
    /// 0.4.4 #8:数据救援结果报告(同上)。
    @Published var archiveSalvageReport: ArchiveSalvageReport?
    /// 0.4.4 #63:「文件X在哪个包」AI 查询 sheet(菜单触发;非 nil = 显示)。只读 marker,数据在 sheet 里查缓存。
    @Published var archiveFinderRequest: ArchiveFinderRequest?
    /// 0.4.4 #68:敏感/配置/脚本/许可证文件报告(菜单触发;确定性扫描,AI 仅在报告里解释)。
    @Published var sensitiveFileReport: SensitiveFileReport?
    /// 0.4.4 #69:近似重复文件报告(菜单触发;确定性扫描,AI 仅在报告里解释)。
    @Published var nearDuplicateReport: NearDuplicateReport?
    /// 0.4.4 #14:最近一次归档打开的性能快照。**普通 var,绝不 @Published**(A17:
    /// loadArchive 每次打开都写它;只有「复制打开性能报告」按需读,不参与渲染)。
    var lastOpenMetrics: ArchiveOpenMetrics?
    /// 发布助手(工具菜单):打包→检查→校验文件→可选签名一条流的待确认配置。
    @Published var releaseAssistantRequest: ReleaseAssistantRequest?
    /// #8 空间分析报告(非 nil = 弹报告 sheet)。
    @Published var spaceAnalysisReport: ArchiveSpaceAnalysisReport?
    /// 0.4.2 #24：归档内重复文件报告 sheet（非 nil = 显示）。
    @Published var duplicateFilesReport: DuplicateFilesReport?
    /// #10:疑似重复归档(同文件夹按指纹/条目数/大小归组)报告 sheet(非 nil = 显示)。
    @Published var duplicateArchivesReport: DuplicateArchivesReport?
    /// #11:内容搜索 —— 搜索词输入 sheet 与结果 sheet(非 nil = 显示)。
    @Published var contentSearchRequest: ContentSearchRequest?
    @Published var contentSearchReport: ContentSearchReport?
    /// 0.4.2：.gpg 解压确认对话框（非 nil = 显示）。
    @Published var gpgExtractRequest: GPGExtractRequest?
    /// 0.4.2：虚拟浏览导出对话框（非 nil = 显示）。
    @Published var virtualExportRequest: VirtualExportRequest?
    /// 0.4.5 #80 B:双击 AI 抽屉摘要行 →「查看更长总结」弹窗(非 nil = 显示;弹窗里端上模型实时现算)。
    @Published var aiLongSummaryRequest: AILongSummaryRequest?
    /// #113 查找：当前搜索文本（空 = 不过滤）。绑定搜索栏；主列表（文件 / 归档）按它过滤展示。
    @Published var searchText = ""
    /// 搜索栏是否可见。⌘F / 右键「查找」/ 菜单栏「查找」置 true；Esc 或清空收起。
    @Published var isSearchActive = false
    /// ⌘F / 菜单栏「查找」自增它 → ContentView 的 `.onChange` 把原生 `.searchable` 字段（`.searchFocused`）聚焦。
    @Published var searchFocusRequestID = 0

    /// 请求聚焦原生搜索框（⌘F / 菜单栏「查找」用）。
    func requestSearchFocus() {
        searchFocusRequestID += 1
    }

    // #113 高级过滤（归档模式工具栏漏斗菜单）：类型 / 仅加密 / 修改时间窗，与搜索文本 AND。
    @Published var searchKind: ArchiveSearchQuery.Kind = .any
    @Published var searchEncryptedOnly = false
    @Published var searchModifiedWithin: SearchModifiedWindow = .any

    /// 修改时间窗（高级过滤的「最近修改」维度）。cutoff 现算 —— 菜单换挡即时生效。
    enum SearchModifiedWindow: String, CaseIterable, Identifiable {
        case any, day, week, month
        var id: String { rawValue }
        var cutoff: Date? {
            switch self {
            case .any: return nil
            case .day: return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            case .month: return Date().addingTimeInterval(-30 * 86_400)
            }
        }
        var title: String {
            switch self {
            case .any: return L10n.text("search.filter.modified.any")
            case .day: return L10n.text("search.filter.modified.day")
            case .week: return L10n.text("search.filter.modified.week")
            case .month: return L10n.text("search.filter.modified.month")
            }
        }
    }

    /// 高级过滤是否生效中（漏斗图标实心化 + 重置项显隐）。
    var hasActiveAdvancedFilters: Bool {
        searchKind != .any || searchEncryptedOnly || searchModifiedWithin != .any
    }

    func resetAdvancedFilters() {
        searchKind = .any
        searchEncryptedOnly = false
        searchModifiedWithin = .any
    }

    /// 过滤后的归档条目（主列表展示用）。文本 + 高级过滤都空返回全部；否则按 Core `ArchiveSearch` AND 过滤。
    var displayedArchiveItems: [ArchiveItem] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || hasActiveAdvancedFilters else { return archiveItems }
        // 0.4.2 #5：搜索框文本走 token 语法（*.swift / size:>1MB / ext: / encrypted: / crc: /
        // comment: / path: / modified:<7d / regex:），普通词照旧子串。工具栏过滤与 token 合并取交集。
        var query = ArchiveSearchQuery.parse(text)
        query.scope = .fullPath
        if searchKind != .any { query.kind = searchKind }   // 工具栏只在设了值时覆盖 `kind:` token
        query.encryptedOnly = query.encryptedOnly || searchEncryptedOnly
        if let cutoff = searchModifiedWithin.cutoff {
            query.modifiedAfter = max(query.modifiedAfter ?? .distantPast, cutoff)
        }
        return ArchiveSearch.filter(archiveItems, with: query)
    }

    /// 过滤后的文件浏览条目。空搜索返回全部；非空时按显示名 / 完整名匹配。
    var displayedFileItems: [FileItem] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return fileItems }
        return fileItems.filter {
            $0.displayName.localizedCaseInsensitiveContains(text) || $0.name.localizedCaseInsensitiveContains(text)
        }
    }

    /// 收起搜索栏并清空文本 —— Esc / 关闭按钮用。
    func dismissSearch() {
        searchText = ""
        isSearchActive = false
    }

    // MARK: - 保存的过滤器 / 最近搜索（0.4.2 #6）

    @Published var savedSearchFilters: [SavedSearchFilter] = []
    @Published var recentSearchQueries: [String] = []
    private static let searchFilterStore = SavedSearchFilterStore()

    /// 「可疑路径」一键过滤：绝对路径 / `..` 上跳 / 反斜杠 / Windows 盘符 —— 全是路径逃逸样式。
    static let suspiciousPathSearchQuery = #"regex:(^/|(^|/)\.\.(/|$)|\\|^[A-Za-z]:)"#

    /// 应用一条过滤器 / 最近搜索：填回搜索框（token 语法由 displayedArchiveItems 解析）。
    func applySearchQueryString(_ query: String) {
        searchText = query
        isSearchActive = true
    }

    /// 当前搜索状态合成一条可保存的查询串：搜索框原文 + 工具栏过滤折成 token。空 = 没东西可存。
    var currentComposedSearchQuery: String {
        var parts: [String] = []
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { parts.append(text) }
        switch searchKind {
        case .filesOnly: parts.append("kind:files")
        case .foldersOnly: parts.append("kind:folders")
        case .any: break
        }
        if searchEncryptedOnly { parts.append("encrypted:true") }
        switch searchModifiedWithin {
        case .day: parts.append("modified:<24h")
        case .week: parts.append("modified:<7d")
        case .month: parts.append("modified:<30d")
        case .any: break
        }
        return parts.joined(separator: " ")
    }

    func saveCurrentSearchFilter(named name: String) {
        let query = currentComposedSearchQuery
        guard !query.isEmpty else { return }
        savedSearchFilters = Self.searchFilterStore.add(SavedSearchFilter(name: name, query: query))
    }

    func deleteSavedSearchFilter(id: UUID) {
        savedSearchFilters = Self.searchFilterStore.remove(id: id)
    }

    /// 搜索框按回车时记一条最近搜索（去重置顶、上限 8 条）。
    func recordRecentSearch() {
        recentSearchQueries = Self.searchFilterStore.recordRecent(searchText)
    }

    /// 启动 / 建窗时从持久层灌入（init 调）。
    func loadSavedSearchState() {
        savedSearchFilters = Self.searchFilterStore.load()
        recentSearchQueries = Self.searchFilterStore.recents()
    }
    @Published var selection = Set<UUID>()
    @Published var selectedArchiveRows = Set<UUID>()
    /// #72:打开归档后要滚动定位到的条目 id(Spotlight 单文件结果点击 → 跳到该文件)。表格 coordinator 在下次
    /// updateNSView 里消费(scrollRowToVisible)后清空。**故意不加 @Published**:它由 refreshArchiveItems 的
    /// @Published archiveItems 变化顺带驱动一次 updateNSView,在同一拍读取即可,自身不需要也不应再触发发布。
    var pendingRevealArchiveItemID: UUID?
    /// 0.4.1 文件夹原位展开：已展开文件夹的子级清单（key = 文件夹标准化路径）。
    /// **模型必须知道展开的子级** —— 选区解析（selectedFileItems）/ 右键 / 各操作都从这里取。
    /// 上一版把子级只存在 NSOutlineView 节点树里（模型不知道 → 选中子行解析成空选区、右键全失灵），
    /// 被 revert（9775479）；这次注册表就是真值，节点树只是它的视图缓存。
    /// 故意**不加 @Published**：数据源回调里懒加载登记不能触发 SwiftUI 发布；
    /// 子级内容真变化时由 refreshExpandedFolderChildren 显式 objectWillChange.send() 驱动重建。
    var expandedFolderChildrenByPath: [String: [FileItem]] = [:]
    /// 注册表归属的文件夹（标准化路径）。loadFolder 进了别的文件夹 → 整表清空（展开状态不跨目录）。
    var expandedFolderOwnerPath: String?
    /// 展开子级的「内容世代」：refreshExpandedFolderChildren 真换了清单才递增,进表格内容指纹。
    /// 首次展开的懒登记**不**递增 —— 行已由 expandItem 画出,若把登记本身算成内容变化,
    /// 展开后的下一次 updateNSView 会误判变化触发全表 reloadData（无谓闪烁）。
    var expandedChildrenGeneration = 0
    @Published var status = L10n.text("status.ready")
    @Published var isWorking = false
    /// 失败 alert 的完整文案；setter 在 `errorMessage` 上 trim 一次。`nil` = 不展示 alert。
    /// 之前用 `ArchiveOperationFailureAlert` wrapper 包了一层「fullMessage + previewLimit + previewMessage」，
    /// 但 previewLimit 从未被设过其它值，wrapper 跟 `errorMessage` getter/setter 互相把对方藏起来，是过度抽象。
    @Published var operationFailureFullMessage: String?
    @Published var hashReport: HashReport?
    @Published var benchmarkRequest: SevenZipBenchmarkRequest?
    @Published var benchmarkSession: SevenZipBenchmarkSession?
    @Published var operationDetailsSession: ArchiveOperationDetailsSession?
    @Published var isShowingOperationDetails = false
    @Published var archiveCreationRequest: ArchiveCreationRequest?
    /// 右键「加密为 .gpg」的待确认请求 —— 非 nil 时 ContentView 弹 GPGEncryptOptionsView。
    @Published var gpgEncryptRequest: GPGEncryptRequest?
    @Published var extractArchiveRequest: ExtractArchiveRequest?
    @Published var extractSelectionRequest: ExtractSelectionRequest?
    /// 地址栏输入网络归档 URL 触发的「下载并解压」请求 —— 非 nil 时 ContentView 弹 WebExtractSheet。
    /// 只在用户提交地址栏时设置(非 FSEvents reload 路径,A17 不涉及)。
    @Published var webExtractRequest: WebExtractRequest?
    /// 右键「权限与属主…」的待确认请求 —— 非 nil 时 ContentView 弹 FilePermissionsEditorSheet。
    @Published var permissionsEditRequest: FilePermissionsEditRequest?
    /// #111 归档比较结果 —— 非 nil 时 ContentView 弹 ArchiveDiffView。
    @Published var archiveDiffReport: ArchiveDiffReport?
    /// 右键「拆分…」的待确认请求 —— 非 nil 时 ContentView 弹 FileSplitSheet。
    @Published var fileSplitRequest: FileSplitRequest?
    /// #112 批量格式转换确认 sheet 的载荷（非 nil 时弹 ConvertArchiveSheet）。
    @Published var convertArchiveRequest: ConvertArchiveRequest?
    @Published var operationProgress = ArchiveProgressState()
    /// 0.1.10 拆文件前是 `private(set)`，但 setter 现在跑在 +OperationLifecycle extension 里，
    /// `private(set)` 会拒绝 extension 写入；降到默认 internal(set) —— 模块内可读写。
    @Published var canCancelCurrentOperation = false
    @Published var navigationBackStack: [NavigationSnapshot] = []
    @Published var navigationForwardStack: [NavigationSnapshot] = []
    /// **嵌套档案的「上一级」返回栈**:进一层嵌套档案 / 档案内 `.siz`(走 `openNestedArchive`)时压入「**进来时所在的父档案位置**」
    /// （父档案 URL + 父 archivePath,如 `xx.zip` 的 `子目录/`）。在嵌套档案根目录按「上一级」时弹栈回到那里 ——
    /// 而不是退出整条链跳到物理文件夹(用户反馈:从 zip 里的 `.siz` / 内层档案「上一级」不该直接蹦回物理目录)。
    /// 任何**真实**导航(`openArchive` / `openFolder` 的 `recordsHistory: true` 路径)都会清空它;嵌套打开 / 历史恢复
    /// 走 `recordsHistory: false` 不清。临时档案位置永不进**后退栈**(那条仍走 `recordsHistory: false`),所以「后退」不会蹦 `/tmp`。
    var nestedArchiveReturnStack: [NavigationLocation] = []
    /// 镜像自 macOS Finder「个人收藏」侧栏。
    ///
    /// 放在 model 而不是 Sidebar 的 `@State` —— 之前用 `@State` 时主线程赋值后 NSLog 能确认值已到 9，
    /// `favoriteRows` getter 也能读到 9，但屏幕仍然显示初始的 0（fallback 分支）。
    /// 推测是 SwiftUI 在 NavigationSplitView 里对 Sidebar 的 @State 在某条路径上失了 view 身份，
    /// 改用 ObservableObject 的 @Published 后这条路径被绕开。
    @Published var finderFavorites: [FinderFavoritesReader.Item] = []

    /// 「显示路径」覆盖 —— 用于 `.siz` 这种「内层 archive 实际在 /tmp、用户心智里是原文件」的场景。
    /// 设了之后，`title` / `locationText` / `editableLocationText` 都用这个 URL 代替真实的 inner URL，
    /// 用户看到的路径就是 `~/Desktop/xxx.siz` 而不是 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-UUID/archive.zip`。
    /// 切换到其它 mode（folder / tag）或非 SIZ archive 时由 `openArchive` 自动清空。
    @Published var archiveDisplayOverride: URL?

    /// **嵌套档案的虚拟堆叠路径**（档案里套档案）。仅用于地址栏 / 标题**显示**，让用户看懂自己在第几层嵌套，
    /// 例如 `/Users/me/Desktop/xx.zip/xa/a.zip/b.zip/c.zip`。这些中间段是**虚拟目录**，不要求真的可点进 / 可访问。
    /// 进一层嵌套档案压一段（见 `openNestedArchive`）；任何「真实」打开（核心 `openArchive` / `openFolder`）都清空它。
    /// 非空时 `archiveDisplayOverride` 同时指向**最外层真实档案**，供「上一级」退出整条虚拟链回到真实文件夹。
    @Published var nestedDisplayPath: String?

    /// `.siz` 容器在 SimpleZip 内被点开时的待处理请求 —— ContentView 用 `.onChange` 接住跑 unwrap + 验签 sheet。
    /// 不能走 `NSWorkspace.shared.open`：`.siz` UTI 注册到自己会循环创建新主窗口。
    /// 用 @Published 而不是 Notification.Name —— 单发单收的「函数调用穿了通知马甲」（AGENTS A3）。
    ///
    /// **0.3.0**：原先是「待打开 URL + 地址锚点 override + 嵌套 entry 链」三个分散字段，由各调用站点分别
    /// set、`handleSIZOpen` 进入时分别读走并清空 —— 三者一旦没成套设置/清空就会状态错配（如上一次的锚点
    /// 残留污染下一次普通 `.siz` 打开）。现在合成一个原子值 `SIZOpenRequest`，set/read 都是整组。
    @Published var pendingSIZOpen: SIZOpenRequest?

    /// 文件浏览模式选中 `.siz` 点 Extract 时的待处理 URL —— ContentView 用 `.onChange` 接住跑 unwrap + 验签 +
    /// 标准解压对话框。同 `pendingSIZOpen` 的解耦原则。
    @Published var pendingSIZExtract: URL?

    /// 文件浏览模式选中 `.szs` 点 Open / Test 时的待处理 URL —— ContentView 接住后跑 `handleSZSOpen` 弹验证 sheet
    /// （验证 sheet 同时充当 Test 的结果展示：签名 + SHA 全过 = 容器完整）。
    @Published var pendingSZSOpen: URL?

    /// 文件浏览模式选中 `.szs` 点 Extract 时的「解压不适用」提示触发。`.szs` 不是压缩包没法解压；
    /// ContentView 接住后弹 alert 解释并提供「以虚拟目录浏览」按钮。
    @Published var pendingSZSExtractHint: URL?

    /// 右键「以虚拟目录浏览」入口 —— **静默**校验。ContentView 接住后跑 peek + verify：
    /// - 签名 + 全部文件 SHA 校验通过 → 直接进 `openSZSAsVirtualFolder`，**不**弹任何 sheet / alert；
    /// - 任意一项不过 → 弹 alert 列摘要，让用户选「仍然进入」/「查看详情」（走原 SZSVerificationSheet）/ 取消。
    /// 跟 `pendingSZSOpen` 区别：那条永远弹验证 sheet；这条想要「没问题就别打扰」的 UX。
    @Published var pendingSZSSilentVirtualBrowse: URL?

    /// 「右键 → 创建签名清单」触发后传给 ContentView 的预填值（payload root + 已选文件）。同 `pendingSIZOpen` 解耦原则。
    @Published var pendingCreateSZS: CreateSZSPrefill?

    /// 创建 `.szs` 时的预填值 —— 右键入口给 CreateSZSSheet 用，避免用户重新挑根目录 + 重新选文件。
    struct CreateSZSPrefill: Equatable {
        let payloadRoot: URL
        let files: [URL]
    }

    /// `.siz` 打开请求 —— 把原先分散的三个字段合成一个原子值，避免在不同站点分别 set/read 时错配。
    /// `handleSIZOpen` 的 `.onChange` 一次拿到整组上下文，不再向 model 另读 entry 链 / 锚点。
    struct SIZOpenRequest: Equatable {
        /// 待打开的 `.siz` 文件 URL（普通 `.siz` = 它自己；`.gpg` 套 `.siz` = 解出来的 scratch `.siz`）。
        let url: URL
        /// 地址栏锚点 override：`.gpg` 套 `.siz` 时是原始 `.gpg`（避免暴露 `/var/folders/...` scratch 路径）；
        /// nil = 普通 `.siz`，锚点即自身。
        var displayOverride: URL?
        /// 从**档案内**解出的嵌套 `.siz` 的 entry 链路（如 `xa/inner.siz`）：非 nil → 验签后走 `openNestedArchive`
        /// （地址显示嵌套链、「上一级」回真实文件夹）；nil = 顶层 `.siz`，走 `openArchive(displayedAs:)`。
        var nestedEntryName: String?
    }

    /// `.szs` 虚拟目录模式 —— 打开 `.szs` 后用户选择「以虚拟目录浏览」时进入此模式。
    /// `.folder` mode 渲染 `payloadRoot` 真实文件，但 `loadFolder` 应用 filter 只显示**在 manifest 里出现过的文件 +
    /// 含至少一个签名文件的祖先目录**。其他文件（payload root 下没被 manifest 覆盖的）暂时不显示，给用户「这是个签名清单的快照」错觉。
    /// 用户通过 `archiveDisplayOverride` 看到的 title / 地址栏是 `.szs` 文件路径（如 `/Users/yumeka/Desktop/xxx.szs`）。
    @Published var manifestVirtualMode: ManifestVirtualMode?

    /// 0.4.5 #89:AI 工作区里「进入虚拟分组」的下钻链(group 节点)。空 = 工作区根。复用文件夹的返回 / 前进 /
    /// 上一级 / 地址栏(见 `currentNavigationLocation` 的 `.aiWorkspace` + `goUp` + `title`/`locationText`)。
    /// AIWorkspaceView 读它决定当前层显示哪些节点;双击分组 → `drillIntoAIWorkspaceGroup` 记一条历史并下钻。
    @Published var aiWorkspacePath: [AIVirtualNode] = []

    struct ManifestVirtualMode: Equatable {
        /// 原 `.szs` 文件 URL —— 显示用、不参与文件系统操作。
        let manifestURL: URL
        /// 真实根目录 —— 文件系统列表实际跑在这里。
        let payloadRoot: URL
        /// 标准化的签名文件绝对 URL 集合。
        let allowedFiles: Set<URL>
        /// 含至少一个签名文件的祖先目录 URL 集合 —— 让用户能进子目录继续看。
        let allowedDirs: Set<URL>
    }

    let fileManager = FileManager.default
    let extractionCoordinator = ArchiveExtractionCoordinator(fileManager: .default)
    /// 打开的压缩包内容 + 当前路径 + 合成目录派生。生命周期等同于 model。
    let session = ArchiveSession()
    /// 用户主动用「以压缩包打开」打开过的文件 URL 集合（已 standardize）。
    /// 当前导航位置的 archive URL 出现在这里 → 后端调用统一加 `force: true`，
    /// 让 ArchiveService 跳过扩展名校验直接走 7-Zip。`.exe` `.apk` `.ipa` 等本质是 ZIP/NSIS
    /// 的非典型压缩包就是这类用户场景。
    var forcedArchivePaths: Set<String> = []
    /// 本地文件浏览相关的纯逻辑（列目录 / 标签搜索 / FileItem 构造 / 路径补全）。
    let fileBrowser = FileBrowserService()
    /// 「一次一个」长任务的生命周期管理（取消、ID 跟踪、跟 ArchiveService 的子进程联动）。
    let operationRunner = ArchiveOperationRunner()
    /// 0.4.2 升 @Published：动态工具栏按「剪贴板里有没有东西」显隐「粘贴」,复制/剪切瞬间要刷新。
    @Published var fileClipboard: (urls: [URL], shouldMove: Bool)?
    /// 本地文件操作（移动 / 粘贴复制 / 创建副本 / 重命名 / 删除）的撤销 / 重做栈。
    /// 各操作成功后注册逆操作（见 +Undo）；逆操作保守执行 —— 源不在 / 目标被占就跳过报错，绝不覆盖用户数据。
    let fileUndoManager = UndoManager()
    @Published var fileUndoActionName: String?
    @Published var fileRedoActionName: String?
    /// 撤销 / 重做执行期间的逐文件详情(瞬态收集器)：undo 原语每动一个文件就 append 一条,
    /// `recordUndoRedoHistory` 收割后挂成活动中心任务的 transferLog —— 跟解压 / 粘贴同款分组卡片格式。
    /// 非 undo/redo 期间始终为空。
    var undoRedoTransferLog: [TransferLogEntry] = []
    /// 创建新文件 / 文件夹后，等 FileTable 刷出对应行再自动进入现有内联重命名。
    @Published var pendingInlineRenameURL: URL?
    /// 归档里新建条目后，待自动进入内联重命名的归档内路径（跟 `pendingInlineRenameURL` 同一 idiom，ArchiveTable 消费）。
    @Published var pendingInlineRenameArchiveEntry: String?
    /// 删除后键盘光标应落到的「邻居」URL：等 FileTable 刷出后选中它并把焦点交回表格，
    /// 这样删除一项后方向键能从邻居继续，而不是丢焦点、回到列表顶端。
    @Published var pendingSelectionURL: URL?
    /// 双击 `.gpg` 嗅探出是公钥/私钥时承载的导入请求 → ContentView 观察它弹 GPGKeyImportSheet（复用 importKey 后端）。
    @Published var pendingGPGKeyImport: GPGKeyImportRequest?
    /// 当前文件夹的 FSEvents 监视器：内容变化（外部改动 + 本应用自己的增删改 / 重命名）自动刷新列表。
    /// 仅 `.folder` 模式启用，由 `reload()` 统一 watch/stop。引入它后文件操作不再各自手动 reload。
    /// 在 `init()` 里创建（onChange 闭包需要捕获 self）；非 `lazy` —— `lazy` 的隔离初始化器无法在 `deinit` 里访问。
    var folderWatcher: FolderWatcher?
    /// FolderWatcher 回调去抖：把一次批量操作（如粘贴多文件）产生的多次 FSEvents 合并成一次 reload。
    var pendingWatcherReload: Task<Void, Never>?
    /// Finder 收藏来自 sfl4/bookmark + 文件存在性探测；外置卷冷启动时可能慢，不能卡在 model.init。
    var finderFavoritesRefreshTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    var activeLoadGeneration = 0
    var mountedDiskImage: MountedDiskImageSession?
    var openedArchiveItemDirectories: [URL] = []
    /// 在外部 app 打开的归档内文件 → 监视它的临时副本，回前台时若被外部编辑就询问写回原归档（#109 part 3）。
    var pendingArchiveWriteBacks: [PendingArchiveWriteBack] = []

    /// 当前打开的压缩包**已解析口令**：明文包 = `""`；加密包(header-encrypted 7z / 加密 zip)= 打开时
    /// 预设 / 用户输入并验证成功的那个口令。归档内编辑(增删改 / 新建 / 写回)复用它,否则对加密包用空口令
    /// 会直接失败(`addOrReplaceEntries` 等的 `-p` 缺失)。`loadArchive` 每次按当前包重新解析,始终对应正在显示的包。
    var resolvedArchivePassword: String = ""

    init() {
        // 注意：不在这里清理临时目录 —— 那是「全 app 一次性」职责，已移到 AppDelegate 启动时 stale-only 执行。
        // 模型每次 init 都删全局临时根，会误删其它窗口正在用的解压目录（见 cleanStaleOpenedArchiveItems 注释）。
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        loadSavedSearchState()
        folderWatcher = FolderWatcher { [weak self] in
            // FSEvents 回调可能在任意线程；跳回主 actor 再碰 model。
            Task { @MainActor [weak self] in
                self?.handleFolderContentsChanged()
            }
        }
        reload()
    }

    deinit {
        // 显式停 watcher：FSEvent stream 用 passRetained 持有 folderWatcher 一个强引用，
        // 不在这里 stop（→ release stream → 放掉那个 +1），folderWatcher 永远不会被释放。
        folderWatcher?.stop()
        finderFavoritesRefreshTask?.cancel()
        // #11:NSFileCoordinator 会强持有 presenter,窗口关闭时必须显式移除,否则泄漏 + 幽灵回调。
        openArchivePresenter?.stop()
        let openedArchiveItemDirectories = openedArchiveItemDirectories
        Task.detached {
            for directory in openedArchiveItemDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        if let mountedDiskImage {
            Task.detached {
                try? await ArchiveService.detachDiskImage(at: mountedDiskImage.mountPoint)
            }
        }
    }

    var title: String {
        switch mode {
        case .folder(let url):
            // 虚拟目录模式（`.szs` / `.gpg` 解密产物）在 payloadRoot 时显示容器名（如 `xxx.szs` / `secret.txt.gpg`），
            // 而不是真实路径末段（`.gpg` 解密目录是 `/var/folders/...` 的 UUID 目录，丑且无意义）。与 locationText 一致。
            if let virtual = manifestVirtualMode, url.standardizedFileURL.path == virtual.payloadRoot.path {
                return virtual.manifestURL.lastPathComponent
            }
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .archive(let url):
            // 嵌套档案：标题显示最内层档案名（虚拟堆叠串的末段，如 `c.zip`）。
            if let nested = nestedDisplayPath {
                return URL(fileURLWithPath: nested).lastPathComponent
            }
            return (archiveDisplayOverride ?? url).lastPathComponent
        case .tag(let tag):
            return tag
        case .aiWorkspace(let id):
            // 标题 = 当前层(下钻后的子目录名,否则工作区名)。
            return aiWorkspacePath.last?.title ?? aiWorkspaceDisplayTitle(id)
        }
    }

    /// AI 工作区名(工作区已不存在时退回通用「AI 建议」)。
    private func aiWorkspaceDisplayTitle(_ id: UUID) -> String {
        AIWorkspaceStore.shared.workspace(id)?.title ?? L10n.text("browser.aiSuggestions.title")
    }

    /// AI 工作区地址栏面包屑:工作区名 / 子目录 / 更深子目录…(复用地址栏,跟着虚拟路径走)。
    private func aiWorkspaceBreadcrumb(_ id: UUID) -> String {
        ([aiWorkspaceDisplayTitle(id)] + aiWorkspacePath.map(\.title)).joined(separator: " / ")
    }

    /// archive 模式地址栏的「基础路径」：嵌套档案用虚拟堆叠串，否则用真实档案路径（`.siz`/`.gpg` 的 override 或真 URL）。
    private func archiveDisplayBasePath(_ url: URL) -> String {
        nestedDisplayPath ?? (archiveDisplayOverride ?? url).path
    }

    var locationText: String {
        switch mode {
        case .folder(let url):
            // **`.szs` 虚拟模式**：用 manifest URL（如 `/Users/yumeka/Desktop/Desktop.szs`）替代真实路径
            // （`/Users/yumeka/Desktop`），让用户在地址栏看到「我现在在 .szs 里」。子目录拼相对路径。
            if let virtualPath = virtualizedLocationPath(realURL: url) {
                return virtualPath
            }
            return url.path
        case .archive(let url):
            // `archiveDisplayOverride` 给 `.siz` 这种「内层 archive 实际在 /tmp，但用户心智里是
            // 桌面的 `xxx.siz`」的场景用 —— 显示原始 .siz 路径而不是丑陋的 `/var/folders/...`。
            // 嵌套档案则用 `nestedDisplayPath` 把整条虚拟链堆叠出来（archiveDisplayBasePath 统一处理）。
            let baseLocation = L10n.format("location.archive", archiveDisplayBasePath(url))
            let path = session.archivePath
            return path.isEmpty ? baseLocation : "\(baseLocation) / \(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        case .aiWorkspace(let id):
            return aiWorkspaceBreadcrumb(id)
        }
    }

    var editableLocationText: String {
        switch mode {
        case .folder(let url):
            // 同 locationText —— 虚拟模式下编辑态也展示 manifest URL 路径，让用户复制 / 粘贴语义一致。
            if let virtualPath = virtualizedLocationPath(realURL: url) {
                return virtualPath
            }
            return url.path
        case .archive(let url):
            let base = archiveDisplayBasePath(url)
            let path = session.archivePath
            return path.isEmpty ? base : base + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .tag(let tag):
            return L10n.format("location.tag", tag)
        case .aiWorkspace(let id):
            return aiWorkspaceBreadcrumb(id)
        }
    }

    /// 把真实文件系统 URL 翻译成「虚拟 .szs 路径」—— 仅 `manifestVirtualMode` 非空时返回，否则 nil。
    /// - 真实 URL == payloadRoot → 虚拟路径 = manifest URL（如 `/Users/yumeka/Desktop/Desktop.szs`）
    /// - 真实 URL 是 payloadRoot 下子目录 → 拼相对路径（如 `/Users/yumeka/Desktop/Desktop.szs/sub`）
    /// - 真实 URL 在 payloadRoot 之外 → nil（理论上不该出现 —— `loadFolder` 自动退出虚拟模式）
    private func virtualizedLocationPath(realURL: URL) -> String? {
        guard let virtual = manifestVirtualMode else { return nil }
        let realPath = realURL.standardizedFileURL.path
        let rootPath = virtual.payloadRoot.path
        if realPath == rootPath {
            return virtual.manifestURL.path
        }
        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard realPath.hasPrefix(rootWithSlash) else { return nil }
        let rel = String(realPath.dropFirst(rootWithSlash.count))
        return virtual.manifestURL.path + "/" + rel
    }

    // 注意：从**显示中**的列表取选区,不是完整 fileItems / archiveItems。
    // 否则搜索过滤后,选中项被过滤掉不可见时,Delete / 右键 / 菜单仍会作用在那个看不见的项上（数据安全隐患）。
    // 空搜索时 displayed* == 完整列表,行为不变。
    // 0.4.1 文件夹原位展开：已展开文件夹的子级也是可见行,一并解析 —— 这正是上一版 revert 的根因
    // （子级不在平铺名单里 → 选中子行解析成空选区）。子级行不受搜索过滤,但它们确实显示着,可操作是对的。
    var selectedFileItems: [FileItem] {
        var result = displayedFileItems.filter { selection.contains($0.id) }
        if !expandedFolderChildrenByPath.isEmpty {
            result += expandedFolderChildrenByPath.values.flatMap { $0 }.filter { selection.contains($0.id) }
        }
        return result
    }

    var selectedArchiveItems: [ArchiveItem] {
        displayedArchiveItems.filter { selectedArchiveRows.contains($0.id) }
    }

    var errorMessage: String? {
        get { operationFailureFullMessage }
        set { operationFailureFullMessage = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 截断到 600 字符给 alert 顶部预览（避免上百行 stderr 撑爆弹窗）。完整文案仍存 `errorMessage`，
    /// 用户点「打开详情」走 operationDetailsSession 看完整内容。截断逻辑在 Core 里有专属单测。
    var operationFailurePreviewMessage: String {
        guard let message = operationFailureFullMessage else { return "" }
        return ArchiveOperationFailurePreview.truncate(message)
    }

    var isShowingOperationFailureAlert: Bool {
        operationFailureFullMessage != nil
    }

    var canGoUp: Bool {
        if case .tag = mode {
            return false
        }
        if case .folder(let url) = mode {
            return url.path != "/"
        }
        return true
    }

    var canGoBack: Bool {
        !navigationBackStack.isEmpty
    }

    var canGoForward: Bool {
        !navigationForwardStack.isEmpty
    }

    var currentArchiveURLForNavigation: URL {
        if case .archive(let url) = mode {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: "/")
    }

    var currentNavigationLocation: NavigationLocation? {
        switch mode {
        case .folder(let url):
            return .folder(url.standardizedFileURL)
        case .archive(let url):
            return .archive(url.standardizedFileURL, session.archivePath)
        case .tag(let tag):
            return .tag(tag)
        case .aiWorkspace(let id):
            return .aiWorkspace(id, aiWorkspacePath.map(\.id))
        }
    }

    /// 当前位置 + 嵌套档案地址显示上下文,作为一条后退 / 前进历史记录。
    var currentNavigationSnapshot: NavigationSnapshot? {
        guard let location = currentNavigationLocation else { return nil }
        return NavigationSnapshot(
            location: location,
            archiveDisplayOverride: archiveDisplayOverride,
            nestedDisplayPath: nestedDisplayPath
        )
    }
}
