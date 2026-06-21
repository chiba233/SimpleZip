//
//  AIAgentBackgroundIndex.swift
//  SimpleZipAIAgent
//
//  独立 AI 进程改造 · 阶段2 · **agent 后台索引一轮**(launchd 周期拉起 agent 跑这个)。
//
//  数据通路:读 App 同步来的配置 + App 写的 scope 白名单 → `AIBackgroundIndexRun.scan`(与 App 前台共用的
//  Core 扫描编排)→ 写回派生索引文件(App 读)。**纯元数据 / 渐进覆盖 / 续扫** 全复用现成 Core 机制,本文件
//  只做「headless 读 → 扫 → 写回」的胶水(App 那半边由 @MainActor 的 AIBackgroundIndexStore 干同样的事)。
//
//  门控(opt-in,层层兜底,任一不满足即不跑):AI 主开关(红线)+ 静默后台索引总开关(独立 opt-in 默认关)+
//  后台索引开关 + 活跃度≠off + 有白名单。**电源门控 / 间隔判定不在这里** —— 那是 launchd 调度 + 调用方(下一刀)的事;
//  本函数只负责「真要跑时,跑一轮、超时即停、写回」。单次 timeout 由调用方折进 `isCancelled`(传 `{ Date() >= 截止 }`)。
//
//  A19:agent 的 `Bundle.main` 指向符号链接母目录、不可信 → 一切路径据**约定的 App bundle id**
//  (`AIAgentConfiguration.appBundleID`,#if DEBUG 隔离 dev/prod)显式拼;偏好域用 `UserDefaults(suiteName:)` 读对。
//
//  全程同步(元数据扫描是纯同步文件 IO,不调模型)→ 调用方直接调 + exit,无需 run loop。
//

import Foundation

enum AIAgentBackgroundIndex {

    nonisolated struct RunSummary: Sendable {
        let scopesScanned: Int
        let recordsWritten: Int
        var bakedSummaries: Int = 0
        var bakedURLs: Int = 0
        let note: String
    }

