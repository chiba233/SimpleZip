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

    /// 阶段0b:运行时门控(启动时刻 / 交互空闲追踪 / 电源 / 上下文组装)抽到文件末的 `AIIndexerGate`。这里只留
    /// gate 实例 + 给 gateDiag 用的转发属性;各 pass 仍调下面的 `canRunModelWorkNow()` / `canRunDeepContextNow()` 转发方法。
    private let gate = AIIndexerGate()
    /// 转发:DevTools 豁免旗(gateDiag 读)。
    var devToolsInteractionExempt: Bool { gate.devToolsInteractionExempt }

    private init() {}

    /// DevTools 调试开关:**开** → 完全豁免交互门控 + **立即视为空闲**(拨表到 1 小时前让模型档立刻满足)+ 立刻评一轮
    /// (挂着 DevTools 观察后台 AI 真的在跑);**关** → 恢复正常交互计时(验证交互检测器是否真会把 AI 停下来)。
    /// 由 DevTools 里的开关控制,关闭 DevTools 也强制复位为关(豁免不外泄)。
    func setDevToolsExemption(_ on: Bool) {
        gate.setExemption(on)        // 状态部分(豁免旗 + 交互计时)在 gate
        if on { runIfEnabled() }     // 「开了立刻评一轮」是编排,留 indexer
    }

    /// 转发到 gate(运行时上下文 / 能跑哪档门控)。各 pass 入口 + gateDiag 共用 —— 调用点不动。
    func currentRuntimeContext() -> AIBackgroundRuntimeContext { gate.currentRuntimeContext() }

    /// 接通 `AIBackgroundPlanner`(工程补充五):用当前 runtime + 已收集的 interaction 信号(AIFeedbackStore)+ 索引健康,
    /// 确定性地规划「后台空闲时该补什么数据 / 预热哪个 surface」的一组 tier-gated job(绝不越当前档位天花板)。
    /// **v1 只产 plan 供观测(DevTools)**;逐 job kind 接执行、以及 interest-event / evidence-gap / 陈旧工作区等
    /// 输入待对应数据收集接齐后填,是后续步骤(见记忆 ⓪/①)。纯确定性、可取消、可解释。
    func planBackgroundJobs() -> AIBackgroundPlan {
        let input = AIBackgroundPlanningInput(
            runtime: currentRuntimeContext(),
            interactionSummary: AIFeedbackStore.shared.interactionCounterSummary,
            recentInterestSummary: AIFeedbackStore.shared.interestSummary,
            workspaceEvidenceGaps: AIWorkspaceStore.shared.currentEvidenceGaps,
            indexHealth: AIIndexMaintenanceFacts())
        return AIBackgroundPlanner.plan(input)
    }
    func canRunModelWorkNow() -> Bool { gate.canRunModelWorkNow() }
    func canRunDeepContextNow() -> Bool { gate.canRunDeepContextNow() }

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
    private var urlSuggestionRunning = false
    private var urlSuggestionTask: Task<Void, Never>?
    private var archiveEntryRunning = false
    private var archiveEntryTask: Task<Void, Never>?
    private var archiveKindRunning = false
    private var archiveKindTask: Task<Void, Never>?
    private var pendingExecRunning = false
    private var pendingExecTask: Task<Void, Never>?
    private var lastPendingExecAt: Date?
    private var folderGroupRunning = false
    private var folderGroupTask: Task<Void, Never>?
    private var organizeRunning = false
    private var organizeTask: Task<Void, Never>?
    private var workbenchRankingRunning = false
    private var workbenchRankingTask: Task<Void, Never>?
    private var workbenchNeedsAttentionRunning = false
    private var workbenchNeedsAttentionTask: Task<Void, Never>?
    private var workbenchFailureRunning = false
    private var workbenchFailureTask: Task<Void, Never>?
    private var workbenchClusterRunning = false
    private var workbenchClusterTask: Task<Void, Never>?
    private var toolbarRankingRunning = false
    private var toolbarRankingTask: Task<Void, Never>?

    /// 后台索引**心跳定时器**(主运行循环)+ 当前间隔。P0 根因:`runIfEnabled` 原本只在启动 `activate()` 时被调
    /// 一次,那次又卡在 launch-silence(<60s)直接空跑,之后再无任何定时器触发 → 后台索引 / 建议全程跑不起来
    /// (全仓唯一 Timer 是 DevTools 刷新)。心跳定期重评门控,让所有 pass 真正轮得到。
    private var heartbeat: Timer?
    private var currentHeartbeatInterval: TimeInterval?
    /// DevTools 用:心跳是否在跑(配合 `lastFullRunAt` 判断后台到底有没有自驱)。
    var isHeartbeatRunning: Bool { heartbeat != nil }

    // MARK: - DevTools 诊断(每个 pass 真跑没跑 / 有没有候选 / 产出多少 + 当前各档闸状态)

    /// 阶段0b:每个 pass 的执行画像从 god-object 抽到文件末的 `AIIndexerPassDiagnostics`(诊断协作类)。
    /// 这里只留**转发**:DevTools + 内部读 `passDiag`,写走 `recordPass` / `recordRunningPass`(都转发到协作类)。
    private let passDiagnostics = AIIndexerPassDiagnostics()
    var passDiag: [String: PassDiag] { passDiagnostics.byPass }
    /// 上一轮**完整索引轮**结束时间(判断后台到底有没有在跑)。
    private(set) var lastFullRunAt: Date?
    var isIndexerRunning: Bool { running }

    /// 记一条 pass 画像(pass 在候选选定 / 收尾时调)。转发到诊断协作类。
    func recordPass(_ name: String, candidates: Int = 0, produced: Int = 0, skip: String? = nil) {
        passDiagnostics.record(name, candidates: candidates, produced: produced, skip: skip)
    }

    private func recordRunningPass(_ name: String) {
        passDiagnostics.recordRunning(name)
    }

    /// 归档/文件夹清单类**重型** pass(包内 / 包定性 / 文件组)每轮**只处理 1 个候选**。实测端上模型单次结构化生成
    /// 方差极大(2~34s,NPU 非确定性),且这些 pass 的 prompt 最长(整份清单)→ 单次最慢。若按 `maxModelSuggestionsPerRound`
    /// (激进 6)批量处理,一次调用就把单串行闸(`AIGenerationSerializer`)占满数分钟,跨心跳注入 > 消化、队列永不收敛,
    /// DevTools 永远「仍在运行」(实测 `/tmp/inference_test_results.md`)。改 1 个/轮:配合 `maxAttempts:3`,单次 ≈ 39s
    /// (< 60s 激进心跳)→ 每轮腾出闸门、轮转推进、队列收敛。覆盖面靠多轮 + 指纹跳过逐步补齐(慢但全)。
    private static let deepContextSuggestionsPerRound = 1

    /// DevTools 用:当前各档闸的实时状态 + 输入 —— 直接回答「为啥都是 0」(哪一档被卡)。
    nonisolated struct GateDiag: Sendable {
        let appIsActive: Bool
        let secondsSinceLaunch: Int
        let secondsSinceLastInteraction: Int
        let isCharging: Bool?
        let lowBattery: Bool
        let powerSaverMode: Bool
        let activityLevel: String
        let modelAvailable: Bool
        let canDeterministic: Bool
        let canModelWork: Bool
        let canDeepContext: Bool
        let devToolsExempt: Bool
    }
    func gateDiag() -> GateDiag {
        let c = currentRuntimeContext()
        return GateDiag(
            appIsActive: c.appIsActive,
            secondsSinceLaunch: c.secondsSinceLaunch,
            secondsSinceLastInteraction: c.secondsSinceLastInteraction,
            isCharging: c.isCharging,
            lowBattery: c.lowBattery,
            powerSaverMode: c.powerSaverMode,
            activityLevel: c.activityLevel.rawValue,
            modelAvailable: c.modelAvailable,
            canDeterministic: AIBackgroundSchedulingRules.canRunDeterministicIndexing(c),
            canModelWork: AIBackgroundSchedulingRules.canRunModelWork(c),
            canDeepContext: AIBackgroundSchedulingRules.canRunDeepContext(c),
            devToolsExempt: devToolsInteractionExempt)
    }

    /// App **是否曾真正进入前台活跃**(plain var,绝不 @Published —— A17:reload/启动路径禁发布)。
    /// 由 `AppDelegate.applicationDidBecomeActive` 置位(只赋值,不起任何活、不碰布局)。
    /// 用途:App Intents 把本 app 当 helper 在**后台**拉起跑 intent 时,SwiftUI 照样实例化 ContentView、
    /// onAppear 照跑 `runIfEnabled` —— 但 helper **从不 becomeActive**,故此处恒为 false,实际扫描永不启动,
    /// 不会用 `nonDefaultOpenApps` 的 LaunchServices 风暴占住 helper 进程(那会让它没能在 App Intents 的 XPC
    /// 超时窗口内响应 → Shortcuts 报「Couldn't communicate with a helper application」)。
    private var hasEnteredForeground = false

    /// 标记 app 已首次进入前台活跃。**只置一个普通 bool**,不触发 SwiftUI 更新 / 不碰窗口布局 ——
    /// 可安全在 `applicationDidBecomeActive`(可能正处窗口布局周期)调用。心跳已在 onAppear 装好,
    /// 置位后的下一跳即自然跑起扫描,无需在此主动触发任何后台工作。
    func markForegroundEntered() { hasEnteredForeground = true }

    /// 跑一轮预索引(门控未过则直接返回 —— 默认 opt-in 关闭即什么都不做)。完成后通知发现编排者刷新。
    func runIfEnabled() {
        let store = AIBackgroundIndexStore.shared
        guard store.indexingEnabled, let budget = store.budget else { return }
        // P0 修复:确保心跳在跑。`runIfEnabled` 原本只被启动 activate() 调一次、又卡在 launch-silence 空跑,之后再无
        // 触发。心跳按活跃度档周期重评门控,门控未过则下面廉价返回,过了就跑一轮预算化渐进覆盖(多轮把全部覆盖到)。
        ensureHeartbeat()
        // App Intents helper(后台拉起跑 intent)从不 becomeActive → hasEnteredForeground 恒 false:心跳照装但
        // 实际扫描永不启动,helper 进程不会被 nonDefaultOpenApps 的 LaunchServices 风暴占住(修 Shortcuts
        // 「Couldn't communicate with a helper application」)。正常用户启动必经 becomeActive,置位后的下一跳
        // 心跳自然跑起扫描。注意:启动旗标只在 becomeActive 里纯赋值,不在那里起任何活(避免诱发 SwiftUI
        // ScrollView 在窗口布局周期内重入崩溃)。
        //
        // 🔴 helper 死因(2026-06-23 实测采样+日志钉死):App Intents 后台 helper 会因**窗口状态恢复**
        //(日志 `restoreWindowWithIdentifier SimpleZip.Main`)触发 becomeActive → `hasEnteredForeground` 被误置 true
        // → 启动 AI 后台索引 → `nonDefaultOpenApps` 的**同步 LaunchServices** 占满 Swift cooperative 线程池 →
        // **饿死 App Intents 的异步 XPC 回复 → NSCocoaError 4101「Couldn't communicate with a helper application」**。
        // 「helper 永不 becomeActive」的旧假设是错的;但 helper 恢复出的窗口**不可见**(`running-NotVisible`)。
        // 故判据改为「**真有可见主窗口**」:真实用户会话必有,helper 没有 → AI 后台索引永不在 helper 里启动。
        guard hasEnteredForeground,
              NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        // AI 电源规范③:启动静默 60s + 无重归档任务 + 活跃度非关。低电 / 省电也可(只读索引不耗模型)。
        guard !running,
              AIBackgroundSchedulingRules.canRunDeterministicIndexing(currentRuntimeContext()) else { return }
        running = true

        // 渐进覆盖(用户:权重高的先跑、跑过的延后、最终全覆盖):按「最久没扫」取前 N —— 从没扫过的
        // (lastScannedAt==nil)最优先,其余按上次扫描时间升序。这样即便每轮预算只够 N 个 scope(省电=1),多轮
        // 心跳也能把所有白名单目录轮一遍,而不是永远只扫前 N 个。扫完即 markScanned → 下轮自然排到队尾。
        let scopeBudget = max(1, budget.maxDirectoriesPerRound)
        let allScopes = store.scopes   // 全量快照后跨 actor;最久没扫排序 + 取预算内由 Core 编排做
        let home = NSHomeDirectory()
        let fileBudget = min(budget.maxEntriesPerArchive, 3_000)
        // 内容预读是**更高隐私等级的独立开关**:只元数据预索引时 allowContent=false(绝不读内容);开了「预读内容」
        // 才对「定主题」文档读头部产脱敏摘要(归档内容预读是另一条路,见 archivePrefetchEnabled)。
        let allowContent = store.contentPrereadEnabled
        // 渐进覆盖:把上一轮已有摘要的记录带进去,指纹没变的直接沿用、不重读 → 预算轮到没读过/变了的文件。
        let existingSummarized = allowContent ? store.summarizedRecordsByID() : [:]

        task = Task.detached(priority: .background) {
            // 单一扫描编排(A2):App 前台与 agent 后台共用 `AIBackgroundIndexRun.scan`。前台停止钩子 = `Task.isCancelled`
            // (agent 后台会把单次 timeout 折进同一个 isCancelled);渐进覆盖 / 最久没扫排序 / 续扫都是 Core 编排里的现成机制。
            let scanned = AIBackgroundIndexRun.scan(
                scopes: allScopes, home: home, scopeBudget: scopeBudget, fileBudget: fileBudget,
                allowContent: allowContent, existingSummarized: existingSummarized,
                isCancelled: { Task.isCancelled }
            ).map { ($0.scopeID, $0.records) }
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
                        AIBackgroundIndexer.shared.generateURLOpenSuggestionsIfEnabled()   // 文本里真实 URL →「打开网页」
                        AIBackgroundIndexer.shared.generateDiskImageSuggestionsIfEnabled()   // 内含 App 的 dmg「安装到应用程序」
                        AIBackgroundIndexer.shared.generateActivityLinkSuggestionsIfEnabled()   // 命中近期任务产物「查看活动」
                        AIBackgroundIndexer.shared.generateWorkbenchChipRankingIfEnabled()   // 活动中心「建议筛选」chip 模型排序
                        AIBackgroundIndexer.shared.generateWorkbenchClusterChipsIfEnabled()   // 活动中心「真建议」chip(发现真实聚集→模型命名)
                        AIBackgroundIndexer.shared.generateWorkbenchNeedsAttentionIfEnabled()   // 活动中心「需要处理」卡 AI 解读
                        AIBackgroundIndexer.shared.generateWorkbenchFailureExplanationsIfEnabled()   // 活动中心失败任务「失败解释」
                        AIBackgroundIndexer.shared.generateArchiveEntrySuggestionsIfEnabled()   // 归档「也许你要包里的 X」
                        AIBackgroundIndexer.shared.generateToolbarRankingIfEnabled()   // 工具栏动作 AI 排序(建议七 Phase2)
                        if AIBackgroundIndexer.shared.canRunDeepContextNow() {
                            AIBackgroundIndexer.shared.generateArchiveKindGuessIfEnabled()   // 归档「这看起来是什么包」
                            AIBackgroundIndexer.shared.generateFolderGroupSuggestionsIfEnabled()   // 文件夹「这些可成组处理」
                            AIBackgroundIndexer.shared.generateOrganizeSuggestionsIfEnabled()   // 文件夹「把这些整理进新文件夹」
                        }
                        // 阶段 B(电池决策):把模型已挑的只读检查 token 收进 pending 队列,真执行等插电(阶段 C)。
                        AIBackgroundIndexer.shared.generatePendingChecksIfEnabled()
                    }
                    // 阶段 B′(调度计划):把 planner 产的确定性 evidence job(工作区成员缺哈希)收进 pending 队列。
                    AIBackgroundIndexer.shared.executePlannedJobsIfDue()
                    // 阶段 C(插电执行):充电时按间隔逐个执行 pending 只读检查(自门控,电池 / 间隔未到则空跑)。
                    AIBackgroundIndexer.shared.executePendingChecksIfDue()
                }
                AIBackgroundIndexer.shared.lastFullRunAt = Date()
                AIBackgroundIndexer.shared.running = false
            }
        }
    }

    /// 确保后台索引心跳在跑(主运行循环重复定时器)。幂等:已在跑且间隔匹配则不重建。活跃度=off → 停表。
    /// 心跳本身不做判定,只「定期再问一次」`runIfEnabled` —— 真正的节流闸是里面的门控(空闲 / 充电 / 低电 / 静默)。
    private func ensureHeartbeat() {
        let level = AppPreferences.aiBackgroundActivityLevel
        // AI 主开关关 或 活跃度 off → 不装表(主开关关时心跳每跳也只是 runIfEnabled 空跑,白唤醒)。
        guard AppPreferences.aiAssistantEnabled, level != .off,
              let interval = AIBackgroundSchedulingRules.heartbeatInterval(for: level) else {
            heartbeat?.invalidate(); heartbeat = nil; currentHeartbeatInterval = nil; return
        }
        if heartbeat != nil, currentHeartbeatInterval == interval { return }   // 已在跑且间隔一致 → 不动
        heartbeat?.invalidate()
        currentHeartbeatInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in AIBackgroundIndexer.shared.heartbeatTick() }
        }
        timer.tolerance = interval * 0.3   // 允许系统合并唤醒省电(后台索引不需要精确节拍)
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// 心跳一跳:主开关 / 活跃度运行期可能被改 → 关掉即 **cancel()**(停表 + 取消所有在跑的派生任务,
    /// 否则已过门控、正在推理的子任务会把过期建议写完);否则重评门控跑一轮(廉价,门控未过即返回)。
    private func heartbeatTick() {
        guard AppPreferences.aiAssistantEnabled, AppPreferences.aiBackgroundActivityLevel != .off else {
            cancel(); return
        }
        runIfEnabled()
    }

    // leastRecentlyScanned 已下沉 Core → AIArchivePrefetchScope.leastRecentlyScanned。

    func cancel() {
        heartbeat?.invalidate(); heartbeat = nil; currentHeartbeatInterval = nil
        task?.cancel(); task = nil; running = false
        archiveTask?.cancel(); archiveTask = nil; archiveRunning = false
        suggestionTask?.cancel(); suggestionTask = nil; suggestionRunning = false
        diskImageTask?.cancel(); diskImageTask = nil; diskImageRunning = false
        activityTask?.cancel(); activityTask = nil; activityRunning = false
        urlSuggestionTask?.cancel(); urlSuggestionTask = nil; urlSuggestionRunning = false
        archiveEntryTask?.cancel(); archiveEntryTask = nil; archiveEntryRunning = false
        archiveKindTask?.cancel(); archiveKindTask = nil; archiveKindRunning = false
        pendingExecTask?.cancel(); pendingExecTask = nil; pendingExecRunning = false
        folderGroupTask?.cancel(); folderGroupTask = nil; folderGroupRunning = false
        organizeTask?.cancel(); organizeTask = nil; organizeRunning = false
        toolbarRankingTask?.cancel(); toolbarRankingTask = nil; toolbarRankingRunning = false
        // 活动中心四个工作台预烘焙 pass —— 关 AI / 活跃度时同样必须取消(早先 cancel() 漏了它们 → 关掉后
        // 仍会把过期的 chip 排序 / 解读 / 失败解释 / 真建议写完)。
        workbenchRankingTask?.cancel(); workbenchRankingTask = nil; workbenchRankingRunning = false
        workbenchNeedsAttentionTask?.cancel(); workbenchNeedsAttentionTask = nil; workbenchNeedsAttentionRunning = false
        workbenchFailureTask?.cancel(); workbenchFailureTask = nil; workbenchFailureRunning = false
        workbenchClusterTask?.cancel(); workbenchClusterTask = nil; workbenchClusterRunning = false
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
        // Task.detached 真正跑在后台线程：ArchiveService.list() 含 7zz 子进程启动 + parseSevenZipList 解析，
        // 在 Task { @MainActor in } 里跑会占主线程 >1s（SimpleZip12 取样实证）。
        // nonisolated async 不自动 hop 出主线程，必须用 Task.detached。
        archiveTask = Task.detached(priority: .background) {
            for url in pick {
                if Task.isCancelled { break }
                let enabled = await MainActor.run { AIBackgroundIndexStore.shared.contentPrereadEnabled }
                guard enabled else { break }                                                // 期间被关
                // 空口令只读列举:加密头 / 损坏 → 抛错跳过(绝不弹密码、绝不解压)。
                guard let items = try? await ArchiveService.list(url) else { continue }
                if ArchiveListingCacheStore().record(archiveURL: url, items: items) {
                    CachedArchiveSpotlightIndexer.indexArchive(at: url)   // 归档级 + 逐条进 Spotlight(双门控在 indexer 里)
                    ArchiveFileSpotlightIndexer.indexArchive(at: url)
                }
            }
            // (AI 文件夹自动发现已下线 → 预读完不再回调 discovery.refresh();归档清单缓存照常给 AI suggestion / Spotlight 用。)
            await MainActor.run { AIBackgroundIndexer.shared.archiveRunning = false }
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
        guard AppPreferences.aiSuggestionEnabled, store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        guard !suggestionRunning else { recordRunningPass("摘要"); return }
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
        recordPass("摘要", candidates: candidates.count, skip: candidates.isEmpty ? "无候选(近阈值文件 0)" : nil)
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
                    (excerpt: AIIndexerScan.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: fileName),
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
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.applyModelSuggestion(
                    recordID: rec.id, summary: result.summary, actions: result.actions)
            }
        }
    }

    // MARK: - 工具栏动作排序(建议七 Phase2;前台 XPC 路径,gated canRunModelWorkNow —— 与后台 agent 同写一份缓存)

    /// 前台烘焙工具栏 AI 序:文件级(AI 建议 list 重要文件)+ 类型级(按后缀代表文件),经 XPC 引擎跑,写共享缓存。
    /// **电源门控**:与其它前台模型 pass 同走 `canRunModelWorkNow`(本地活跃度 + 索引电源 + 低电/省电/空闲);
    /// 后台 agent 另有自己的(只看系统低电/省电)。逐轮覆盖、每轮封顶(`maxModelSuggestionsPerRound`)。
    func generateToolbarRankingIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, AIReportAssistant.isReady, let budget = store.budget else { return }
        guard !toolbarRankingRunning else { recordRunningPass("工具栏序"); return }
        var filePicks: [AIFileMemoryRecord] = []
        var typeReps: [String: AIFileMemoryRecord] = [:]
        for rec in store.recentFileRecords(limit: 2_000) {
            guard rec.type != .folder, let path = rec.path else { continue }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if rec.contentSummary?.shortSummary?.isEmpty == false, !store.hasToolbarRanking(forPath: path, pathExtension: nil) {
                filePicks.append(rec)
            }
            if !ext.isEmpty, typeReps[ext] == nil, !store.hasToolbarRanking(forPath: nil, pathExtension: ext) {
                typeReps[ext] = rec
            }
        }
        let cap = budget.maxModelSuggestionsPerRound
        let files = Array(filePicks.prefix(cap))
        let types = Array(typeReps.values.prefix(max(0, cap - files.count)))
        recordPass("工具栏序", candidates: files.count + types.count,
                   skip: (files.isEmpty && types.isEmpty) ? "无候选(都已烘 / 无重要文件)" : nil)
        guard !files.isEmpty || !types.isEmpty else { return }
        toolbarRankingRunning = true
        toolbarRankingTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.toolbarRankingRunning = false }
            for rec in files {
                if Task.isCancelled || !AIBackgroundIndexer.shared.canRunModelWorkNow() { break }
                guard AIReportAssistant.isReady, let path = rec.path else { break }
                await Self.bakeOneToolbarRanking(rec: rec, filePath: path, ext: nil,
                                                 fileName: rec.fileName, summary: rec.contentSummary?.shortSummary)
            }
            for rec in types {
                if Task.isCancelled || !AIBackgroundIndexer.shared.canRunModelWorkNow() { break }
                guard AIReportAssistant.isReady, let path = rec.path else { break }
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                guard !ext.isEmpty else { continue }
                await Self.bakeOneToolbarRanking(rec: rec, filePath: nil, ext: ext,
                                                 fileName: "example.\(ext)", summary: nil)
            }
        }
    }

    /// 烘一个文件 / 类型的工具栏序:候选 = FileActionCatalog(右键菜单白名单)→ 引擎排序 → 写缓存。
    @available(macOS 26.0, *)
    private static func bakeOneToolbarRanking(rec: AIFileMemoryRecord, filePath: String?, ext: String?,
                                             fileName: String, summary: String?) async {
        let ids = FileActionCatalog.defaultActions(for: singleFileSnapshot(rec)).map { $0.id.rawValue }
        guard ids.count >= 2 else {
            AIBackgroundIndexStore.shared.setToolbarRanking(filePath: filePath, pathExtension: ext, orderedIDs: ids); return
        }
        guard let out = try? await AIAgentClient.generatePass(
            kind: .toolbarActionRanking,
            input: ToolbarActionRankingInput(fileName: fileName, kind: rec.type == .archive ? "archive" : "file",
                                             roleTags: rec.roleTags, summary: summary, actions: ids),
            as: AIPassIntListOutput.self) else { return }
        guard !Task.isCancelled else { return }   // 模型生成期间关了 AI → 不写过期序(P2-8)
        let ordered = out.numbers.compactMap { ids.indices.contains($0 - 1) ? ids[$0 - 1] : nil }
        AIBackgroundIndexStore.shared.setToolbarRanking(filePath: filePath, pathExtension: ext, orderedIDs: ordered)
    }

    /// 单文件工具栏上下文快照(从索引记录构造;前台 / 与 agent 同款,这里有 SignedContainerService)。
    private static func singleFileSnapshot(_ rec: AIFileMemoryRecord) -> ContextualToolbarSnapshot {
        let url = URL(fileURLWithPath: rec.path ?? rec.fileName)
        let isDir = rec.type == .folder
        let isArchive = !isDir && ArchiveService.isSupportedArchive(url)
        let sf = ContextualToolbarSnapshot.SelectedFile(
            name: rec.fileName, pathExtension: url.pathExtension.lowercased(), isDirectory: isDir,
            isSupportedArchive: isArchive,
            isToolableArchive: !isDir && SignedContainerService.isToolableArchive(url),
            isPackage: false,
            isFirstVolume: !isDir && FileSplitCombine.isFirstVolume(url),
            isChecksumFile: !isDir && ChecksumFile.isChecksumFileName(rec.fileName))
        return ContextualToolbarSnapshot(mode: .folder, selectedFiles: [sf],
                                         gpgUIAvailable: false, canConvertSelectedArchives: isArchive)
    }

    // MARK: - 文本内真实 URL「打开网页」建议(MainActor:只读重读脱敏头部 + 模型按编号筛)

    /// 对**已预读过的文本记录**,App 只读重读脱敏头部并正则抽真实 http(s) URL,再让端上模型只从这些 URL 编号里
    /// 选一个值得展示的网页。模型不能发明 / 改写 URL;没选中就不写建议(空抽屉)。点击走系统默认浏览器。
    func generateURLOpenSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        guard !urlSuggestionRunning else { recordRunningPass("网页"); return }
        let candidates = AIPrereadSelection.selectForURLSuggestion(
            records: store.recentFileRecords(limit: 2_000),
            budget: budget.maxModelSuggestionsPerRound, now: Date())
        recordPass("网页", candidates: candidates.count, skip: candidates.isEmpty ? "无候选(含真实 URL 的文本 0)" : nil)
        guard !candidates.isEmpty else { return }
        urlSuggestionRunning = true
        urlSuggestionTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.urlSuggestionRunning = false }
            for rec in candidates {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.contentPrereadEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
                let fileName = (path as NSString).lastPathComponent
                let excerptTask = Task.detached(priority: .background) {
                    AIIndexerScan.redactedExcerpt(url: URL(fileURLWithPath: path), fileName: fileName)
                }
                guard let excerpt = await excerptTask.value else { continue }
                let urls = AIURLCandidateExtractor.extract(from: excerpt, limit: 12)
                guard !urls.isEmpty else { continue }
                // 确定性高价值域名白名单 fast-path:命中(github/pypi/npm/Apple 文档…)直接写,跳过模型 —— 命中率高得多。
                if let fastURL = urls.first(where: AIURLCandidateExtractor.isHighValueURL) {
                    if Task.isCancelled { break }   // 读取期间关了 AI → 不写过期建议(P2-8)
                    AIBackgroundIndexStore.shared.applyURLOpenSuggestion(
                        recordID: rec.id, url: fastURL, label: AIURLCandidateExtractor.webPageLabel(for: fastURL))
                    continue
                }
                // 阶段3:经前台 XPC Service 在引擎进程跑(模型只选编号、不发明 URL)。
                guard let urlOut = try? await AIAgentClient.generatePass(
                    kind: .urlOpenSuggestion,
                    input: URLOpenSuggestionInput(fileName: rec.fileName, roleTags: rec.roleTags, urls: urls),
                    as: AIPassIntOutput.self),
                    urls.indices.contains(urlOut.number) else { continue }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                let url = urls[urlOut.number]
                AIBackgroundIndexStore.shared.applyURLOpenSuggestion(
                    recordID: rec.id, url: url, label: AIURLCandidateExtractor.webPageLabel(for: url))
            }
        }
    }

    // 高价值域名判定 isHighValueURL / webPageLabel / highValueURLHosts 已下沉到 Core 的
    // AIURLCandidateExtractor(URL 处理内聚一处,agent 复用 Core 时零拷贝可用)。


    // MARK: - 磁盘镜像安装建议(推荐打开方式 backlog 第2项;MainActor:7zz peek + 模型 async)

    /// 对**还没评估、内含 App 的 .dmg**,后台出「安装到应用程序」建议:① 7zz **只读 peek**(纯文件读、不挂载,实测
    /// ~17ms)列出 dmg 内的 `.app` 包;② 有 App → 端上模型出 {一句话定性 + 是否建议安装}(拒绝假AI:确定性只找到
    /// 「有 .app」这个候选,冒不冒 + 措辞由模型定);③ 写回索引(`setDiskImageSuggestion`)。门控同单文件建议
    /// (AI 建议开关 + 内容预读 + 模型就绪);预算 = AI 活跃度档位的 `maxModelSuggestionsPerRound`。可取消、串行不重叠。
    /// **peek 阶段绝不挂载**(纯 7zz 文件读);点击「安装 X」才走 app 内置复制逻辑把 .app 拷进 /Applications(用户授权)。
    func generateDiskImageSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.contentPrereadEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        guard !diskImageRunning else { recordRunningPass("装App"); return }
        let candidates = AIPrereadSelection.selectDiskImagesForSuggestion(
            records: store.recentFileRecords(limit: 2_000),
            budget: budget.maxModelSuggestionsPerRound, now: Date())
        recordPass("装App", candidates: candidates.count, skip: candidates.isEmpty ? "无候选(含 .app 的 dmg 0)" : nil)
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
                    .map { AIPrereadSelection.topAppBundleNames(in: $0) } ?? []
                guard !appNames.isEmpty else {
                    AIBackgroundIndexStore.shared.setDiskImageSuggestion(recordID: rec.id, summary: nil, appName: nil)
                    continue   // 没 .app(或 peek 失败)→ 标记已评估,下轮不再选
                }
                // 模型决定冒不冒 + 措辞;模型失败 → 不标记(下轮重试,budget 兜底不会失控)。
                guard let result = try? await AIAgentClient.generatePass(
                    kind: .diskImageInstallSuggestion,
                    input: DiskImageSuggestionInput(dmgName: rec.fileName, appNames: appNames),
                    as: AIPassDiskImageOutput.self) else { continue }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.setDiskImageSuggestion(
                    recordID: rec.id,
                    summary: result.summary.isEmpty ? nil : result.summary,
                    appName: result.suggest ? appNames.first : nil)
            }
        }
    }

    // topAppBundleNames 已下沉 Core → AIPrereadSelection.topAppBundleNames。

    // MARK: - 「文件有活动」建议(backlog 第3项;MainActor:读活动快照 + 模型 async)

    /// 文件精确命中**近期成功任务的产物路径**(复用喂 Spotlight 的活动快照 `ArchiveTaskSnapshot.outputPath`)→ 端上
    /// 模型用一句话提醒「最近对它做过什么」→ 写回 `openTask` 动作(导航复用现成 `.openTask` 路由,零新代码)。门控:
    /// AI 建议开关 + 后台索引 + 模型就绪;预算挂活跃度档;**已指向同一任务的跳过**(任务变了才重做)。目录行无抽屉 → 跳过。
    func generateActivityLinkSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady,
              let budget = store.budget else { return }
        guard !activityRunning else { recordRunningPass("活动"); return }
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
        recordPass("活动", candidates: picks.count, skip: picks.isEmpty ? "无候选(命中近期任务产物的文件 0)" : nil)
        guard !picks.isEmpty else { return }
        activityRunning = true
        activityTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.activityRunning = false }
            for (rec, snap) in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { break }
                guard let path = rec.path, FileManager.default.fileExists(atPath: path) else { continue }
                let actionText = AIBackgroundIndexer.activityActionText(for: snap.kind)
                let whenText = AIAgeFacts.coarseWhenText(snap.finishedAt ?? snap.startedAt, now: Date())
                // 阶段3:整条 pass 经前台 XPC Service 在引擎进程跑(主二进制零模型推理)。
                let input = ActivityReminderInput(fileName: rec.fileName, actionText: actionText, whenText: whenText)
                guard let out = try? await AIAgentClient.generatePass(
                    kind: .activityReminder, input: input, as: AIPassTextOutput.self),
                      !out.text.isEmpty else { continue }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.applyActivitySuggestion(recordID: rec.id, taskID: snap.id, phrasing: out.text)
            }
        }
    }

    /// 任务类型 → 「产生这个文件时做了什么」的中性英文描述。前台与后台 agent 共用 Core 的 `AIActivityActionText`
    /// (按 rawValue 映射,避免两处分叉);**不含任何具体软件名**(模型转界面语言,见提示词规矩)。
    nonisolated static func activityActionText(for kind: OperationTask.Kind) -> String {
        AIActivityActionText.text(forKindRawValue: kind.rawValue)
    }

    // coarseWhenText 已下沉 Core → AIAgeFacts.coarseWhenText。

    // MARK: - 建议六 v2 模块⑤:活动中心「建议筛选」chip 的模型排序(后台预烘焙)

    /// 活动中心「建议筛选」chip 的**模型排序/精选**(拒绝假AI)。确定性 builder 出候选 chip 池(App 安全枚举的预定义
    /// filter);端上模型只按编号挑出最值得展示的几个并排序,绝不发明 filter。每轮**只处理 1 个分类**(第一个排序过期
    /// 的;队列收敛 `4fd1fcad`),指纹幂等(chip 池没变不重排),写回 store,前台只读缓存。门控:跑在 `canRunModelWorkNow`
    /// 下(空闲 + 充电语义 + 非低电/省电)→ 电源管理自动接上。**只喂 chip 语义维度 + 匹配数,不含任务标题 / 路径。**
    func generateWorkbenchChipRankingIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady,
              store.budget != nil else { return }
        guard !workbenchRankingRunning else { recordRunningPass("筛选排序"); return }
        let all = (TaskCenter.shared.active + TaskCenter.shared.history).map(\.aiTaskRecord)
        // 找第一个「排序过期 / 没排过」的分类(每轮只排 1 个,逐轮覆盖全部分类)。
        var pick: (category: String, chips: [ActivityAIWorkbenchFilterChip], fingerprint: String)?
        for category in ["archive", "fileOperation", "undoRedo"] {
            let records = all.filter { $0.category == category }
            let chips = ActivityAIWorkbenchBuilder.snapshot(records: records).filterChips
            guard chips.count >= 2 else { continue }   // < 2 个 chip 不必排
            let fingerprint = ActivityAIWorkbenchKeys.chipPoolFingerprint(chips)
            if store.workbenchChipRanking(forCategory: category)?.fingerprint != fingerprint {
                pick = (category, chips, fingerprint); break
            }
        }
        guard let pick else { recordPass("筛选排序", candidates: 0, skip: "全部分类已排序 / 无可排 chip"); return }
        recordPass("筛选排序", candidates: pick.chips.count)
        workbenchRankingRunning = true
        workbenchRankingTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.workbenchRankingRunning = false }
            guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { return }
            // 阶段3:经前台 XPC Service 在引擎进程跑排序。
            let candidates = pick.chips.map {
                WorkbenchChipRankingInput.Candidate(
                    label: ActivityAIWorkbenchKeys.chipPromptLabel($0), matches: ActivityAIWorkbenchKeys.chipMatchCount($0))
            }
            guard let out = try? await AIAgentClient.generatePass(
                kind: .rankWorkbenchFilterChips, input: WorkbenchChipRankingInput(candidates: candidates),
                as: AIPassIntListOutput.self), !out.numbers.isEmpty else { return }
            let orderedIDs = out.numbers.compactMap { idx -> String? in
                (idx >= 1 && idx <= pick.chips.count) ? pick.chips[idx - 1].id : nil
            }
            guard !orderedIDs.isEmpty else { return }
            guard !Task.isCancelled else { return }   // 模型生成期间关了 AI → 不写过期结果(P2-8)
            AIBackgroundIndexStore.shared.applyWorkbenchChipRanking(
                category: pick.category, fingerprint: pick.fingerprint, orderedIDs: orderedIDs)
        }
    }

    // MARK: - 建议六 v2 模块1「需要处理」AI 解读 + 模块①「失败解释」(后台预烘焙)

    /// 建议六 v2 模块1:后台让端上模型给活动中心「需要处理」卡写一段解读(现在最值得先处理什么 + 为什么)。每轮**只处理
    /// 1 个分类**(第一个解读过期 / 没解读过的;队列收敛 `4fd1fcad`),未读失败集指纹幂等(集合没变不重生成),写回 store,
    /// 前台只读缓存。门控:跑在 `canRunModelWorkNow` 下(空闲 + 充电语义 + 非低电/省电)。**只喂 类型 / 来源 / 诊断标签 +
    /// 计数,不含原始标题 / 路径**;无未读失败的分类清空其缓存(列表恢复确定性文案)。
    func generateWorkbenchNeedsAttentionIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady,
              store.budget != nil else { return }
        guard !workbenchNeedsAttentionRunning else { recordRunningPass("需要处理解读"); return }
        let all = (TaskCenter.shared.active + TaskCenter.shared.history).map(\.aiTaskRecord)
        // 找第一个「解读过期 / 没解读过、且有未读失败」的分类(每轮只做 1 个,逐轮覆盖全部分类)。
        var pick: (category: String, records: [AITaskRecord], fingerprint: String)?
        for category in ["archive", "fileOperation", "undoRedo"] {
            let records = all.filter { $0.category == category }
            let fingerprint = ActivityAIWorkbenchKeys.needsAttentionFingerprint(records)
            guard !fingerprint.isEmpty else { continue }   // 该分类无未读失败 → 不需要解读
            if store.workbenchNeedsAttentionExplanation(forCategory: category)?.fingerprint != fingerprint {
                pick = (category, records, fingerprint); break
            }
        }
        guard let pick else { recordPass("需要处理解读", candidates: 0, skip: "全部分类已解读 / 无未读失败"); return }
        recordPass("需要处理解读", candidates: 1)
        workbenchNeedsAttentionRunning = true
        workbenchNeedsAttentionTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.workbenchNeedsAttentionRunning = false }
            guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { return }
            let unseenFailed = pick.records.filter { $0.status == "failed" && !$0.failureSeen }
            guard !unseenFailed.isEmpty else { return }
            let summary = ActivityAIWorkbenchSummary(records: pick.records)
            let summaryFacts = [
                "total \(summary.total)", "running \(summary.running)",
                "unseen-failed \(summary.failedUnseen)", "failed \(summary.failedSeen)",
                "succeeded \(summary.succeeded)"
            ]
            let failedFacts = unseenFailed.prefix(8).map { rec -> String in
                let tags = rec.diagnostics.tags.isEmpty ? "no-tags" : rec.diagnostics.tags.joined(separator: "+")
                return "\(rec.kind) / \(rec.source) / \(tags)"
            }
            // 阶段3:整条 pass 经前台 XPC Service 在引擎进程跑(主二进制零模型推理)。
            let input = ActivityWorkbenchExplanationInput(summaryFacts: summaryFacts, failedFacts: Array(failedFacts))
            guard let out = try? await AIAgentClient.generatePass(
                kind: .activityWorkbenchExplanation, input: input, as: AIPassTextOutput.self),
                  !out.text.isEmpty else { return }
            guard !Task.isCancelled else { return }   // 模型生成期间关了 AI → 不写过期结果(P2-8)
            AIBackgroundIndexStore.shared.applyWorkbenchNeedsAttentionExplanation(
                category: pick.category, fingerprint: pick.fingerprint, text: out.text)
        }
    }

    /// 建议六 v2 模块①:后台让端上模型给**失败任务**逐个写一段短解释(展开任务时前台只读缓存,不再前台触发模型)。每轮
    /// **只处理 1 个失败任务**(第一个解释过期 / 没解释过的;队列收敛),脱敏诊断指纹幂等(失败态没变不重生成),写回 store
    /// 并随活失败任务集修剪(历史不累积)。门控:`canRunModelWorkNow`。**只喂脱敏诊断(类型 / 来源 / 标签 / 脱敏消息 /
    /// 脱敏错误行),不含原始标题 / 路径。**
    func generateWorkbenchFailureExplanationsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady,
              store.budget != nil else { return }
        guard !workbenchFailureRunning else { recordRunningPass("失败解释"); return }
        let failed = (TaskCenter.shared.active + TaskCenter.shared.history)
            .map(\.aiTaskRecord).filter { $0.status == "failed" }
        let liveTaskIDs = Set(failed.map(\.id))
        // 找第一个「解释过期 / 没解释过」的失败任务(每轮只做 1 个,逐轮覆盖)。
        var pick: (record: AITaskRecord, fingerprint: String)?
        for record in failed {
            let fingerprint = ActivityAIWorkbenchKeys.failureExplanationFingerprint(record)
            if store.workbenchFailureExplanation(forTask: record.id)?.fingerprint != fingerprint {
                pick = (record, fingerprint); break
            }
        }
        guard let pick else { recordPass("失败解释", candidates: 0, skip: "全部失败任务已解释 / 无失败任务"); return }
        recordPass("失败解释", candidates: 1)
        workbenchFailureRunning = true
        workbenchFailureTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.workbenchFailureRunning = false }
            guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { return }
            let diag = pick.record.diagnostics
            // 阶段3:模型推理迁出主进程 —— 拼好(已脱敏)输入 DTO,经前台 XPC Service 让引擎跑这条 pass(拼 prompt+模型+解析)。
            let input = TaskFailureExplanationInput(
                kind: pick.record.kind, source: pick.record.source, tags: diag.tags,
                failureMessage: diag.failureMessage, errorLines: diag.errorLines)
            guard let out = try? await AIAgentClient.generatePass(
                kind: .taskFailureShortExplanation, input: input, as: AIPassTextOutput.self),
                  !out.text.isEmpty else { return }
            guard !Task.isCancelled else { return }   // 模型生成期间关了 AI → 不写过期结果(P2-8)
            AIBackgroundIndexStore.shared.applyWorkbenchFailureExplanation(
                taskID: pick.record.id, fingerprint: pick.fingerprint, text: out.text, liveTaskIDs: liveTaskIDs)
        }
    }

    /// 建议六 v2「真建议」chip:App 确定性发现真实失败聚集(discoverClusters)→ 后台让模型在这些**真实聚集**上
    /// 择优 + 自然语言命名 → 写回缓存(前台叠加在写死 chip 之上)。每轮只处理 1 个分类(第一个聚集过期 / 没命名的),
    /// 聚集指纹幂等(构成没变不重命名)。门控:`canRunModelWorkNow`。**只喂维度描述 + 命中数,不含任务标题 / 路径。**
    func generateWorkbenchClusterChipsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady,
              store.budget != nil else { return }
        guard !workbenchClusterRunning else { recordRunningPass("真建议"); return }
        let all = (TaskCenter.shared.active + TaskCenter.shared.history).map(\.aiTaskRecord)
        var pick: (category: String, clusters: [AIWorkbenchCluster], fingerprint: String)?
        for category in ["archive", "fileOperation", "undoRedo"] {
            let records = all.filter { $0.category == category }
            let clusters = ActivityAIWorkbenchBuilder.discoverClusters(records: records)
            guard !clusters.isEmpty else { continue }
            let fingerprint = ActivityAIWorkbenchKeys.clusterFingerprint(clusters)
            if store.workbenchClusterChips(forCategory: category)?.fingerprint != fingerprint {
                pick = (category, clusters, fingerprint); break
            }
        }
        guard let pick else { recordPass("真建议", candidates: 0, skip: "全部分类已命名 / 无可命名聚集"); return }
        recordPass("真建议", candidates: pick.clusters.count)
        workbenchClusterRunning = true
        workbenchClusterTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.workbenchClusterRunning = false }
            guard AIBackgroundIndexStore.shared.indexingEnabled, AIReportAssistant.isReady else { return }
            // 阶段3:经前台 XPC Service 在引擎进程跑命名。
            let candidates = pick.clusters.map {
                WorkbenchClusterNamingInput.Candidate(facts: $0.dimensionFacts, matches: $0.matchCount)
            }
            guard let clusterOut = try? await AIAgentClient.generatePass(
                kind: .nameWorkbenchClusters, input: WorkbenchClusterNamingInput(candidates: candidates),
                as: AIPassClusterNamingOutput.self), !clusterOut.entries.isEmpty else { return }
            let named = clusterOut.entries
            let chips: [CachedClusterChip] = named.compactMap { item in
                guard item.index >= 1, item.index <= pick.clusters.count else { return nil }
                let cluster = pick.clusters[item.index - 1]
                return CachedClusterChip(
                    id: ActivityAIWorkbenchKeys.clusterChipID(cluster.filter),
                    displayName: item.name, filter: cluster.filter, matchCount: cluster.matchCount)
            }
            guard !chips.isEmpty else { return }
            guard !Task.isCancelled else { return }   // 模型生成期间关了 AI → 不写过期结果(P2-8)
            AIBackgroundIndexStore.shared.applyWorkbenchClusterChips(
                category: pick.category, fingerprint: pick.fingerprint, chips: chips)
        }
    }

    // MARK: - 压缩包「你可能需要的文件」建议(backlog 第4项;MainActor:读清单缓存 + 模型 async)

    /// 对**预读过(清单已缓存)、还没评估**的归档,让端上模型从包内文件清单里挑**少数几个**用户最可能想单独取出 /
    /// 预览的 → 写回 `revealArchiveEntry` 动作(点击 = `.openArchive(revealEntry:)` 打开并定位,**不解压**)。门控:
    /// AI 建议开关 + 内容预读 + 归档清单缓存开 + 模型就绪;预算挂活跃度档;已评估的跳过(归档变了阶段一清回才重选)。
    func generateArchiveEntrySuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.contentPrereadEnabled, AppPreferences.archiveListingCacheEnabled,
              AIReportAssistant.isReady, store.budget != nil else { return }
        guard !archiveEntryRunning else { recordRunningPass("包内"); return }
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
            if picks.count >= Self.deepContextSuggestionsPerRound { break }
        }
        recordPass("包内", candidates: picks.count, skip: picks.isEmpty ? "无候选(有缓存清单的归档 0)" : nil)
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
                guard let entryOut = try? await AIAgentClient.generatePass(
                    kind: .archiveEntryPicks,
                    input: ArchiveEntryPicksInput(archiveName: rec.fileName, entryPaths: paths),
                    as: AIPassIntListOutput.self) else { continue }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                let actions = entryOut.numbers.map { idx -> AIFileSuggestedAction in
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
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AppPreferences.archiveListingCacheEnabled,
              AIReportAssistant.isReady, canRunDeepContextNow(), store.budget != nil else { return }
        guard !archiveKindRunning else { recordRunningPass("包定性"); return }
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
            if picks.count >= Self.deepContextSuggestionsPerRound { break }
        }
        recordPass("包定性", candidates: picks.count, skip: picks.isEmpty ? "无候选(未定性的归档 0)" : nil)
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
                let kindInput = ArchiveKindGuessInput(
                    archiveName: rec.fileName,
                    entries: entries.map { ArchiveKindGuessInput.Entry(name: $0.name, isDirectory: $0.isDirectory) })
                guard let guess = try? await AIAgentClient.generatePass(
                    kind: .archiveKindGuess, input: kindInput, as: AIPassArchiveKindOutput.self) else { continue }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.applyArchiveKindGuess(
                    recordID: rec.id, summary: guess.summary, toolTokens: guess.toolTokens)
            }
        }
    }

    // MARK: - 解压速览(预烘焙;前台 XPC 按需路径)

    /// 解压对话框打开时按需烘一句话「这是什么包」给速览。**预烘焙优先**:已索引归档的定性由后台 agent 写进
    /// `contentSummary`(调用点先读那份);这里只兜「正在解压、但不在文件索引里」的归档 —— 用对话框已 list 的
    /// 非加密条目经 XPC 引擎(同 agent 的 `.archiveKindGuess` pass)烘一次,写进 `extractAdvisoryByPath` 缓存
    /// (跨重启,再开瞬出)。**这是用户主动开窗触发的前台动作**,与创建实时速览同类 → 只 gate `isReady`,**不**走
    /// `canRunModelWorkNow` 的空闲/活跃度门控(那会在用户正干活时反而压制速览);后台 agent 那半仍受电源门控。
    /// 不可用 / 失败 / 全加密返回 nil(对话框退回纯确定性预检,不报错)。条目名已在调用点按 `!isEncrypted` 过滤。
    @available(macOS 26.0, *)
    func bakeExtractAdvisoryOnDemand(archiveURL: URL, entries: [ArchiveKindGuessInput.Entry]) async -> String? {
        guard AIReportAssistant.isReady else { return nil }
        let trimmed = entries.compactMap { e -> ArchiveKindGuessInput.Entry? in
            let name = e.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.isEmpty ? nil : ArchiveKindGuessInput.Entry(name: name, isDirectory: e.isDirectory)
        }
        guard !trimmed.isEmpty else { return nil }
        guard let guess = try? await AIAgentClient.generatePass(
            kind: .archiveKindGuess,
            input: ArchiveKindGuessInput(archiveName: archiveURL.lastPathComponent, entries: trimmed),
            as: AIPassArchiveKindOutput.self) else { return nil }
        let summary = guess.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        AIBackgroundIndexStore.shared.setExtractAdvisory(path: archiveURL.path, summary: summary)
        return summary
    }

    // MARK: - 文件夹批量分组建议(MainActor:索引记录 → 候选 → 模型 async → 按文件夹缓存)

    /// 对**还没评估**的索引目录,让端上模型从同一文件夹里的文件中圈出少数「可一起批量处理」的组。
    /// 只写派生缓存(`folderGroupsByPath`),不接任何 UI。门控完全沿用包定性:AI 建议开关 + 后台索引 + 模型就绪
    /// + deep-context 空闲门控;预算封顶每轮目录数。
    func generateFolderGroupSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady, canRunDeepContextNow(),
              store.budget != nil else { return }
        guard !folderGroupRunning else { recordRunningPass("文件组"); return }

        var folderOrder: [String] = []
        var recordsByFolder: [String: [AIFileMemoryRecord]] = [:]
        for rec in store.recentFileRecords(limit: 4_000) {
            guard rec.type != .folder, let path = rec.path else { continue }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            guard store.folderGroupsByPath[folder] == nil else { continue }
            if recordsByFolder[folder] == nil { folderOrder.append(folder) }
            recordsByFolder[folder, default: []].append(rec)
        }
        let picks = folderOrder
            .filter { (recordsByFolder[$0]?.count ?? 0) >= 2 }
            .prefix(Self.deepContextSuggestionsPerRound)
        recordPass("文件组", candidates: picks.count, skip: picks.isEmpty ? "无候选(可成组的文件夹 0)" : nil)
        guard !picks.isEmpty else { return }

        folderGroupRunning = true
        folderGroupTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.folderGroupRunning = false }
            for folder in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.indexingEnabled,
                      AIReportAssistant.isReady,
                      AIBackgroundIndexer.shared.canRunDeepContextNow() else { break }
                let records = recordsByFolder[folder] ?? []
                var pathByCandidateID: [String: String] = [:]
                let candidates = records.compactMap { rec -> AIVirtualNodePromptCandidate? in
                    guard let path = rec.path else { return nil }
                    let candidate = AIWorkspaceDiscovery.candidate(from: rec)
                    pathByCandidateID[candidate.id] = path
                    return AIVirtualNodePromptCandidate(candidate: candidate)
                }
                guard candidates.count >= 2 else {
                    AIBackgroundIndexStore.shared.setFolderGroups([], forPath: folder)
                    continue
                }
                guard let suggestions = try? await AIVirtualFolderModelPlanner.folderGroupSuggestions(items: candidates)
                else { continue }
                let groups = suggestions.compactMap { suggestion -> CachedFolderGroup? in
                    var seen = Set<String>()
                    let paths = suggestion.memberIDs.compactMap { pathByCandidateID[$0] }
                        .filter { seen.insert($0).inserted }
                    guard paths.count >= 2 else { return nil }
                    return CachedFolderGroup(title: nil, memberPaths: paths, actionToken: suggestion.actionToken)
                }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.setFolderGroups(groups, forPath: folder)
            }
        }
    }

    /// Task 7:对**还没评估**的索引目录,让端上模型判断是否有一簇同类文件值得归进一个新子文件夹,有则起主题名 +
    /// 圈成员,写派生缓存(`organizeByPath`)。**不移动任何文件** —— 真正建文件夹 + 移动由用户在顶部建议条点「整理」
    /// 后走 app 内置 `dropFileURLs(...shouldMove:true)`(冲突弹窗 + 撤销 + 活动中心都在里头)。门控完全沿用文件组建议;
    /// 重型清单类 pass,每轮只 1 个候选(`deepContextSuggestionsPerRound`,队列收敛 `4fd1fcad`)。
    func generateOrganizeSuggestionsIfEnabled() {
        guard #available(macOS 26.0, *) else { return }
        let store = AIBackgroundIndexStore.shared
        guard AppPreferences.aiSuggestionEnabled, store.indexingEnabled, AIReportAssistant.isReady, canRunDeepContextNow(),
              store.budget != nil else { return }
        guard !organizeRunning else { recordRunningPass("整理"); return }

        var folderOrder: [String] = []
        var recordsByFolder: [String: [AIFileMemoryRecord]] = [:]
        for rec in store.recentFileRecords(limit: 4_000) {
            guard rec.type != .folder, let path = rec.path else { continue }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            guard !store.organizeEvaluated(forPath: folder) else { continue }
            if recordsByFolder[folder] == nil { folderOrder.append(folder) }
            recordsByFolder[folder, default: []].append(rec)
        }
        // 整理需要一簇文件 —— 至少 3 个文件的文件夹才值得评估。
        let picks = folderOrder
            .filter { (recordsByFolder[$0]?.count ?? 0) >= 3 }
            .prefix(Self.deepContextSuggestionsPerRound)
        recordPass("整理", candidates: picks.count, skip: picks.isEmpty ? "无候选(可整理的文件夹 0)" : nil)
        guard !picks.isEmpty else { return }

        organizeRunning = true
        organizeTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.organizeRunning = false }
            var produced = 0
            for folder in picks {
                if Task.isCancelled { break }
                guard AIBackgroundIndexStore.shared.indexingEnabled,
                      AIReportAssistant.isReady,
                      AIBackgroundIndexer.shared.canRunDeepContextNow() else { break }
                let records = recordsByFolder[folder] ?? []
                var pathByCandidateID: [String: String] = [:]
                let candidates = records.compactMap { rec -> AIVirtualNodePromptCandidate? in
                    guard let path = rec.path else { return nil }
                    let candidate = AIWorkspaceDiscovery.candidate(from: rec)
                    pathByCandidateID[candidate.id] = path
                    return AIVirtualNodePromptCandidate(candidate: candidate)
                }
                guard candidates.count >= 3 else {
                    AIBackgroundIndexStore.shared.setOrganizeSuggestion(nil, forPath: folder)
                    continue
                }
                // 模型失败(抛错)→ 不落哨兵,下轮重试;模型「不值得」(nil)→ 落空哨兵,不再重评该文件夹。
                let suggestion: (folderName: String, memberIDs: [String])?
                do {
                    suggestion = try await AIVirtualFolderModelPlanner.organizeSuggestion(items: candidates)
                } catch {
                    continue
                }
                guard let suggestion else {
                    AIBackgroundIndexStore.shared.setOrganizeSuggestion(nil, forPath: folder)
                    continue
                }
                var seen = Set<String>()
                let paths = suggestion.memberIDs.compactMap { pathByCandidateID[$0] }.filter { seen.insert($0).inserted }
                guard paths.count >= 3 else {
                    AIBackgroundIndexStore.shared.setOrganizeSuggestion(nil, forPath: folder)
                    continue
                }
                if Task.isCancelled { break }   // 模型生成期间关了 AI → 不写过期建议(P2-8)
                AIBackgroundIndexStore.shared.setOrganizeSuggestion(
                    CachedFolderGroup(title: suggestion.folderName, memberPaths: paths, actionToken: "organize"),
                    forPath: folder)
                produced += 1
            }
            AIBackgroundIndexer.shared.recordPass("整理", candidates: picks.count, produced: produced)
        }
    }

    // MARK: - 只读自动检查 pending 队列(阶段 B,电池决策;MainActor:读索引缓存 + 入队,不调模型不执行)

    /// 把模型**已挑**的只读检查 token(hash/test/inspect/security)从索引缓存收进 pending 队列(幂等)。
    /// **不调模型、不执行检查** —— 只是「电池侧决定要做什么」;真执行等插电(阶段 C)。同文件同检查同指纹不重排。
    func generatePendingChecksIfEnabled() {
        guard AppPreferences.aiSuggestionEnabled, AIBackgroundIndexStore.shared.indexingEnabled else { return }
        let tokenToBehavior: [String: AIPendingCheck.Behavior] = [
            "hash": .hash, "test": .test, "inspect": .inspect, "security": .security
        ]
        var items: [(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String)] = []
        for rec in AIBackgroundIndexStore.shared.recentFileRecords(limit: 2_000) {
            guard let path = rec.path, let summary = rec.contentSummary else { continue }
            let fingerprint = AIPendingCheck.fingerprint(byteSize: rec.byteSize, modifiedAt: rec.modifiedAt)
            for action in summary.suggestedActions {
                guard let behavior = tokenToBehavior[action.token] else { continue }
                items.append((path, behavior, fingerprint))
            }
        }
        guard !items.isEmpty else { return }
        AIPendingCheckStore.shared.enqueueBatch(items)
        AIPendingCheckStore.shared.prune()
    }

    // MARK: - 后台调度计划执行(工程补充五接线 Phase 1:plan→入队,真执行走下面的 executePendingChecksIfDue)

    /// 把 `AIBackgroundPlanner` 产的 plan 里**确定性 evidence job** 翻成 pending 入队(Phase 1/2:
    /// `calculateCheapHashes`→`.hash`、`testSmallArchives`→`.test`)。工作区成员缺哈希 / 小归档没测 → plan 产
    /// 对应 job → 这里经 `pathsBySourceRef` 回查路径入队 → 既有 `executePendingChecksIfDue`(插电侧)真算 / 真测
    /// + 写内联结果。**幂等**(同指纹不重排)、纯入队不执行、不调模型、不碰 reload;其余 job kind 暂跳过(Phase 3+
    /// 接)。DevTools 经 recordPass 观测。
    func executePlannedJobsIfDue() {
        guard AppPreferences.aiSuggestionEnabled, AIBackgroundIndexStore.shared.indexingEnabled else { return }
        let plan = planBackgroundJobs()
        let store = AIBackgroundIndexStore.shared
        var items: [(path: String, behavior: AIPendingCheck.Behavior, fingerprint: String)] = []
        for job in plan.jobs {
            let behavior: AIPendingCheck.Behavior
            switch job.kind {
            case .calculateCheapHashes: behavior = .hash
            case .testSmallArchives:    behavior = .test
            default: continue
            }
            for ref in job.sourceRefs {
                guard let path = AIWorkspaceStore.shared.path(forSourceRef: ref),
                      let rec = store.record(forPath: path) else { continue }
                items.append((path, behavior,
                              AIPendingCheck.fingerprint(byteSize: rec.byteSize, modifiedAt: rec.modifiedAt)))
            }
        }
        guard !items.isEmpty else {
            recordPass("调度执行", candidates: plan.jobs.count,
                       skip: plan.jobs.isEmpty ? "plan 无 job" : "无确定性 evidence job 可入队(Phase 1/2:hash/test)")
            return
        }
        AIPendingCheckStore.shared.enqueueBatch(items)
        AIPendingCheckStore.shared.prune()
        recordPass("调度执行", candidates: plan.jobs.count, produced: items.count)
    }

    // MARK: - 只读自动检查执行(阶段 C,插电执行;MainActor:间隔节流 + 真检查 + 写内联结果)

    /// 插电时按活跃度间隔**逐个**执行 pending 只读检查,结果写回内联(复用 `applyInlineResult`,抽屉自动显示)。
    /// 自门控:AI 开 + 索引开 + **充电中** + 距上次执行 ≥ 间隔(4/15/30 分)+ 没在执行。一次一条(间隔即天然串行)。
    /// 处理**全部 4 种行为**(否则队列头是 security/inspect 时会卡住 hash/test):
    /// - hash / test = 事实必显(算出 / 测过即内联);
    /// - security / inspect = 阶段 D:列清单 + 安全分析 / 发布检查 →「执行完显式 AI 复判值不值得显示」
    ///   (`AIPendingCheckJudge`:没异常不冒)→ 有异常才端上模型润色成白话(macOS26;空返不冒)→ 内联。
    /// 加密 / 损坏 / 需口令 → 记失败、不展示假结果(同指纹不再重排,文件改了才重试)。
    func executePendingChecksIfDue() {
        guard !pendingExecRunning, AppPreferences.aiSuggestionEnabled,
              AIBackgroundIndexStore.shared.indexingEnabled else { return }
        guard gate.isChargingNow() == true else { return }   // 只插电执行
        let level = AppPreferences.aiBackgroundActivityLevel
        guard level != .off else { return }
        let interval = AIPendingCheckSchedule.interval(for: level)
        if let last = lastPendingExecAt, Date().timeIntervalSince(last) < interval { return }   // 间隔节流
        guard let check = AIPendingCheckStore.shared.nextPending() else { return }
        guard let recordID = AIBackgroundIndexStore.shared.record(forPath: check.path)?.id else {
            AIPendingCheckStore.shared.markFailed(id: check.id)
            return
        }
        pendingExecRunning = true
        lastPendingExecAt = Date()
        let id = check.id
        let path = check.path
        let behavior = check.behavior
        pendingExecTask = Task { @MainActor in
            defer { AIBackgroundIndexer.shared.pendingExecRunning = false }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                AIPendingCheckStore.shared.markFailed(id: id)
                return
            }
            do {
                switch behavior {
                case .hash:
                    let text = try await Task.detached(priority: .utility) { try HashService.sha256(for: url) }.value
                    AIBackgroundIndexStore.shared.applyInlineResult(recordID: recordID, token: behavior.rawValue, text: text)
                    AIPendingCheckStore.shared.markDone(id: id)
                case .test:
                    try await ArchiveService.test(url, password: "")
                    AIBackgroundIndexStore.shared.applyInlineResult(
                        recordID: recordID, token: behavior.rawValue, text: L10n.text("aiWorkspace.inlineTest.passed"))
                    AIPendingCheckStore.shared.markDone(id: id)
                case .security:
                    try await AIBackgroundIndexer.shared.executePendingSecurity(url: url, recordID: recordID, id: id)
                case .inspect:
                    try await AIBackgroundIndexer.shared.executePendingInspect(url: url, recordID: recordID, id: id)
                }
            } catch is CancellationError {
                AIBackgroundIndexer.shared.lastPendingExecAt = nil   // 取消不算执行,下次可立即重试
            } catch {
                // 加密 / 损坏 / 需口令 → 不展示假结果,记失败(同指纹不再重排,文件改了才重试)。
                AIPendingCheckStore.shared.markFailed(id: id)
            }
        }
    }

    /// 阶段 D · 路径安全检测:空口令列清单(加密 / 损坏 → 抛错 → 上层 markFailed)→ 安全分析 + 评级 →
    /// **AI 复判**(`securityWorthSurfacing`:没异常 → markDone 不展示)→ 有异常时端上模型润色成一句白话
    /// (macOS26 + 就绪;不可用 / 空返 → markDone 不展示假结果)→ 内联。复用 on-demand 同款 Core 单元,不重写。
    private func executePendingSecurity(url: URL, recordID: String, id: String) async throws {
        let items = try await ArchiveService.list(url)
        let findings = ArchiveSecurityReport.analyze(items)
        let assessment = ArchiveRiskScore.assess(
            findings: findings,
            encryptedCount: items.filter(\.isEncrypted).count,
            junkCount: ArchiveJunkFiles.junkEntries(in: items).count)
        guard AIPendingCheckJudge.securityWorthSurfacing(findings: findings, assessment: assessment) else {
            AIPendingCheckStore.shared.markDone(id: id); return   // 干净 → 执行过了但不冒
        }
        guard #available(macOS 26.0, *), AIReportAssistant.isReady else {
            AIPendingCheckStore.shared.markDone(id: id); return   // 模型不可用 → 不展示假结果
        }
        let prompt = AIReportAssistant.inlinePathSafetyPrompt(assessment: assessment, findings: findings, listable: true)
        let text = try await AIReportAssistant.generate(instructions: prompt.instructions, prompt: prompt.prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { AIPendingCheckStore.shared.markDone(id: id); return }
        AIBackgroundIndexStore.shared.applyInlineResult(
            recordID: recordID, token: AIPendingCheck.Behavior.security.rawValue, text: text)
        AIPendingCheckStore.shared.markDone(id: id)
    }

    /// 阶段 D · 发布包检测:空口令列清单(加密 / 损坏 → 抛错 → markFailed)→ 统计 + 安全发现 + 完整性测试 →
    /// **AI 复判**(`inspectWorthSurfacing`:没问题 → 不冒)→ 有问题时模型润色 → 内联。复用 `ReleaseInspection.stats` /
    /// `ArchiveSecurityReport` / `ArchiveStructuralFingerprint` 等 Core 单元(不跑 bundle 检查 —— 那是 .app/.dmg 专路)。
    private func executePendingInspect(url: URL, recordID: String, id: String) async throws {
        let items = try await ArchiveService.list(url)
        var report = ReleaseInspectionReport(archiveURL: url)
        report.listable = true
        report.stats = ReleaseInspection.stats(for: items)
        report.securityFindings = ArchiveSecurityReport.analyze(items)
        report.structuralFingerprint = ArchiveStructuralFingerprint.compute(for: items)
        report.hasComment = !ArchiveService.headerComment(for: url).isEmpty
        do {
            try await ArchiveService.test(url, password: "")
            report.testPassed = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report.testPassed = false
            report.testFailureMessage = String(error.localizedDescription.prefix(160))
        }
        guard AIPendingCheckJudge.inspectWorthSurfacing(report: report) else {
            AIPendingCheckStore.shared.markDone(id: id); return
        }
        guard #available(macOS 26.0, *), AIReportAssistant.isReady else {
            AIPendingCheckStore.shared.markDone(id: id); return
        }
        let prompt = AIReportAssistant.inlineReleaseInspectionPrompt(for: report)
        let text = try await AIReportAssistant.generate(instructions: prompt.instructions, prompt: prompt.prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { AIPendingCheckStore.shared.markDone(id: id); return }
        AIBackgroundIndexStore.shared.applyInlineResult(
            recordID: recordID, token: AIPendingCheck.Behavior.inspect.rawValue, text: text)
        AIPendingCheckStore.shared.markDone(id: id)
    }

    /// **「查看更长总结」按需现算**(backlog B)。双击抽屉摘要行 → 弹窗实时生成:后台线程重读 + 脱敏头部 → 端上模型
    /// 出更长总结。红线照旧(敏感目录 / 疑似密钥不读)。调用点(sheet 的 produce 闭包)已在 AI 就绪门控内;读不到
    /// 内容也让模型从名字 / 角色尽力。复用预索引记录的结构信号(标题 / 语言)当上下文。
    @available(macOS 26.0, *)
    static func generateLongSummary(url: URL, fileName: String) async throws -> String {
        let excerptTask = Task.detached(priority: .userInitiated) {
            AIIndexerScan.redactedExcerpt(url: url, fileName: fileName) ?? ""
        }
        let excerpt = await excerptTask.value
        let record = AIBackgroundIndexStore.shared.record(forPath: url.path)
        let roleTags = record?.roleTags ?? AIFileType.roleTags(fileName: fileName, isDirectory: false)
        // 阶段3:实时按需总结也经前台 XPC Service 在引擎进程跑(主二进制零模型推理)。
        let input = LongFileSummaryInput(
            fileName: fileName, roleTags: roleTags,
            languageHint: record?.contentSummary?.languageHint,
            headings: record?.contentSummary?.headings ?? [], excerpt: excerpt)
        return try await AIAgentClient.generatePass(
            kind: .longFileSummary, input: input, as: AIPassTextOutput.self).text
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

}

