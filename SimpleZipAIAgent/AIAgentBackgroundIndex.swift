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
        let note: String
    }

    /// App 共享的 Application Support 子目录(`<App Support>/<App bundle id>/`)。A19:不靠 Bundle.main。
    private static func appSupportBase() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(AIAgentConfiguration.appBundleID, isDirectory: true)
    }

    /// 读 App 写的 scope 白名单(偏好域 = App bundle id;A19 用 suiteName 读对域,不用 agent 自己的 .standard)。
    private static func loadScopes() -> [AIArchivePrefetchScope] {
        guard let defaults = UserDefaults(suiteName: AIAgentConfiguration.appBundleID),
              let data = defaults.data(forKey: AppPreferences.Key.aiBackgroundIndexScopes),
              let scopes = try? JSONDecoder().decode([AIArchivePrefetchScope].self, from: data) else { return [] }
        return scopes
    }

    /// 写回 scope 白名单(只为更新 lastScannedAt → 下轮 leastRecentlyScanned 续扫)。互斥由 app/agent 让位保证(下一刀)。
    private static func saveScopes(_ scopes: [AIArchivePrefetchScope]) {
        guard let defaults = UserDefaults(suiteName: AIAgentConfiguration.appBundleID),
              let data = try? JSONEncoder().encode(scopes) else { return }
        defaults.set(data, forKey: AppPreferences.Key.aiBackgroundIndexScopes)
    }

    /// 跑一轮后台索引(同步)。`isCancelled` = 唯一停止钩子,调用方把单次 timeout 折进它(`{ Date() >= 截止 }`)。
    static func runOnce(isCancelled: () -> Bool = { false }) -> RunSummary {
        func skip(_ note: String) -> RunSummary { RunSummary(scopesScanned: 0, recordsWritten: 0, note: note) }

        // 1. 配置门控(红线主开关 + 静默后台 opt-in + 后台索引开关 + 活跃度)。
        guard let config = AIAgentConfiguration.loadPersisted() else { return skip("无配置(App 未同步)→ 不跑") }
        guard config.aiAssistantEnabled else { return skip("AI 主开关关(红线)→ 不跑") }
        guard config.silentBackgroundIndexEnabled else { return skip("静默后台索引未开(opt-in 默认关)→ 不跑") }
        guard config.indexingEnabled else { return skip("后台索引开关关 → 不跑") }
        let level = AIBackgroundActivityLevel(rawValue: config.activityLevel) ?? .balanced
        guard level != .off, let budget = AIArchivePrefetchBudget.forLevel(level) else { return skip("活跃度 off → 不跑") }

        // 2. scope 白名单(App 写、agent 读)。
        let scopes = loadScopes()
        guard !scopes.isEmpty else { return skip("白名单为空 → 不跑") }

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

        // 5. 扫描(与 App 共用 Core 编排;timeout 折进 isCancelled)。
        let results = AIBackgroundIndexRun.scan(
            scopes: scopes, home: home, scopeBudget: scopeBudget, fileBudget: fileBudget,
            allowContent: allowContent, existingSummarized: existingSummarized, isCancelled: isCancelled)
        guard !results.isEmpty else { return skip("本轮未扫(取消/超时立即触发)") }

        // 6. 写回索引(每 scope 先清后 upsert,与 store.ingest 同语义)+ 更新 lastScannedAt。
        let now = Date()
        var written = 0
        var updatedScopes = scopes
        for r in results {
            index = index.clearingScope(r.scopeID).upserting(r.records, scopeID: r.scopeID, at: now)
            written += r.records.count
            if let i = updatedScopes.firstIndex(where: { $0.id == r.scopeID }) {
                updatedScopes[i] = markScanned(updatedScopes[i], at: now)
            }
        }
        if let data = try? JSONEncoder().encode(index) {
            derived.set(data, forKey: AppPreferences.Key.aiFileMemoryIndexData)
        }
        saveScopes(updatedScopes)
        return RunSummary(scopesScanned: results.count, recordsWritten: written, note: "OK")
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
