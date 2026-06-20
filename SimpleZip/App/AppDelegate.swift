//
//  AppDelegate.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import AppKit
import CoreSpotlight
import Foundation
import SwiftUI

/// AppKit 代理：接收 Finder 或“打开方式”传入的文件路径。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 「点空白取消文本焦点」监视器的持有引用（与 app 同生命周期，不移除）。
    private var textFocusMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0.4.2 用户报：批量重命名等对话框的输入框点空白处不会失焦——SwiftUI TextField 在 macOS
        // 上没有这个原生行为,且全 app 的 sheet 都中招。应用级一次性修复:任何 mouseDown 落在
        // 「正在编辑的文本」(字段编辑器 / TextEditor)之外时,把第一响应者交还窗口 = 提交并取消焦点
        // （Finder 同款）。事件原样放行,点中的控件照常响应;点在文本自己(含其滚动条)上不受影响。
        textFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let textView = window.firstResponder as? NSTextView,
                  textView.isEditable else { return event }
            // 命中判定的宿主——字段编辑器(TextField/SecureField)用它正在编辑的控件
            // (field editor 的 delegate 就是那个 NSTextField)。**不能**用 enclosingScrollView:
            // 弹窗内容整体包在 HeightCappedScrollView 里,字段编辑器的最近滚动视图 = 整个弹窗,
            // 点哪都算「在框内」→ 永不失焦(首版用户回报「死都取消不了」的根因)。
            // 只有 TextEditor(非字段编辑器的 NSTextView)才用自己的滚动视图,让点它的滚动条不丢焦点。
            let host: NSView
            if textView.isFieldEditor {
                host = (textView.delegate as? NSView) ?? textView
            } else {
                host = textView.enclosingScrollView ?? textView
            }
            let point = host.convert(event.locationInWindow, from: nil)
            if !host.bounds.contains(point) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        if let icon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApp.applicationIconImage = icon
        }
        NSApp.servicesProvider = self
        // 阶段3:启动即同步 AI 配置 + **暖前台 XPC Service**。开了 AI → publishConfiguration(持久化 + 经 XPC 推配置)
        // 顺带把按需的 XPC Service 拉起来、配置就位 —— 这样「开 AI + 打开 app」XPC 进程就被拉起,前台 AI pass 走它即时可用,
        // 不必等第一条 pass 触发才冷启动。关了 AI → 只持久化红线状态(不必拉起 XPC,省电)。
        if AppPreferences.aiAssistantEnabled {
            AIAgentClient.publishConfiguration()
        } else {
            AIAgentClient.persistConfiguration()
        }
        // 尽早固化「会话开始时间」—— 手动清理临时文件只删早于此刻的陈旧项，保护本次会话在用的 staging。
        let sessionStart = TemporaryResourceManager.sessionStart
        // 启动时单次清理上次会话残留的「打开压缩包内文件」解压目录（stale-only，只删早于本次会话的）。
        // 之前放在 ArchiveBrowserModel.init 且无条件删整个根目录，多窗口时会误删在用解压目录。
        TemporaryResourceManager.cleanStaleOpenedArchiveItems(olderThan: sessionStart)
        // P2b：扫一遍**所有** `SimpleZip*` 临时暂存（不止打开归档的目录，也含归档内编辑 / `.szs` 创建
        // 的 staging —— 崩溃时它们只靠 defer 清理，会残留明文归档内容）。只删早于本次会话的陈旧项，
        // 当前会话在用的 staging（晚于 sessionStart）不碰。递归 stat 必须离开主线程（A18），丢后台跑。
        Task.detached(priority: .utility) {
            TemporaryResourceManager.clearTemporaryArtifacts(olderThan: sessionStart)
        }
        // 「每次启动时检查更新」（通用设置 opt-in）：发现新版才弹提示，已最新则静默。
        SparkleUpdater.shared.checkForUpdatesOnLaunchIfEnabled()

        // 加密临时卷：先清上次会话崩溃残留（遗留挂载 + 镜像），再为本次会话挂一个**随机密钥**的 AES-256 卷。
        // 之后所有解密 / 解压临时产物落进这个卷；关 app 即 detach + 删镜像，明文不留盘（见 SecureScratchVolume）。
        // 懒挂载也行，但启动期预挂载能让随后的同步临时分配（打开档案内文件等）直接命中卷而非回落普通临时目录。
        // 启动卡顿修复:用 `Task.detached` 而非 `Task {}` —— 后者在 main actor 上排队,而 `ensureMounted()`
        // 内部 `hdiutil create` + `hdiutil attach`(建 AES-256 加密镜像并挂载)是内核级 I/O,会和窗口首帧
        // 渲染抢主线程调度位。detach 到后台,首帧不被加密卷挂载拖住(SecureScratchVolume 内部 NSLock 自洽)。
        Task.detached(priority: .utility) {
            await SecureScratchVolume.sweepStale()
            _ = try? await SecureScratchVolume.shared.ensureMounted()
        }

        // #64 冷启动不弹窗修复：app 由「Finder 打开文件」触发启动时，`WindowGroup` 上的
        // `.handlesExternalEvents(matching: [])` 会让 SwiftUI 拒绝创建初始窗口（点 Dock 触发 reopen 才补窗）。
        // 这里在 SwiftUI 做完自己的建窗决定之后（async-to-main）兜底：**只有**在「有待处理外部打开」且
        // 「不存在任何主内容窗口」时，才手动建一个宿主 ContentView 的窗口。
        // 用「有 pending」作门控 —— 正常启动（点图标、无文件）队列为空，绝不会误建多余窗口。
        DispatchQueue.main.async { [weak self] in
            self?.ensureWindowForPendingExternalOpens()
        }

        // 0.4.2 #23：异常退出检测。上次会话没走到 applicationWillTerminate（崩溃 / 强杀）→
        // 启动后提示：残留临时卷 / 临时目录已自动清理（上面两步），可一键导出诊断报告。
        let hadPreviousSession = UserDefaults.standard.object(forKey: Self.cleanShutdownKey) != nil
        let previousWasClean = UserDefaults.standard.bool(forKey: Self.cleanShutdownKey)
        UserDefaults.standard.set(false, forKey: Self.cleanShutdownKey)
        if hadPreviousSession && !previousWasClean {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
                self?.presentUncleanExitNotice()
            }
        }

        // 0.4.2 用户反馈：Finder 右键服务（NSServices）在装新版后常要等系统缓存刷新才出现。
        // 每个版本首次启动时主动刷一次服务缓存（NSUpdateDynamicServices），右键菜单即刻可用，
        // 不必让用户去 系统设置 → 键盘 手动折腾。按版本门控 —— 不在每次启动都打扰 pbs。
        let servicesVersionKey = "SimpleZip.services.lastRegisteredVersion"
        let bundleInfo = Bundle.main.infoDictionary
        let currentVersion = "\(bundleInfo?["CFBundleShortVersionString"] as? String ?? "?")-\(bundleInfo?["CFBundleVersion"] as? String ?? "?")"
        if UserDefaults.standard.string(forKey: servicesVersionKey) != currentVersion {
            NSUpdateDynamicServices()
            UserDefaults.standard.set(currentVersion, forKey: servicesVersionKey)
        }

        // 清洗列顺序偏好：历史上 outlineTableColumn 未解绑的 bug 会把 name 列重复堆进 fileColumnOrder
        // （曾出现 [name, name, size, …]），表头就冒出 2~3 个重复「名称」列。读路径已去重，但**存储里的
        // 污染源没清掉**，仍会被「列移动」重新写回 / 在没走去重的旧路径下复发。启动时按 identifier 去重一次，根除。
        Self.sanitizeColumnOrderPreferences()

        // 0.4.4 macOS 26 AI:把发布账本 / 历史任务 / 归档缓存 / 设置 / 活动选项同步进 Spotlight 语义索引
        // (macOS 15+,旧系统 no-op)。**启动卡顿修复**:以前一口气起 6 个并发 `Task.detached` 全量删 + 全量
        // 写(可达上千条)砸 corespotlightd;现在走**串行协调器**(单后台任务顺序 await)+ 每个索引器「**指纹
        // 没变就跳过**」—— 数据没变的冷启动几乎零成本,变了才重建对应那一个。
        SpotlightStartupCoordinator.reindexAllOnLaunch()
    }

    /// 去掉列顺序偏好里的重复 identifier（修复历史污染，幂等）。
    private static func sanitizeColumnOrderPreferences() {
        for key in [AppPreferences.Key.fileColumnOrder, AppPreferences.Key.archiveColumnOrder] {
            let raw = AppPreferences.stringArray(forKey: key)
            guard !raw.isEmpty else { continue }
            var seen = Set<String>()
            let deduped = raw.filter { seen.insert($0).inserted }
            if deduped != raw {
                AppPreferences.setStringArray(deduped, forKey: key)
            }
        }
    }

    /// 0.4.3 #5:有任务在跑时退出要确认 —— 半路退出会腰斩写回 / 解压(安全写回保证原包不坏,
    /// 但用户的这次操作白做)。三选:继续任务(默认) / 完成后退出(terminateLater,TaskCenter
    /// 在最后一个任务收尾时回 reply) / 立即退出。无任务照常直接退。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TaskCenter.shared.runningCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("quit.tasksRunning.title", "\(running)")
        alert.informativeText = L10n.text("quit.tasksRunning.message")
        alert.addButton(withTitle: L10n.text("quit.tasksRunning.keepRunning"))
        alert.addButton(withTitle: L10n.text("quit.tasksRunning.afterTasks"))
        alert.addButton(withTitle: L10n.text("quit.tasksRunning.quitNow"))
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            TaskCenter.shared.quitWhenAllTasksFinish()
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// 退出时拆除加密临时卷：detach 挂载 + 删镜像。同步尽力（terminate 不能 await）；
    /// 万一没跑成（强杀），残留的镜像是 AES 密文、无害，下次启动 `sweepStale()` 收口。
    func applicationWillTerminate(_ notification: Notification) {
        // 0.4.2:活动中心历史的异步写盘在退出前排空 —— 否则最后完成的任务可能丢。
        TaskCenter.shared.flushHistoryNow()
        SecureScratchVolume.shared.teardown()
        // 0.4.2 #23：正常退出 → 落「干净关闭」标记；崩溃 / 强杀走不到这里，下次启动据此提示。
        UserDefaults.standard.set(true, forKey: Self.cleanShutdownKey)
    }

    /// 0.4.2 #23：异常退出标记 key（会话状态，不进偏好备份）。
    private static let cleanShutdownKey = "SimpleZip.session.cleanShutdown"

    /// 异常退出后的提示：临时资源已自动清理 + 中断任务已在活动中心标出，可导出诊断报告。
    /// 0.4.3 修「启动卡死假象」:以前无条件 `runModal` —— 启动 800ms 后若 app 不在前台
    /// (开机自启 / 焦点被别的 app 抢走),模态面板開在别人后面,主线程困在模态循环,
    /// 整个 app 看起来挂了,用户只能 SIGTERM 强杀(实测调试器停在 runModal 上)。
    /// 现在:有主窗口就挂 **sheet**(不卡全局、永远贴着自己窗口可见);没窗口才回退
    /// runModal,且先显式把 app 拉到前台。
    private func presentUncleanExitNotice() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("recovery.title")
        alert.informativeText = L10n.text("recovery.message")
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.addButton(withTitle: L10n.text("recovery.exportDiagnostics"))
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                DiagnosticsCopier.exportGeneralReport()
            }
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handleResponse(alert.runModal())
        }
    }

    /// reopen（点 Dock 图标 / 无可见窗口时被激活）让 SwiftUI 重建主窗口 —— 标准做法，
    /// 也覆盖「热运行但所有标签都关了之后又点 Dock」的场景。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newTab = NSMenuItem(title: L10n.text("menu.newTab"), action: #selector(openDockNewTab), keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)

        let newWindow = NSMenuItem(title: L10n.text("menu.newWindow"), action: #selector(openDockNewWindow), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)
        return menu
    }

    @objc private func openDockNewTab() {
        MainWindowFactory.open(asTab: true)
    }

    /// 原生标签栏右侧「+」按钮发送 AppKit 标准 `newWindowForTab:` action。
    /// SwiftUI Commands 里的「新建标签页」只覆盖菜单 / 快捷键，不会自动接住这个按钮。
    @objc private func newWindowForTab(_ sender: Any?) {
        MainWindowFactory.open(asTab: true)
    }

    @objc private func openDockNewWindow() {
        MainWindowFactory.open(asTab: false)
    }

    /// 若启动时有待处理的外部打开（文件 / Finder 服务）但 SwiftUI 没建出任何主内容窗口，手动补一个。
    /// 新窗口宿主 `ContentView`，其 `onAppear` 会跑现有的 `ExternalFileOpenQueue.drain()`，把文件打开；
    /// 设共享 `tabbingIdentifier` 以免变成游离窗口、后续新标签能并入。
    /// 若有待处理的外部打开（文件 / Finder 服务）但当前**没有任何主内容窗口**，手动补一个独立窗口。
    /// 覆盖两种场景：① 冷启动（启动期 SwiftUI 没建窗）；② app 在后台运行但所有窗口都关了。
    /// 已有窗口时跳过 —— 那种情况由 ContentView 的 `.onReceive(.openExternalFile)` 处理（开新标签）。
    /// 新窗口的 `ContentView.onAppear` 会跑现有 drain 把文件打开。
    private func ensureWindowForPendingExternalOpens() {
        let pendingURLs = ExternalFileOpenQueue.shared.peek()
        let hasFinderService = !FinderServiceActionQueue.shared.peek().isEmpty
        guard !pendingURLs.isEmpty || hasFinderService else { return }
        guard !NSApp.windows.contains(where: { MainWindow.isMainContentWindow($0) }) else { return }

        // 自动解压「彻底和主窗口脱钩」：冷启动时若待处理项**全是自动解压目标**（普通压缩包 + .siz + .szs），
        // 直接走独立浮窗、**绝不建主窗口**（用户硬要求：开了自动解压就不该拉起主窗口）。
        // 浮窗的 session 会自己处理 unwrap/验签/校验，需要主窗口时浮窗里有「在主窗口打开」入口。
        // 文件夹 / Finder 服务仍走主窗口。
        if !hasFinderService, !pendingURLs.isEmpty,
           pendingURLs.allSatisfy(isAutoExtractFloatURL) {
            ExternalFileOpenQueue.shared.drain().forEach { url in
                ExternalExtractWindowController.shared.open(url)
            }
            return
        }
        MainWindowFactory.open(asTab: false)
    }

    /// 该 URL 是否「开了自动解压、应走独立浮窗、不建主窗口」—— 镜像 ContentView.opensInFloatWindowOnly。
    /// 开了自动解压时：受支持压缩包（非 dmg）+ `.siz` + `.szs` 全部纳入（浮窗内完成 unwrap/验签/校验）。
    private func isAutoExtractFloatURL(_ url: URL) -> Bool {
        guard AppPreferences.finderOpenAutoExtract else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == SIZArchive.extensionName || ext == SZSArchive.extensionName { return true }
        // `.gpg`/`.pgp`/`.asc` 加密数据 → 解密浮窗（冷启动也不拉起主窗口；钥匙串 / 签名不在此）。
        if GPGFileService.shouldAutoDecryptOnExternalOpen(url) { return true }
        guard ArchiveService.isSupportedArchive(url) else { return false }
        let supported = ArchiveService.supportedArchiveURL(url) ?? url
        return supported.pathExtension.lowercased() != "dmg"
    }

    /// 入队后异步排一次「无窗则补窗」检查。async-to-main 让已存在窗口的 ContentView 先有机会处理通知
    /// （开新标签）；只有真的没窗口时才落到这里建窗。
    private func scheduleEnsureWindowForPendingExternalOpens() {
        DispatchQueue.main.async { [weak self] in
            self?.ensureWindowForPendingExternalOpens()
        }
    }

    /// 供 App Intents(#35 打开缓存归档:点 Spotlight 命中 / Shortcuts 接收实体)复用:按外部打开语义
    /// 在 SimpleZip 里打开一个归档,并确保有窗口处理。与 Finder / Open With / `simplezip://open` 同一条路径
    /// (尊重「自动解压」等偏好),但不弹 URL scheme 的确认框 —— 点本 app 自己索引的 Spotlight 结果是用户
    /// 主动、可信的操作。
    @MainActor
    static func openExternalArchive(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        ExternalFileOpenQueue.shared.enqueue(url)
        (NSApp.delegate as? AppDelegate)?.scheduleEnsureWindowForPendingExternalOpens()
    }

    /// #72:打开归档并在加载完成后跳到 `revealEntryPath`(Spotlight 单文件结果点击,自动解压关闭时走浏览跳转)。
    /// 走 `PendingArchiveReveal` 侧信道:loadArchive 收尾按 url 取出执行;开窗 / 路由复用上面的外部打开路径。
    @MainActor
    static func openExternalArchive(_ url: URL, revealEntryPath: String) {
        PendingArchiveReveal.set(entryPath: revealEntryPath, for: url)
        openExternalArchive(url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ExternalFileOpenQueue.shared.enqueue(URL(fileURLWithPath: filename))
        scheduleEnsureWindowForPendingExternalOpens()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames
            .map { URL(fileURLWithPath: $0) }
            .forEach { ExternalFileOpenQueue.shared.enqueue($0) }
        scheduleEnsureWindowForPendingExternalOpens()
        sender.reply(toOpenOrPrint: .success)
    }

    /// #73:Spotlight 结果**点击**走这里 —— 系统把点击当作 `CSSearchableItemActionType` 续期活动派发。
    /// 从 uniqueIdentifier 解出 SpotlightRoute 并执行跳转(设置项深链 / 活动中心定位 / 发布包 reveal /
    /// 打开归档 / 跳到归档内文件)。`indexAppEntities` 的 OpenIntent 自动触发在 macOS 上不可靠,故自己处理。
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        SpotlightTapDispatcher.handle(userActivity)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if FinderServiceActionQueue.shared.enqueue(fromCallbackURL: url) { continue }
            // #16:simplezip://check|compare|open —— 任何进程都能发,先弹确认(列动作+完整路径)。
            if let command = SimpleZipURLCommand.parse(url) {
                handleURLCommand(command)
                continue
            }
            ExternalFileOpenQueue.shared.enqueue(url)
        }
        scheduleEnsureWindowForPendingExternalOpens()
    }

    /// #16:URL scheme 动作的确认 + 入队。check/compare 走 FinderServiceAction 管道
    /// (ContentView 消费,无窗口时由 ensure-window 机制兜底),open 走外部打开队列。
    private func handleURLCommand(_ command: SimpleZipURLCommand) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("urlScheme.confirm.title")
        switch command {
        case .check(let path):
            alert.informativeText = L10n.format("urlScheme.confirm.check", path)
        case .compare(let left, let right):
            alert.informativeText = L10n.format("urlScheme.confirm.compare", left, right)
        case .open(let path):
            alert.informativeText = L10n.format("urlScheme.confirm.open", path)
        }
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch command {
        case .check(let path):
            FinderServiceActionQueue.shared.enqueue(.testArchives([URL(fileURLWithPath: path)]))
        case .compare(let left, let right):
            FinderServiceActionQueue.shared.enqueue(.compareArchives(URL(fileURLWithPath: left), URL(fileURLWithPath: right)))
        case .open(let path):
            ExternalFileOpenQueue.shared.enqueue(URL(fileURLWithPath: path))
        }
    }

    @objc func addToArchiveFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.addToArchive"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.addToArchive(urls))
        }
    }

    @objc func calculateHashFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.hash"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.calculateHash(urls))
        }
    }

    // 以下几项与上面两个完全同构（NSServices）：声明在 Info.plist 的 NSServices，方法名对上 NSMessage，
    // servicesProvider = self。Finder 右键集成全部走 macOS 服务（不再有独立的 FinderSync 扩展），
    // 这几个动作和「添加到压缩包 / 计算哈希」一样是真·NSServices。
    @objc func extractFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.extract"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.extract(urls))
        }
    }

    @objc func createZipFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.addToArchive"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.quickCreate(.zip, urls))
        }
    }

    @objc func createSevenZipFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.addToArchive"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.quickCreate(.sevenZip, urls))
        }
    }

    @objc func createTarGzFromFinder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handleFinderService(pasteboard, actionName: L10n.text("button.addToArchive"), error: error) { urls in
            FinderServiceActionQueue.shared.enqueue(.quickCreate(.tarGzip, urls))
        }
    }

    private func handleFinderService(
        _ pasteboard: NSPasteboard,
        actionName: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>,
        enqueue: ([URL]) -> Void
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = ((pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]) ?? [])
            .compactMap { $0 as URL }

        guard !urls.isEmpty else {
            error.pointee = L10n.format("finderService.error.noFiles", actionName) as NSString
            return
        }

        enqueue(urls)
        NSApp.activate(ignoringOtherApps: true)
        scheduleEnsureWindowForPendingExternalOpens()
    }
}