// MARK: - 阶段0b:从 AIBackgroundIndexer god-object 抽出的「pass 诊断」协作类

/// 一个 pass 上一次执行的画像。`candidates` = 门控过了之后真正选到的候选数;`produced` = 这轮写出的产物数;
/// `skip` = 选到候选但没产出 / 没跑的原因(如「无候选」「模型空返」「门控未过」)。
nonisolated struct PassDiag: Sendable {
    var lastRunAt: Date?
    var candidates: Int = 0
    var produced: Int = 0
    var skip: String?
}

/// DevTools 诊断:记录每个后台 pass 上一次执行的画像(候选数 / 产物数 / 跳过原因 / 时间)。从 god-object 抽出,
/// 行为与原内联逻辑逐字一致 —— 只负责存与读,不碰门控 / 调度 / 模型(那些仍在 indexer)。随 indexer 在主线程访问。
final class AIIndexerPassDiagnostics {
    private(set) var byPass: [String: PassDiag] = [:]

    /// 记一条 pass 画像(pass 在候选选定 / 收尾时调)。
    func record(_ name: String, candidates: Int = 0, produced: Int = 0, skip: String? = nil) {
        byPass[name] = PassDiag(lastRunAt: Date(), candidates: candidates, produced: produced, skip: skip)
    }

