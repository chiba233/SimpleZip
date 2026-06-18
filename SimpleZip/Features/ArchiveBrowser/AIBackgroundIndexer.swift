//
//  AIBackgroundIndexer.swift
//  SimpleZip
//
//  0.4.5 #80 #89:后台 AI 文件预索引扫描器(白皮书工程补充六)。**security-sensitive。**
//
//  硬约束(全部满足才跑,且实现层层兜底):
//  - **opt-in 门控**:`AIBackgroundIndexStore.folderPreindexEnabled`(AI 主开关 + 活跃度≠off + 子开关 + 有白名单)。
//  - **白名单**:只走 `AIArchivePrefetchScope` 列出的目录。
//  - **只读 + 仅元数据**:只取文件名 / 大小 / mtime / 是否目录;**绝不读内容**(内容门控另在 readability policy)。
//  - **排除**:`AIPrefetchExclusions`(系统 / 密钥 / 缓存 / 开发依赖 / 临时目录)+ 跳过隐藏文件(避开 .ssh/.env)。
//  - **不跟符号链接**(防逃逸白名单 / 环);外置 / 网络卷默认不进(scope 未显式允许)。
//  - **预算化**:每轮 scope 数 + 每 scope 文件 / 目录上限,按活跃度档位;**可取消**;**全程 off-main**(A18)。
//  - 文件名经 `AIFileMemoryRecord.make` 脱敏(疑似密钥名抹除)。
//

import AppKit
import Foundation
import IOKit.ps   // 电源状态(低电 / 充电)给后台调度规则用

@MainActor
final class AIBackgroundIndexer {
    static let shared = AIBackgroundIndexer()

    /// App 启动时刻(≈ shared 首次创建)—— 算「距启动秒数」给启动静默期(60s)用。
    private let launchDate = Date()
    /// 距用户上次交互 —— 本地事件监视器更新。**只在 app 活跃时捕获事件**:app 在后台 = 无本地事件 = 距上次交互
    /// 持续增长 = 视为空闲,正合「用户没在用 SimpleZip 时才跑模型」。
    private var lastInteractionDate = Date()
    private var interactionMonitor: Any?