    /// App 共享的 Application Support 子目录(`<App Support>/<App bundle id>/`)。A19:不靠 Bundle.main。
    private static func appSupportBase() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(AIAgentConfiguration.appBundleID, isDirectory: true)
    }

    /// 读 App 写的 scope 白名单(偏好域 = App bundle id;A19 + 实测:嵌入 helper 被拉起时 Bundle.main 解析到
    /// app bundle → suiteName==自己 id 会失效读空,故统一走 appDomainDefaults()——该情况回退 .standard 才是对的域)。
    private static func loadScopes() -> [AIArchivePrefetchScope] {
        guard let data = AIAgentConfiguration.appDomainDefaults().data(forKey: AppPreferences.Key.aiBackgroundIndexScopes),
              let scopes = try? JSONDecoder().decode([AIArchivePrefetchScope].self, from: data) else { return [] }
        return scopes
    }

    /// 写回 scope 白名单(只为更新 lastScannedAt → 下轮 leastRecentlyScanned 续扫)。互斥由 app/agent 让位保证。
    private static func saveScopes(_ scopes: [AIArchivePrefetchScope]) {
        guard let data = try? JSONEncoder().encode(scopes) else { return }
        AIAgentConfiguration.appDomainDefaults().set(data, forKey: AppPreferences.Key.aiBackgroundIndexScopes)
    }

    /// agent 上次成功跑完后台索引的时刻(epoch 秒)。用于**间隔自节流**:launchd 用固定 base 频率(最小档)周期拉起,
    /// 配置间隔 > base 时,中间几次唤醒据此廉价 no-op(偏好域 = App bundle id,App 也可读来显示「上次后台索引」)。
    private static let lastIndexRunKey = "SimpleZip.ai.agent.lastIndexRun.v1"
    private static func loadLastRun() -> Date? {
        let epoch = AIAgentConfiguration.appDomainDefaults().double(forKey: lastIndexRunKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
    private static func saveLastRun(_ date: Date) {
        AIAgentConfiguration.appDomainDefaults().set(date.timeIntervalSince1970, forKey: lastIndexRunKey)
    }

    /// 跑一轮后台索引 + **模型烘焙**(launchd 周期拉起 → 据配置间隔自节流 → 元数据扫描 → 在本进程内直调端上模型
    /// 预烘焙各 pass → 写回)。async:模型生成是异步的(`AIAgentBaker` 直调引擎)。
    /// - force: 跳过间隔自节流 + app/agent 前台锁让位(给 `--force` 命令行测试用;门控 / 红线仍生效)。
    /// - extraCancel: 调用方附加停止钩子;函数内把单次 timeout 也折进同一个钩子。
    /// - log: 滚动进度(扫描每个 scope、烘焙每个 pass);命令行打到 stderr,默认无。
    static func runOnce(force: Bool = false,
                        extraCancel: @escaping () -> Bool = { false },
                        log: @escaping (String) -> Void = { _ in }) async -> RunSummary {
        func skip(_ note: String) -> RunSummary { log(note); return RunSummary(scopesScanned: 0, recordsWritten: 0, note: note) }

        // 1. 配置门控(红线主开关 + 静默后台 opt-in + 后台索引开关 + 活跃度)。
        guard let config = AIAgentConfiguration.loadPersisted() else { return skip("无配置(App 未同步)→ 不跑") }
        guard config.aiAssistantEnabled else { return skip("AI 主开关关(红线)→ 不跑") }
        guard config.silentBackgroundIndexEnabled else { return skip("静默后台索引未开(opt-in 默认关)→ 不跑") }
        guard config.indexingEnabled else { return skip("后台索引开关关 → 不跑") }
        let level = AIBackgroundActivityLevel(rawValue: config.activityLevel) ?? .balanced
        guard level != .off, let budget = AIArchivePrefetchBudget.forLevel(level) else { return skip("活跃度 off → 不跑") }
        log("配置 OK · 活跃度 \(level.rawValue) · 语言 \(config.languageName)\(force ? " · --force(绕间隔/前台锁)" : "")")

        // 1c. app/agent 互斥:App 在前台活跃(持有前台锁)→ 后台归 App,agent 让位(--force 跳过)。
        if !force, let lockURL = AIForegroundLock.lockURL(appBundleID: AIAgentConfiguration.appBundleID),
           AIForegroundLock.isForegroundAppActive(at: lockURL) {
            return skip("App 在前台活跃(持有前台锁)→ 后台索引归 App,让位")
        }

        // 1b. 间隔自节流:距上次成功跑完不足配置间隔则廉价 no-op(--force 跳过)。
        let now = Date()
        let intervalSeconds = TimeInterval(max(1, config.backgroundIndexIntervalHours)) * 3_600
        if !force, let last = loadLastRun(), now.timeIntervalSince(last) < intervalSeconds {
            let mins = Int(now.timeIntervalSince(last) / 60)
            return skip("距上次后台索引仅 \(mins) 分 < 间隔 \(config.backgroundIndexIntervalHours)h → 跳过")
        }

        // 2. scope 白名单(App 写、agent 读)。
        let scopes = loadScopes()
        guard !scopes.isEmpty else { return skip("白名单为空 → 不跑") }
        log("白名单 \(scopes.count) 个目录")

        // 3. 派生索引 store(显式路径,A19)+ 载入已有索引(渐进覆盖:沿用旧摘要、续扫旧 lastScannedAt)。
        guard let base = appSupportBase() else { return skip("拿不到 App Support 路径") }
        let derived = AIDerivedDataStore(directory: base.appendingPathComponent("AIDerivedData", isDirectory: true))
        var index = loadIndex(from: derived)

        // 4. 渐进覆盖参数(与 App 前台 runIfEnabled 一致)。
        let home = NSHomeDirectory()
        let scopeBudget = max(1, budget.maxDirectoriesPerRound)
        let fileBudget = min(budget.maxEntriesPerArchive, 3_000)
        let allowContent = config.contentPrereadEnabled
        var existingSummarized: [String: AIFileMemoryRecord] = [:]
        if allowContent {
            for rec in index.records where rec.contentSummary != nil { existingSummarized[rec.id] = rec }
        }

        // 5. 元数据扫描(与 App 共用 Core 编排)。单次 timeout 折进停止钩子;到时即停,下次靠 leastRecentlyScanned 续。
        let deadline = now.addingTimeInterval(TimeInterval(max(1, config.maxBackgroundRunSeconds)))
        let isCancelled: () -> Bool = { extraCancel() || Date() >= deadline }
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: home, scopeBudget: scopeBudget, fileBudget: fileBudget,
            allowContent: allowContent, existingSummarized: existingSummarized, isCancelled: isCancelled,
            progress: { event in
                switch event {
                case .willScanScope(let d, let t, let path): log("[\(d + 1)/\(t)] 正在索引 \(path) …")
                case .didScanScope(let d, let t, let path, let n): log("[\(d)/\(t)] \(path) → \(n) 条")
                }
            })
        guard !results.isEmpty else { return skip("本轮未扫(取消/超时立即触发)") }

        // 6. 合并扫描结果进索引(每 scope 先清后 upsert,与 store.ingest 同语义)+ 更新 lastScannedAt。
        var written = 0
        var updatedScopes = scopes
        for r in results {
            index = index.clearingScope(r.scopeID).upserting(r.records, scopeID: r.scopeID, at: now)
            written += r.records.count
            if let i = updatedScopes.firstIndex(where: { $0.id == r.scopeID }) {
                updatedScopes[i] = markScanned(updatedScopes[i], at: now)
            }
        }
        log("元数据 \(results.count) scope · \(written) 条 → 开始模型烘焙")

        // 7. **模型烘焙**:在本进程内直调端上模型预烘焙各 pass(到 deadline 即停,下轮续)。这才是后台 agent 的本职。
        var bakedSummaries = 0
        var bakedURLs = 0
        var bakeNote = "(未烘焙)"
        if #available(macOS 26.0, *) {
            let baked = await AIAgentBaker.bake(index: index, config: config, budget: budget, deadline: deadline, log: log)
            index = baked.index
            bakedSummaries = baked.summary.fileSummaries
            bakedURLs = baked.summary.urlSuggestions
            bakeNote = baked.summary.note
        } else {
            bakeNote = "macOS < 26 → 跳过烘焙"
        }

        // 8. 写回索引 + scope lastScannedAt + 记录本轮跑完时刻(自节流)。
        if let data = try? JSONEncoder().encode(index) {
            derived.set(data, forKey: AppPreferences.Key.aiFileMemoryIndexData)
        }
        saveScopes(updatedScopes)
        saveLastRun(now)
        return RunSummary(scopesScanned: results.count, recordsWritten: written,
                          bakedSummaries: bakedSummaries, bakedURLs: bakedURLs,
                          note: "OK · 烘焙 \(bakeNote)")
    }

    /// 载入已有派生索引(无 / 损坏 → 空索引,首轮从头建)。
    private static func loadIndex(from derived: AIDerivedDataStore) -> AIFileMemoryIndex {
        guard let data = derived.data(forKey: AppPreferences.Key.aiFileMemoryIndexData),
              let decoded = try? JSONDecoder().decode(AIFileMemoryIndex.self, from: data) else {
            return AIFileMemoryIndex()
        }
        return decoded
    }

    /// 返回一个 lastScannedAt 更新后的 scope 副本(AIArchivePrefetchScope 是不可变值类型,整条重建)。
    private static func markScanned(_ s: AIArchivePrefetchScope, at date: Date) -> AIArchivePrefetchScope {
        AIArchivePrefetchScope(
            id: s.id, directoryPath: s.directoryPath, origin: s.origin, recursive: s.recursive,
            maxDepth: s.maxDepth, includeExternalVolumes: s.includeExternalVolumes,
            includeNetworkVolumes: s.includeNetworkVolumes, createdAt: s.createdAt, lastScannedAt: date)
    }
}