    /// pass 仍在运行:沿用上轮候选 / 产出数,skip 标「仍在运行」(与原 `recordRunningPass` 一致)。
    func recordRunning(_ name: String) {
        let prior = byPass[name]
        record(name, candidates: prior?.candidates ?? 0, produced: prior?.produced ?? 0, skip: "仍在运行")
    }
}

// MARK: - 阶段0b:从 AIBackgroundIndexer god-object 抽出的「运行时门控」协作类
//
// 组装 `AIBackgroundRuntimeContext`(App 活跃 / 空闲 / 电源 / 模型可用 / 活跃度档)交给 Core 的
// `AIBackgroundSchedulingRules` 判定能跑到哪档(Core 不读墙钟,时间换算在这里做)。文档 02:这块 `currentRuntimeContext`
// 将来要拆成「App runtime hint」喂给 agent —— 先从 god-object 独立出来。@MainActor:持有 NSEvent 本地监视器 +
// 读 `NSApplication.isActive`,必须主线程。

@MainActor
final class AIIndexerGate {
    /// App 启动时刻 —— 算「距启动秒数」给启动静默期(60s)用。
    private let launchDate = Date()
    /// 距用户上次交互 —— 本地事件监视器更新。**只在 app 活跃时捕获事件**:app 在后台 = 无本地事件 = 距上次交互
    /// 持续增长 = 视为空闲,正合「用户没在用 SimpleZip 时才跑模型」。
    private var lastInteractionDate = Date()
    private var interactionMonitor: Any?
    /// DevTools 开着时**完全豁免交互门控** —— 挂着 DevTools debug / 复制信息绝不该被当成「用户在用 app」把正在观察的
    /// 后台 AI pass 停掉(用户实测:干啥都归零)。**任何**事件、任何窗口,只要这面旗子立着就一律不计交互。
    private(set) var devToolsInteractionExempt = false