    private init() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            self?.lastInteractionDate = Date()
            return event
        }
    }

    /// 组装当前运行时上下文给 `AIBackgroundSchedulingRules` 判定能跑到哪档(时间换算在这里做,Core 不读墙钟)。
    func currentRuntimeContext() -> AIBackgroundRuntimeContext {
        let now = Date()
        let power = AIBackgroundIndexer.powerState()
        return AIBackgroundRuntimeContext(
            appIsActive: NSApplication.shared.isActive,
            runningTaskCount: TaskCenter.shared.active.count,
            heavyArchiveTaskRunning: TaskCenter.shared.active.contains {
                OperationTask.pausableKinds.contains($0.kind) && $0.status.isRunning
            },
            secondsSinceLaunch: Int(now.timeIntervalSince(launchDate)),
            secondsSinceLastInteraction: Int(now.timeIntervalSince(lastInteractionDate)),
            powerSaverMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lowBattery: power.lowBattery,
            isCharging: power.isCharging,
            modelAvailable: AIReportAssistant.isReady,
            activityLevel: AppPreferences.aiBackgroundActivityLevel)
    }

    /// 现在能不能跑端上模型轻任务(空闲 + 模型可用 + 非低电/省电 + 过启动静默)。各模型 pass 入口共用。
    func canRunModelWorkNow() -> Bool {
        AIBackgroundSchedulingRules.canRunModelWork(currentRuntimeContext())
    }

    /// 现在能不能跑深度上下文 pass(充电 + balanced/aggressive)。包定性需要读完整归档清单并跑模型,归入这一档。
    func canRunDeepContextNow() -> Bool {
        AIBackgroundSchedulingRules.canRunDeepContext(currentRuntimeContext())
    }

    /// 读电源状态(低电 < 20% / 是否充电)。无电池(台式机)→ 不低电、充电未知。off-main 安全(纯 IOKit 读)。
    private nonisolated static func powerState() -> (lowBattery: Bool, isCharging: Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return (false, nil)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let pct = maxCap > 0 ? capacity * 100 / maxCap : 100
            let charging = (desc[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            return (pct < 20, charging)
        }
        return (false, nil)
    }

    private var running = false
    private var task: Task<Void, Never>?
    private var archiveRunning = false
    private var archiveTask: Task<Void, Never>?
    private var suggestionRunning = false
    private var suggestionTask: Task<Void, Never>?
    private var diskImageRunning = false
    private var diskImageTask: Task<Void, Never>?
    private var activityRunning = false
    private var activityTask: Task<Void, Never>?
    private var archiveEntryRunning = false
    private var archiveEntryTask: Task<Void, Never>?
    private var archiveKindRunning = false
    private var archiveKindTask: Task<Void, Never>?

    /// 跑一轮预索引(门控未过则直接返回 —— 默认 opt-in 关闭即什么都不做)。完成后通知发现编排者刷新。
    func runIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !running, store.indexingEnabled, let budget = store.budget else { return }
        // AI 电源规范③:启动静默 60s + 无重归档任务 + 活跃度非关。低电 / 省电也可(只读索引不耗模型)。
        guard AIBackgroundSchedulingRules.canRunDeterministicIndexing(currentRuntimeContext()) else { return }
        running = true

        let scopes = Array(store.scopes.prefix(max(1, budget.maxDirectoriesPerRound)))
        let home = NSHomeDirectory()
        let fileBudget = min(budget.maxEntriesPerArchive, 3_000)
        // 内容预读是**更高隐私等级的独立开关**:只元数据预索引时 allowContent=false(绝不读内容);开了「预读内容」
        // 才对「定主题」文档读头部产脱敏摘要(归档内容预读是另一条路,见 archivePrefetchEnabled)。
        let allowContent = store.contentPrereadEnabled
        // 渐进覆盖:把上一轮已有摘要的记录带进去,指纹没变的直接沿用、不重读 → 预算轮到没读过/变了的文件。
        let existingSummarized = allowContent ? store.summarizedRecordsByID() : [:]

        task = Task.detached(priority: .background) {
            var results: [(UUID, [AIFileMemoryRecord])] = []
            for scope in scopes {
                if Task.isCancelled { break }
                let records = AIBackgroundIndexer.scanScope(scope, home: home, fileBudget: fileBudget,
                                                            allowContent: allowContent,
                                                            existingSummarized: existingSummarized)
                results.append((scope.id, records))
            }
            let scanned = results   // 不可变快照后再跨 actor 边界(Swift 6:别捕获可变 var)
            await MainActor.run {
                // M7:回主线程后再核一遍门控 —— 扫描期间用户可能关了开关 / 清了白名单,关了就不落盘。
                if store.indexingEnabled {
                    let now = Date()
                    for (id, records) in scanned {
                        store.ingest(records: records, folders: [], scopeID: id, at: now)
                        store.markScanned(id, at: now)
                    }
                    // (AI 文件夹自动发现已下线 → 不再 index 完回调 discovery.refresh();索引 / 预读照常给 AI suggestion 用。)
                    AIBackgroundIndexer.shared.prereadArchivesIfEnabled()   // 元数据落盘后预读归档内容(确定性档,门控未过则空跑)
                    // AI 电源规范③:模型类 pass 只在「用户空闲 20s + 模型可用 + 非低电/省电」时跑(不打扰正在用 app 的用户)。
                    if AIBackgroundIndexer.shared.canRunModelWorkNow() {
                        AIBackgroundIndexer.shared.generateFileSuggestionsIfEnabled()   // 近阈值/空闲文件出模型建议
                        AIBackgroundIndexer.shared.generateDiskImageSuggestionsIfEnabled()   // 内含 App 的 dmg「安装到应用程序」
                        AIBackgroundIndexer.shared.generateActivityLinkSuggestionsIfEnabled()   // 命中近期任务产物「查看活动」
                        AIBackgroundIndexer.shared.generateArchiveEntrySuggestionsIfEnabled()   // 归档「也许你要包里的 X」
                        if AIBackgroundIndexer.shared.canRunDeepContextNow() {
                            AIBackgroundIndexer.shared.generateArchiveKindGuessIfEnabled()   // 归档「这看起来是什么包」
                        }
                    }
                }
                AIBackgroundIndexer.shared.running = false
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil; running = false
        archiveTask?.cancel(); archiveTask = nil; archiveRunning = false
        suggestionTask?.cancel(); suggestionTask = nil; suggestionRunning = false
        diskImageTask?.cancel(); diskImageTask = nil; diskImageRunning = false
        activityTask?.cancel(); activityTask = nil; activityRunning = false
        archiveEntryTask?.cancel(); archiveEntryTask = nil; archiveEntryRunning = false
        archiveKindTask?.cancel(); archiveKindTask = nil; archiveKindRunning = false
    }

    // MARK: - 内容预读 · 归档半边(MainActor:ArchiveService 在 app target 下 MainActor 隔离,A18)

    /// 开了「预读内容」时,挑白名单里**还没列过清单**的少量归档,只读列出内部条目 → 写归档清单缓存(它顺带进
    /// Spotlight,和打开归档时同一条路 #35/#72)→ `ArchiveMemoryIndex` 据此派生候选进 AI 文件夹池。加密(空口令列
    /// 不动)/ 损坏 / 临时包 → 跳过。预算化(每轮 ≤ maxArchivesPerRound)、可取消、串行不抢主线程重活。
    func prereadArchivesIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard !archiveRunning, store.contentPrereadEnabled, AppPreferences.archiveListingCacheEnabled,
              let budget = store.budget else { return }
        // 缓存指纹:canonicalPath → (大小, 修改时间)。指纹没变 = 已列过且没变 → 跳过;变了(如重新下载)→ 重列。
        // 这和文件预读同款渐进覆盖:预算只花在「没列过 / 变了」的包上,高权重列完慢慢轮到其余。
        let cachedFingerprint = Dictionary(
            ArchiveListingCacheStore().loadAll().map { ($0.archivePath, ($0.archiveByteSize, $0.archiveModified)) },
            uniquingKeysWith: { first, _ in first })
        let tempPrefix = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let staleRecords = store.recentFileRecords(limit: 2_000).filter { rec in
            guard rec.type == .archive, let path = rec.path else { return false }
            let url = URL(fileURLWithPath: path)
            let p = url.resolvingSymlinksInPath().path
            guard !p.hasPrefix(tempPrefix) else { return false }                    // 临时解压壳层不预读
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let canonical = ArchiveListingCacheStore.canonicalPath(for: url)
            if let fp = cachedFingerprint[canonical], fp.0 == rec.byteSize, fp.1 == rec.modifiedAt {
                return false   // 指纹没变 → 已列过、跳过
            }
            return true        // 新 / 变了 → 候选
        }
        // AI 排序挑前 N(近期碰过 / 改过的包先列)。
        let pick = AIPrereadSelection
            .selectArchivesForListing(records: staleRecords, budget: budget.maxArchiveListingsPerRound, now: Date())
            .compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
        guard !pick.isEmpty else { return }
        archiveRunning = true
        archiveTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.archiveRunning = false }
            for url in pick {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled else { break }   // 期间被关
                // 空口令只读列举:加密头 / 损坏 → 抛错跳过(绝不弹密码、绝不解压)。
                guard let items = try? await ArchiveService.list(url) else { continue }
                if ArchiveListingCacheStore().record(archiveURL: url, items: items) {
                    CachedArchiveSpotlightIndexer.indexArchive(at: url)   // 归档级 + 逐条进 Spotlight(双门控在 indexer 里)
                    ArchiveFileSpotlightIndexer.indexArchive(at: url)
                }
            }
            // (AI 文件夹自动发现已下线 → 预读完不再回调 discovery.refresh();归档清单缓存照常给 AI suggestion / Spotlight 用。)
        }
    }

    // MARK: - ②b/②c 模型驱动建议(MainActor:模型调用 async + 串行闸;每轮少量近阈值文件)

    /// 对**已预读、AI 建议评分近阈值、还没出模型建议**的少量文件,端上模型出 {一句话摘要 + 建议动作 token},
    /// 写回预索引(`applyModelSuggestion`)。**拒绝假AI**:文件浏览器只读这个缓存,没有就空抽屉。门控:内容预读开关 +
    /// 模型就绪。预算 = **AI 活跃度档位**对应的 `maxModelSuggestionsPerRound`(不再是脱离设置的孤儿常量)。
    /// 重读头部 + 脱敏在后台线程(只重读这极少量近阈值文件,不影响阶段一扫描)。可取消、串行不重叠。
    func generateFileSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        // AI 建议子开关关 → 自动总结模块停跑(用户:关了 AI 建议把自动总结一起关)。
        guard !suggestionRunning, AppPreferences.aiSuggestionEnabled,
              store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        let now = Date()
        let records = store.recentFileRecords(limit: 2_000)
        // 高价值(近阈值)优先吃预算;吃不满(高分都补完了)→ 用剩余预算给阈值下文件慢慢补摘要(backlog 第5项:
        // 阈值当优先级而非硬闸,每文件一次,后台逐渐平静)。空闲门控由 backlog 第6项 SchedulingRules 统一加。
        var candidates = AIPrereadSelection.selectForModelSuggestion(
            records: records, budget: budget.maxModelSuggestionsPerRound, now: now)
        if candidates.count < budget.maxModelSuggestionsPerRound {
            candidates += AIPrereadSelection.selectForIdleSummary(
                records: records, budget: budget.maxModelSuggestionsPerRound - candidates.count, now: now)
        }
        guard !candidates.isEmpty else { return }
        suggestionRunning = true
        suggestionTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.suggestionRunning = false }
            for rec in candidates {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, let summary = rec.contentSummary,
                      FileManager.default.fileExists(atPath: path) else { continue }
                let fileName = (path as NSString).lastPathComponent
                // 重读头部 + 脱敏在后台线程(不阻塞主线程);拿不到内容(无权限 / 二进制 / 被红线拦)→ 跳过。
                let excerptTask = Task.detached(priority: .background) {
                    (excerpt: AIBackgroundIndexer.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: fileName),
                     apps: AIBackgroundIndexer.nonDefaultOpenApps(forPath: path))   // 推荐打开方式:非默认候选 App(纯元数据)
                }
                let probed = await excerptTask.value
                guard let excerpt = probed.excerpt else { continue }
                let kind = rec.type == .archive ? "archive" : "file"
                let folderToken = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                let discouragedTokens = Array(AIFeedbackStore.shared.discouragedTokens(forFolderToken: folderToken)).sorted()
                guard let result = try? await AIVirtualFolderModelPlanner.fileSuggestion(
                    fileName: rec.fileName, kind: kind, roleTags: rec.roleTags,
                    languageHint: summary.languageHint, headings: summary.headings,
                    fieldNames: summary.fieldNames, excerpt: excerpt,
                    candidateOpenApps: probed.apps, discouragedTokens: discouragedTokens),
                    !result.summary.isEmpty || !result.actions.isEmpty else { continue }
                AIBackgroundIndexStore.shared.applyModelSuggestion(
                    recordID: rec.id, summary: result.summary, actions: result.actions)
            }
        }
    }

    // MARK: - 磁盘镜像安装建议(推荐打开方式 backlog 第2项;MainActor:7zz peek + 模型 async)

    /// 对**还没评估、内含 App 的 .dmg**,后台出「安装到应用程序」建议:① 7zz **只读 peek**(纯文件读、不挂载,实测
    /// ~17ms)列出 dmg 内的 `.app` 包;② 有 App → 端上模型出 {一句话定性 + 是否建议安装}(拒绝假AI:确定性只找到
    /// 「有 .app」这个候选,冒不冒 + 措辞由模型定);③ 写回索引(`setDiskImageSuggestion`)。门控同单文件建议
    /// (AI 建议开关 + 内容预读 + 模型就绪);预算 = AI 活跃度档位的 `maxModelSuggestionsPerRound`。可取消、串行不重叠。
    /// **peek 阶段绝不挂载**(纯 7zz 文件读);点击「安装 X」才走 app 内置复制逻辑把 .app 拷进 /Applications(用户授权)。
    func generateDiskImageSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard !diskImageRunning, AppPreferences.aiSuggestionEnabled,
              store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        let candidates = AIPrereadSelection.selectDiskImagesForSuggestion(
            records: store.recentFileRecords(limit: 2_000),
            budget: budget.maxModelSuggestionsPerRound, now: Date())
        guard !candidates.isEmpty else { return }
        diskImageRunning = true
        diskImageTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.diskImageRunning = false }
            for rec in candidates {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
                // 7zz 只读 peek(空口令;加密 / 不可读 dmg 抛错 → 当作无 App 标记已评估,绝不挂载、绝不弹密码)。
                let appNames = (try? await SevenZipBackend.list(URL(fileURLWithPath: path)))
                    .map { AIBackgroundIndexer.topAppBundleNames(in: $0) } ?? []
                guard !appNames.isEmpty else {
                    AIBackgroundIndexStore.shared.setDiskImageSuggestion(recordID: rec.id, summary: nil, appName: nil)
                    continue   // 没 .app(或 peek 失败)→ 标记已评估,下轮不再选
                }
                // 模型决定冒不冒 + 措辞;模型失败 → 不标记(下轮重试,budget 兜底不会失控)。
                guard let result = try? await AIVirtualFolderModelPlanner.diskImageInstallSuggestion(
                    dmgName: rec.fileName, appNames: appNames) else { continue }
                AIBackgroundIndexStore.shared.setDiskImageSuggestion(
                    recordID: rec.id,
                    summary: result.summary.isEmpty ? nil : result.summary,
                    appName: result.suggest ? appNames.first : nil)
            }
        }
    }

    /// 从 7zz 对一个 dmg 的清单里抽出 `.app` 包名(去重、封顶 6)。条目 `name` 是完整条目路径,形如
    /// `DockDoor Installer/DockDoor.app/Contents/...`;取每条路径里第一个以 `.app` 结尾的路径段即可;
    /// `Applications` 软链等非 .app 段忽略。无 → 空数组。
    nonisolated static func topAppBundleNames(in items: [ArchiveItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            for comp in item.name.split(separator: "/") where comp.hasSuffix(".app") {
                let name = String(comp)
                if seen.insert(name).inserted { out.append(name) }
                break   // 这条路径的第一个 .app 段就够(再深的是包内文件)
            }
            if out.count >= 6 { break }
        }
        return out
    }

    // MARK: - 「文件有活动」建议(backlog 第3项;MainActor:读活动快照 + 模型 async)

    /// 文件精确命中**近期成功任务的产物路径**(复用喂 Spotlight 的活动快照 `ArchiveTaskSnapshot.outputPath`)→ 端上
    /// 模型用一句话提醒「最近对它做过什么」→ 写回 `openTask` 动作(导航复用现成 `.openTask` 路由,零新代码)。门控:
    /// AI 建议开关 + 后台索引 + 模型就绪;预算挂活跃度档;**已指向同一任务的跳过**(任务变了才重做)。目录行无抽屉 → 跳过。
    func generateActivityLinkSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard !activityRunning, AppPreferences.aiSuggestionEnabled,
              store.indexingEnabled, AIReportAssistant.isReady, let budget = store.budget else { return }
        // 喂 Spotlight 的同一份任务快照:成功 + 有产物 + 近 30 天 → 产物路径 → 最近那条(快照新→旧,首遇即最新)。
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var taskByPath: [String: ArchiveTaskSnapshot] = [:]
        for snap in ActivityHistoryStore.snapshot() {
            guard snap.outcome == .succeeded, let path = snap.outputPath,
                  (snap.finishedAt ?? snap.startedAt) >= cutoff else { continue }
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            if taskByPath[std] == nil { taskByPath[std] = snap }   // 首遇 = 最新
        }
        guard !taskByPath.isEmpty else { return }
        // 选:文件(非目录,目录行没抽屉)+ 路径命中任务 + 还没指向这条任务(指向同一任务 = 已做,跳过)。
        var picks: [(rec: AIFileMemoryRecord, snap: ArchiveTaskSnapshot)] = []
        for rec in store.recentFileRecords(limit: 2_000) {
            guard rec.type != .folder, let path = rec.path else { continue }
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let snap = taskByPath[std] else { continue }
            if rec.contentSummary?.action(forToken: "openTask")?.payload == snap.id.uuidString { continue }
            picks.append((rec, snap))
            if picks.count >= budget.maxModelSuggestionsPerRound { break }
        }
        guard !picks.isEmpty else { return }
        activityRunning = true
        activityTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.activityRunning = false }
            for (rec, snap) in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
                let actionText = AIBackgroundIndexer.activityActionText(for: snap.kind)
                let whenText = AIBackgroundIndexer.coarseWhenText(snap.finishedAt ?? snap.startedAt, now: Date())
                guard let phrasing = try? await AIVirtualFolderModelPlanner.activityReminder(
                    fileName: rec.fileName, actionText: actionText, whenText: whenText),
                    !phrasing.isEmpty else { continue }
                AIBackgroundIndexStore.shared.applyActivitySuggestion(recordID: rec.id, taskID: snap.id, phrasing: phrasing)
            }
        }
    }

    /// 任务类型 → 「产生这个文件时做了什么」的中性英文描述(模型转界面语言;**不含任何具体软件名**,见提示词规矩)。
    nonisolated static func activityActionText(for kind: OperationTask.Kind) -> String {
        switch kind {
        case .compress, .create: return "created this archive by compressing files"
        case .convert:           return "created this by converting another archive"
        case .extract:           return "extracted files to produce this"
        case .copy, .paste:      return "copied files here"
        case .move:              return "moved files here"
        case .split:             return "split an archive into volumes here"
        case .combine:           return "combined split volumes into this file"
        default:                 return "produced this file"
        }
    }

    /// 粗粒度时间桶(中性英文,模型转界面语言;时间换算在代码做,模型不算时间 —— 见 AI 提示词规矩)。
    nonisolated static func coarseWhenText(_ date: Date, now: Date) -> String {
        switch now.timeIntervalSince(date) {
        case ..<120:     return "just now"
        case ..<3_600:   return "a few minutes ago"
        case ..<86_400:  return "earlier today"
        case ..<172_800: return "yesterday"
        case ..<604_800: return "a few days ago"
        default:         return "recently"
        }
    }

    // MARK: - 压缩包「你可能需要的文件」建议(backlog 第4项;MainActor:读清单缓存 + 模型 async)

    /// 对**预读过(清单已缓存)、还没评估**的归档,让端上模型从包内文件清单里挑**少数几个**用户最可能想单独取出 /
    /// 预览的 → 写回 `revealArchiveEntry` 动作(点击 = `.openArchive(revealEntry:)` 打开并定位,**不解压**)。门控:
    /// AI 建议开关 + 内容预读 + 归档清单缓存开 + 模型就绪;预算挂活跃度档;已评估的跳过(归档变了阶段一清回才重选)。
    func generateArchiveEntrySuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard !archiveEntryRunning, AppPreferences.aiSuggestionEnabled,
              store.contentPrereadEnabled, AppPreferences.archiveListingCacheEnabled,
              AIReportAssistant.isReady, let budget = store.budget else { return }
        let listingByPath = Dictionary(
            ArchiveListingCacheStore().loadAll().map { ($0.archivePath, $0) },
            uniquingKeysWith: { first, _ in first })
        guard !listingByPath.isEmpty else { return }
        // 选:归档 + 还没评估包内文件建议 + 有缓存清单且含文件条目。预算封顶,近期在前。
        var picks: [(rec: AIFileMemoryRecord, entry: ArchiveListingCacheEntry)] = []
        for rec in store.recentFileRecords(limit: 2_000) {
            guard rec.type == .archive, rec.contentSummary?.mode != "archive-entries", let path = rec.path else { continue }
            let canonical = ArchiveListingCacheStore.canonicalPath(for: URL(fileURLWithPath: path))
            guard let entry = listingByPath[canonical], entry.fileEntryCount > 0 else { continue }
            picks.append((rec, entry))
            if picks.count >= budget.maxModelSuggestionsPerRound { break }
        }
        guard !picks.isEmpty else { return }
        archiveEntryRunning = true
        archiveEntryTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.archiveEntryRunning = false }
            for (rec, entry) in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled, AIReportAssistant.isReady else { break }
                let paths = entry.filePaths(limit: 50)
                guard !paths.isEmpty else {
                    AIBackgroundIndexStore.shared.applyArchiveEntrySuggestion(recordID: rec.id, actions: [])
                    continue
                }
                // 模型挑序号(失败 → nil → 不标记、下轮重试;[] → 模型说没有 → 标记已评估)。
                guard let chosen = try? await AIVirtualFolderModelPlanner.archiveEntryPicks(
                    archiveName: rec.fileName, entryPaths: paths) else { continue }
                let actions = chosen.map { idx -> AIFileSuggestedAction in
                    let entryPath = paths[idx - 1]
                    return AIFileSuggestedAction(token: "revealArchiveEntry", payload: entryPath,
                                                 label: (entryPath as NSString).lastPathComponent)
                }
                AIBackgroundIndexStore.shared.applyArchiveEntrySuggestion(recordID: rec.id, actions: actions)
            }
        }
    }

    // MARK: - 压缩包「这是什么包」定性(MainActor:读清单缓存 + 模型 async)

    /// 对**预读过(清单已缓存)、还没定性**的归档,让端上模型据完整非加密条目名 + 目录结构写一句「这看起来是什么包」。
    /// 纯 AI:App 只提供清单事实,不规则兜底、不硬分类;模型失败则下轮重试,空摘要则只写 `archiveKind` marker 标记已评估。
    func generateArchiveKindGuessIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard !archiveKindRunning, AppPreferences.aiSuggestionEnabled,
              store.indexingEnabled, AppPreferences.archiveListingCacheEnabled,
              AIReportAssistant.isReady, canRunDeepContextNow(), let budget = store.budget else { return }
        let listingByPath = Dictionary(
            ArchiveListingCacheStore().loadAll().map { ($0.archivePath, $0) },
            uniquingKeysWith: { first, _ in first })
        guard !listingByPath.isEmpty else { return }

        var picks: [(rec: AIFileMemoryRecord, entry: ArchiveListingCacheEntry)] = []
        for rec in store.recentFileRecords(limit: 2_000) {
            guard rec.type == .archive, rec.contentSummary?.action(forToken: "archiveKind") == nil,
                  let path = rec.path else { continue }
            let canonical = ArchiveListingCacheStore.canonicalPath(for: URL(fileURLWithPath: path))
            guard let entry = listingByPath[canonical], !entry.entries.isEmpty else { continue }
            picks.append((rec, entry))
            if picks.count >= budget.maxModelSuggestionsPerRound { break }
        }
        guard !picks.isEmpty else { return }

        archiveKindRunning = true
        archiveKindTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.archiveKindRunning = false }
            for (rec, entry) in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { break }
                let entries = entry.entries.compactMap { cached -> (name: String, isDirectory: Bool)? in
                    let name = cached.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return name.isEmpty ? nil : (name, cached.isDirectory)
                }
                guard !entries.isEmpty else {
                    AIBackgroundIndexStore.shared.applyArchiveKindGuess(recordID: rec.id, summary: nil)
                    continue
                }
                guard let summary = try? await AIVirtualFolderModelPlanner.archiveKindGuess(
                    archiveName: rec.fileName, entryNames: entries) else { continue }
                AIBackgroundIndexStore.shared.applyArchiveKindGuess(recordID: rec.id, summary: summary)
            }
        }
    }

    /// 读一个文件头部 → 脱敏(给模型出一句话摘要的素材)。红线门控同 `summarizeContent`(敏感目录 / 临时解密 /
    /// 疑似密钥名一律不读);无读权限 / 空 / 非 UTF-8 → nil。**脱敏后**的文本才会进 prompt(白皮书隐私口径)。
    nonisolated static func redactedExcerpt(url: URL, fileName: String) -> String? {
        if AIFileReadabilityPolicy.blockReason(absolutePath: url.path, fileName: fileName,
                                               currentUserCanRead: true, isExcludedByUser: false) != nil {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxContentReadBytes)) ?? Data()
        guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else { return nil }
        let redacted = AISensitiveRedactor.redact(raw)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// **「查看更长总结」按需现算**(backlog B)。双击抽屉摘要行 → 弹窗实时生成:后台线程重读 + 脱敏头部 → 端上模型
    /// 出更长总结。红线照旧(敏感目录 / 疑似密钥不读)。调用点(sheet 的 produce 闭包)已在 AI 就绪门控内;读不到
    /// 内容也让模型从名字 / 角色尽力。复用预索引记录的结构信号(标题 / 语言)当上下文。
    @available(macOS 26.0, *)
    static func generateLongSummary(url: URL, fileName: String) async throws -> String {
        let excerptTask = Task.detached(priority: .userInitiated) {
            AIBackgroundIndexer.redactedExcerpt(url: url, fileName: fileName) ?? ""
        }
        let excerpt = await excerptTask.value
        let record = AIBackgroundIndexStore.shared.record(forPath: url.path)
        let roleTags = record?.roleTags ?? AIFileType.roleTags(fileName: fileName, isDirectory: false)
        return try await AIVirtualFolderModelPlanner.longFileSummary(
            fileName: fileName, roleTags: roleTags,
            languageHint: record?.contentSummary?.languageHint,
            headings: record?.contentSummary?.headings ?? [], excerpt: excerpt)
    }

    /// **推荐打开方式**:查一个文件的「**非默认**」候选打开 App(LaunchServices 元数据,**不读内容**)。默认双击就能
    /// 开 → 不进建议;只把非默认候选喂给模型挑(用户:非默认才进 suggestion,「不然脱裤子放屁」)。返回
    /// `(bundleID, 显示名)`,去掉默认 App、去重、封顶 8 个。文件不存在 / 无候选 → 空数组。off-main 安全。
    nonisolated static func nonDefaultOpenApps(forPath path: String) -> [(bundleID: String, name: String)] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let ws = NSWorkspace.shared
        let defaultBundleID = ws.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        var seen = Set<String>()
        var out: [(bundleID: String, name: String)] = []
        for appURL in ws.urlsForApplications(toOpen: url) {
            guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { continue }
            if let def = defaultBundleID, bundleID == def { continue }           // 去掉默认 App
            guard seen.insert(bundleID).inserted else { continue }
            let raw = FileManager.default.displayName(atPath: appURL.path)
            let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
            out.append((bundleID, name))
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - 只读元数据扫描(off-main;纯静态,不碰 UI 状态)

    /// 每 scope 最多访问的目录数(防超大递归目录把一轮拖垮 —— 白皮书禁「超出预算的大型递归目录」)。
    private nonisolated static let maxDirectoriesPerScope = 600

    /// 走一个白名单 scope,深度受限、层层排除、只取元数据、不跟符号链接。返回文件记录(疑似密钥文件整条不索引)。
    /// `allowContent` 开时**两阶段**:① BFS 出元数据;② **AI 排序挑前 N 个补内容摘要**(渐进覆盖,见 AIPrereadSelection)。
    /// `existingSummarized` = 上一轮已有摘要的记录(id → 记录),**指纹(大小+修改时间)没变就直接沿用旧摘要、不重读**
    /// → 预算只花在「新文件 / 变了的文件」上,高权重读完慢慢轮到低权重,时间够长全覆盖。
    nonisolated static func scanScope(_ scope: AIArchivePrefetchScope, home: String,
                                      fileBudget: Int, allowContent: Bool = false,
                                      existingSummarized: [String: AIFileMemoryRecord] = [:]) -> [AIFileMemoryRecord] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey, .volumeIsLocalKey]
        var records: [AIFileMemoryRecord] = []
        var visitedDirs = 0
        // 游标 BFS(避免 Array.removeFirst 的 O(n²));seed 标准化(消 `..`,防被篡改的持久 scope 逃逸)。
        var queue: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: scope.directoryPath).standardizedFileURL, 0)]
        var head = 0

        while head < queue.count, records.count < fileBudget, visitedDirs < maxDirectoriesPerScope {
            let (dir, depth) = queue[head]; head += 1
            // 目录级层层兜底(对 seed 和每个子目录一致):符号链接 / 敏感目录 / 系统排除 / 外置·网络卷。
            guard shouldWalkDirectory(dir, scope: scope, home: home) else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            visitedDirs += 1

            let loc = AILocationClassifier.classify(directoryPath: dir.path, home: home)
            var dirHasFile = false   // 这个目录是否「有内容」(直接含文件)→ 决定要不要把它本身记成 folder 候选
            var roleCounts: [String: Int] = [:]
            for entry in entries {
                if records.count >= fileBudget { break }
                // M5:取不到属性 = 类型未知 → 整条跳过(不再 fail-open 当普通文件 / 漏判符号链接)。
                guard let vals = try? entry.resourceValues(forKeys: keys) else { continue }
                if vals.isSymbolicLink == true { continue }   // 不跟符号链接(防逃逸 / 环)
                if !scope.includeExternalVolumes, entry.path.hasPrefix("/Volumes/") { continue }
                if vals.isDirectory == true {
                    // 子目录入队;敏感 / 排除 / 符号链接 / 卷 的判定在出队时由 shouldWalkDirectory 统一兜。
                    if scope.recursive, depth + 1 < scope.maxDepth { queue.append((entry, depth + 1)) }
                } else {
                    // C1:疑似密钥 / 凭据文件名(id_rsa / *.pem / .env / *.p12 / *.gpg …)→ 整条不索引。
                    if AIFileReadabilityPolicy.looksLikeSecret(fileName: entry.lastPathComponent) { continue }
                    dirHasFile = true
                    let roleTags = AIFileType.roleTags(fileName: entry.lastPathComponent, isDirectory: false)
                    guard AIFileRoleSamplingPolicy.reserve(roleTags, counts: &roleCounts) else { continue }
                    // 阶段一:只建**元数据**记录(不读内容)。内容摘要在 BFS 结束后由 AI 排序挑出前 N 个再补(见下)。
                    records.append(AIFileMemoryRecord.make(
                        fileName: entry.lastPathComponent, isDirectory: false,
                        byteSize: vals.fileSize.map(Int64.init), modifiedAt: vals.contentModificationDate,
                        location: loc,
                        path: entry.path))   // 存全路径(非加密路径不是风险,AI 有权知道)
                }
            }
            // **把任何有内容(直接含文件)的目录本身也记成 folder 候选** —— AI 文件夹可把一个文件夹整体收纳
            // (项目目录 / 数据目录…),不必把里面的文件拆散塞(用户:任何有内容的文件夹都该能整体收进来)。
            // depth>0:不收白名单 seed 根本身(那是授权的扫描范围,不是「一个文件夹」)。
            if dirHasFile, depth > 0, records.count < fileBudget {
                let parentLoc = AILocationClassifier.classify(
                    directoryPath: dir.deletingLastPathComponent().path, home: home)
                let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                records.append(AIFileMemoryRecord.make(
                    fileName: dir.lastPathComponent, isDirectory: true,
                    byteSize: nil, modifiedAt: dirMtime, location: parentLoc, path: dir.path))
            }
        }

        // 阶段二:**AI 驱动 + 渐进覆盖的预读**。`allowContent` 关(只元数据档)时整段跳过。
        guard allowContent else { return records }
        // 指纹(大小+修改时间)没变的已摘要文件 → 直接沿用旧摘要、不重读;其余(新/变了)才进候选。
        // 这样预算只花在没读过/变了的文件上 → 高权重吃完慢慢轮到低权重 → 最终全覆盖(用户:别让低权重没机会)。
        var carried: [String: AIFileContentSummary] = [:]
        var staleCandidates: [AIFileMemoryRecord] = []
        for rec in records {
            if let old = existingSummarized[rec.id], let summary = old.contentSummary,
               old.byteSize == rec.byteSize, old.modifiedAt == rec.modifiedAt {
                carried[rec.id] = summary          // 没变 → 沿用,省一次读
            } else {
                staleCandidates.append(rec)         // 新 / 变了 → 候选(AIPrereadSelection 内部再筛文本可读类)
            }
        }
        let selected = AIPrereadSelection.selectForSummary(
            records: staleCandidates, budget: maxContentSummariesPerScope, now: Date())
        var fresh: [String: AIFileContentSummary] = [:]
        for rec in selected {
            guard let path = rec.path else { continue }
            if let summary = summarizeContent(url: URL(fileURLWithPath: path),
                                              fileName: (path as NSString).lastPathComponent) {
                fresh[rec.id] = summary
            }
        }
        guard !carried.isEmpty || !fresh.isEmpty else { return records }
        return records.map { rec in
            if let summary = fresh[rec.id] { return rec.withContentSummary(summary) }       // 新算的
            if let summary = carried[rec.id] { return rec.withContentSummary(summary) }      // 沿用旧的
            return rec
        }
    }

    /// 一个目录是否允许被列举(seed 和每个子目录都过这关)。任一命中即拒:
    /// 符号链接(防逃逸白名单)/ 网络卷(scope 未显式允许)/ 系统排除目录 / 敏感目录(含非隐藏的 keys/secrets/
    /// credentials/password-store …)/ 外置卷(scope 未显式允许)。
    private nonisolated static func shouldWalkDirectory(_ dir: URL, scope: AIArchivePrefetchScope,
                                                        home: String) -> Bool {
        if let vals = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsLocalKey]) {
            if vals.isSymbolicLink == true { return false }                       // H3/H5:不跟符号链接(含 seed)
            if !scope.includeNetworkVolumes, vals.volumeIsLocal == false { return false }  // H4:网络卷默认不进
        }
        if AIPrefetchExclusions.shouldExclude(directoryPath: dir.path, home: home) { return false }
        if AIFileReadabilityPolicy.isSensitiveDirectory(dir.path) { return false } // H2/H3:敏感目录(含非隐藏)
        // H2 纵深:明显的凭据目录名(非 dot 变体)也不进 —— `isSensitiveDirectory` 只盖 .password-store 等带点的。
        if credentialDirNames.contains(dir.lastPathComponent.lowercased()) { return false }
        if !scope.includeExternalVolumes, dir.path.hasPrefix("/Volumes/") { return false }
        return true
    }

    /// 明显的凭据目录名(纵深防御;不含太常见 / 歧义的 `keys`)。
    private nonisolated static let credentialDirNames: Set<String> = [
        "secrets", "credentials", "password-store", "passwords", "vault", ".vault"
    ]

    // MARK: - 文档内容预读(off-main;确定性结构抽取,绝不进 prompt 前不脱敏)

    /// 每 scope 最多深读多少篇文档(预算:内容读盘比列元数据贵,只读少量「定主题」文档)。
    private nonisolated static let maxContentSummariesPerScope = 60
    /// 单篇文档读取的头部上限(64KB:头部足够拿到标题 / 顶层字段定主题,避免对大文件全量读)。
    private nonisolated static let maxContentReadBytes = 64 * 1024

    /// 读一个文件头部 → 脱敏 → 内容摘要(标题 / 字段名 / 语言提示,已脱敏)。**挑哪些读、读多少由调用方
    /// (AIPrereadSelection + 预算)决定**,这里不再自带「只 md 才读」死规则。红线门控仍在:敏感目录 / 临时解密 /
    /// 疑似密钥名(`blockReason`)一律不读;无读权限静默跳过。端上模型短摘要(shortSummary)由 ②b 接(此刻仍 nil)。
    private nonisolated static func summarizeContent(url: URL, fileName: String) -> AIFileContentSummary? {
        if AIFileReadabilityPolicy.blockReason(absolutePath: url.path, fileName: fileName,
                                               currentUserCanRead: true, isExcludedByUser: false) != nil {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }   // 无读权限 → 跳过
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxContentReadBytes)) ?? Data()
        let type = AIFileType.classify(fileName: fileName, isDirectory: false)
        guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else {
            return AIFileContentSummary(mode: "metadata-only")   // 空 / 二进制 / 非 UTF-8 → 只记元数据
        }
        // **脱敏后再抽信号 + 入索引**(白皮书:深度文本摘要由 App 侧先过 AISensitiveRedactor 再塞 contentSummary)。
        let redacted = AISensitiveRedactor.redact(raw)
        let redactionCount = redacted.components(separatedBy: AISensitiveRedactor.placeholder).count - 1
        return AIFileContentSummary(
            mode: "text-summary",
            languageHint: languageHint(type: type, fileName: fileName),
            headings: extractHeadings(redacted, type: type),
            fieldNames: extractFieldNames(redacted, type: type),
            shortSummary: nil,   // 短摘要(端上模型润色)留后续;结构信号已足够喂聚类
            redactionCount: redactionCount)
    }

    /// markdown / 文本标题:`#`…`######` 行的标题文字(去 #、trim、去重),封顶 8 条、每条 ≤ 60 字符。
    private nonisolated static func extractHeadings(_ text: String, type: AIFileType) -> [String] {
        guard type == .markdown || type == .text else { return [] }
        var out: [String] = []; var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let capped = String(title.prefix(60))
            if seen.insert(capped.lowercased()).inserted { out.append(capped) }
            if out.count >= 8 { break }
        }
        return out
    }

    /// 配置 / json / yaml / toml 顶层字段名:行首 `key:` / `key =` 的 key(去重),封顶 12 条。值不取(可能含敏感)。
    private nonisolated static func extractFieldNames(_ text: String, type: AIFileType) -> [String] {
        guard type == .config || type == .checksum else { return [] }
        var out: [String] = []; var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            // key 分隔符取首个 `:` 或 `=`(json 的 `"key":` 也覆盖到,引号在下面剥掉)。
            guard let sepIdx = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            var key = String(line[line.startIndex..<sepIdx]).trimmingCharacters(in: .whitespaces)
            key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"',-"))
            guard key.count >= 2, key.count <= 40,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { continue }
            if seen.insert(key.lowercased()).inserted { out.append(key) }
            if out.count >= 12 { break }
        }
        return out
    }

    /// 语言 / 格式提示(稳定 token):markdown → "markdown";配置 → 扩展名(yaml/json/toml…);否则 nil。
    private nonisolated static func languageHint(type: AIFileType, fileName: String) -> String? {
        switch type {
        case .markdown: return "markdown"
        case .config:
            let ext = (fileName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "config" : ext
        case .checksum: return "checksum"
        default: return nil
        }
    }
}
