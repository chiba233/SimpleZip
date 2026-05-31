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
    @Published var mode: BrowserMode
    @Published var fileItems: [FileItem] = []
    @Published var archiveItems: [ArchiveItem] = []
    @Published var selection = Set<UUID>()
    @Published var selectedArchiveRows = Set<UUID>()
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
    @Published var extractArchiveRequest: ExtractArchiveRequest?
    @Published var extractSelectionRequest: ExtractSelectionRequest?
    @Published var operationProgress = ArchiveProgressState()
    /// 0.1.10 拆文件前是 `private(set)`，但 setter 现在跑在 +OperationLifecycle extension 里，
    /// `private(set)` 会拒绝 extension 写入；降到默认 internal(set) —— 模块内可读写。
    @Published var canCancelCurrentOperation = false
    @Published var navigationBackStack: [NavigationLocation] = []
    @Published var navigationForwardStack: [NavigationLocation] = []
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

    /// `.siz` 容器在 SimpleZip 内被点开时的待处理 URL —— ContentView 用 `.onChange` 接住跑 unwrap + 验签 sheet。
    /// 不能走 `NSWorkspace.shared.open`：`.siz` UTI 注册到自己会循环创建新主窗口。
    /// 用 @Published 而不是 Notification.Name —— 单发单收的「函数调用穿了通知马甲」（AGENTS A3）。
    @Published var pendingSIZOpen: URL?

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

    /// `.szs` 虚拟目录模式 —— 打开 `.szs` 后用户选择「以虚拟目录浏览」时进入此模式。
    /// `.folder` mode 渲染 `payloadRoot` 真实文件，但 `loadFolder` 应用 filter 只显示**在 manifest 里出现过的文件 +
    /// 含至少一个签名文件的祖先目录**。其他文件（payload root 下没被 manifest 覆盖的）暂时不显示，给用户「这是个签名清单的快照」错觉。
    /// 用户通过 `archiveDisplayOverride` 看到的 title / 地址栏是 `.szs` 文件路径（如 `/Users/yumeka/Desktop/xxx.szs`）。
    @Published var manifestVirtualMode: ManifestVirtualMode?

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
    var forcedArchiveURLs: Set<URL> = []
    /// 本地文件浏览相关的纯逻辑（列目录 / 标签搜索 / FileItem 构造 / 路径补全）。
    let fileBrowser = FileBrowserService()
    /// 「一次一个」长任务的生命周期管理（取消、ID 跟踪、跟 ArchiveService 的子进程联动）。
    let operationRunner = ArchiveOperationRunner()
    var fileClipboard: (urls: [URL], shouldMove: Bool)?
    /// 当前文件夹的 FSEvents 监视器：内容变化（外部改动 + 本应用自己的增删改 / 重命名）自动刷新列表。
    /// 仅 `.folder` 模式启用，由 `reload()` 统一 watch/stop。引入它后文件操作不再各自手动 reload。
    /// 在 `init()` 里创建（onChange 闭包需要捕获 self）；非 `lazy` —— `lazy` 的隔离初始化器无法在 `deinit` 里访问。
    var folderWatcher: FolderWatcher?
    /// FolderWatcher 回调去抖：把一次批量操作（如粘贴多文件）产生的多次 FSEvents 合并成一次 reload。
    var pendingWatcherReload: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    var activeLoadGeneration = 0
    var mountedDiskImage: MountedDiskImageSession?
    var openedArchiveItemDirectories: [URL] = []

    init() {
        // 注意：不在这里清理临时目录 —— 那是「全 app 一次性」职责，已移到 AppDelegate 启动时 stale-only 执行。
        // 模型每次 init 都删全局临时根，会误删其它窗口正在用的解压目录（见 cleanStaleOpenedArchiveItems 注释）。
        mode = .folder(AppPreferences.defaultStartupURL(fileManager: fileManager))
        finderFavorites = FinderFavoritesReader.readWithCache()
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
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .archive(let url):
            return (archiveDisplayOverride ?? url).lastPathComponent
        case .tag(let tag):
            return tag
        }
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
            let displayed = archiveDisplayOverride ?? url
            let baseLocation = L10n.format("location.archive", displayed.path)
            let path = session.archivePath
            return path.isEmpty ? baseLocation : "\(baseLocation) / \(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        case .tag(let tag):
            return L10n.format("location.tag", tag)
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
            let displayed = archiveDisplayOverride ?? url
            let path = session.archivePath
            return path.isEmpty ? displayed.path : displayed.path + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .tag(let tag):
            return L10n.format("location.tag", tag)
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

    var selectedFileItems: [FileItem] {
        fileItems.filter { selection.contains($0.id) }
    }

    var selectedArchiveItems: [ArchiveItem] {
        archiveItems.filter { selectedArchiveRows.contains($0.id) }
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
        }
    }
}