    init() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            if self.devToolsInteractionExempt { return event }   // DevTools 开着 = 完全豁免,任何交互一律不计
            self.lastInteractionDate = Date()
            return event
        }
    }

    /// DevTools 豁免开关的**状态部分**:开 → 豁免 + 立即视为空闲(拨表到 1 小时前让模型档立刻满足);关 → 恢复正常
    /// 交互计时。「开了立刻评一轮」(runIfEnabled)是编排,由调用方 indexer 接,不属门控。
    func setExemption(_ on: Bool) {
        devToolsInteractionExempt = on
        lastInteractionDate = on ? Date().addingTimeInterval(-3_600) : Date()
    }

    /// 组装当前运行时上下文给 `AIBackgroundSchedulingRules` 判定能跑到哪档(时间换算在这里做,Core 不读墙钟)。
    func currentRuntimeContext() -> AIBackgroundRuntimeContext {
        let now = Date()
        let power = AIIndexerGate.powerState()
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

    /// 当前是否在充电(只读电源,不组装完整上下文)。pending 检查「只插电执行」用。
    func isChargingNow() -> Bool? { AIIndexerGate.powerState().isCharging }

    /// 读电源状态(低电 < 20% / 是否充电)。实现下沉 Core(AISystemPower)供 App + agent 共用,这里转发。
    private nonisolated static func powerState() -> (lowBattery: Bool, isCharging: Bool?) {
        AISystemPower.batteryState()
    }
}
