//
//  ActivityAIWorkbench.swift
//  SimpleZip
//
//  0.4.5 #80: deterministic Activity Center AI workbench facts.
//  The workbench is useful without a model: it summarizes the current task
//  slice, surfaces high-value failures, and offers safe filter chips that the
//  App applies through existing Activity Center filtering state.
//

import Foundation

nonisolated struct ActivityAIWorkbenchSummary: Codable, Equatable, Sendable {
    let total: Int
    let running: Int
    let failedUnseen: Int
    let failedSeen: Int
    let succeeded: Int
    let skipped: Int
    let cancelled: Int

    init(records: [AITaskRecord]) {
        self.total = records.count
        self.running = records.filter { $0.status == "running" }.count
        self.failedUnseen = records.filter { $0.status == "failed" && !$0.failureSeen }.count
        self.failedSeen = records.filter { $0.status == "failed" && $0.failureSeen }.count
        self.succeeded = records.filter { $0.status == "succeeded" }.count
        self.skipped = records.filter { $0.status == "skipped" }.count
        self.cancelled = records.filter { $0.status == "cancelled" }.count
    }
}

nonisolated struct ActivityAIWorkbenchFilterSpec: Codable, Equatable, Sendable {
    let status: String?
    let source: String?
    let kindTokens: [String]
    let diagnosticTags: [String]
    /// 建议六 v2 时间维度:筛「最近 N 秒内」(如 86400=今天 / 604800=本周)。nil = 不限时间。App 据此设 aiWithinSeconds。
    let timeWindowSeconds: Int?

    init(status: String? = nil, source: String? = nil, kindTokens: [String] = [],
         diagnosticTags: [String] = [], timeWindowSeconds: Int? = nil) {
        self.status = status
        self.source = source
        self.kindTokens = kindTokens
        self.diagnosticTags = diagnosticTags
        self.timeWindowSeconds = timeWindowSeconds
    }
}

nonisolated struct ActivityAIWorkbenchFilterChip: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let filter: ActivityAIWorkbenchFilterSpec
    let sourceRefs: [AIContextSourceRef]
    let facts: [String]
    /// 建议六 v2「真建议」:模型给真实聚集起的自然语言名(如"从 Finder 解压失败的 4 个")。
    /// nil = 写死 chip(前台用 L10n id 显示);非 nil = AI 命名的聚集 chip(前台直接显示这个名字)。
    let displayName: String?

    init(id: String, filter: ActivityAIWorkbenchFilterSpec,
         sourceRefs: [AIContextSourceRef] = [], facts: [String] = [], displayName: String? = nil) {
        self.id = id
        self.filter = filter
        self.sourceRefs = sourceRefs
        self.facts = facts
        self.displayName = displayName
    }
}

/// 建议六 v2「真建议筛选」的候选:一个**从真实任务数据里发现的显著聚集**(任意维度交叉,达数量阈值),
/// 不是写死的 12 个维度组合。`filter` = 点它要应用的安全 filter(App 确定性匹配);`matchCount` = 命中数;
/// `dimensionFacts` = 喂模型命名用的英文维度描述(不含敏感路径)。模型只在这些**真实聚集**上择优 + 起自然语言名
/// (如"今天从 Finder 解压失败的 4 个")—— 模型不扫列表选行,只命名 App 发现的真实聚集(守拒绝假AI)。
nonisolated struct AIWorkbenchCluster: Codable, Equatable, Sendable {
    let filter: ActivityAIWorkbenchFilterSpec
    let matchCount: Int
    let sampleRefs: [AIContextSourceRef]
    let dimensionFacts: [String]
}

nonisolated struct ActivityAIWorkbenchCard: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case currentListSummary
        case needsAttention
    }

    let id: String
    let kind: Kind
    let sourceRefs: [AIContextSourceRef]
    let facts: [String]

    init(id: String, kind: Kind, sourceRefs: [AIContextSourceRef] = [], facts: [String] = []) {
        self.id = id
        self.kind = kind
        self.sourceRefs = sourceRefs
        self.facts = facts
    }
}

nonisolated struct ActivityAIWorkbenchSnapshot: Codable, Equatable, Sendable {
    let schema: String
    let summary: ActivityAIWorkbenchSummary
    let cards: [ActivityAIWorkbenchCard]
    let filterChips: [ActivityAIWorkbenchFilterChip]
    let omissions: [AIContextOmission]

    init(schema: String = ActivityAIWorkbenchBuilder.schema,
         summary: ActivityAIWorkbenchSummary,
         cards: [ActivityAIWorkbenchCard],
         filterChips: [ActivityAIWorkbenchFilterChip],
         omissions: [AIContextOmission] = []) {
        self.schema = schema
        self.summary = summary
        self.cards = cards
        self.filterChips = filterChips
        self.omissions = omissions
    }
}

/// 建议六 v2「学习到的习惯」:近期任务的常用模式摘要(来源 / 格式 / 位置 token,按频次)。**只摘要、不含完整
/// 路径**(位置只到低敏类别 token 如 downloads;格式是扩展名)。前台用现成 L10n 显示名渲染。
nonisolated struct ActivityWorkbenchHabits: Codable, Equatable, Sendable {
    let topSources: [String]
    let topFormats: [String]
    let topLocations: [String]
    let taskCount: Int

    var isEmpty: Bool { topSources.isEmpty && topFormats.isEmpty && topLocations.isEmpty }
}

/// 建议六 v2「自动化建议」:某「手动来源 × 操作」组合稳定重复(达阈值)时,提示可用快捷指令 / 命令行自动化。
/// 只看**手动**来源(app / finder);已经是自动化的来源(intent / cli / urlScheme)不再建议。确定性、可单测。
nonisolated struct ActivityWorkbenchAutomationHint: Codable, Equatable, Sendable {
    let source: String
    let kind: String
    let count: Int
}

/// 建议六 v2「AI 推荐时间维度」:一个时间带(今天 / 本周 / 本月)的活动事实。**独立于建议筛选 chip**——
/// 时间维度和建议筛选可同时生效(双重叠加),所以它不是 chip,而是单独一组可切换的时间带。`recommended`
/// = 工作台标「值得关注」(确定性发现:有未读失败的最窄带 → 最近且可处理)。前台用现成 L10n 显示名渲染。
nonisolated struct ActivityWorkbenchTimeBand: Codable, Equatable, Identifiable, Sendable {
    /// 稳定英文 token(`today` / `thisWeek` / `thisMonth`),前台映射 L10n 显示名。
    let id: String
    /// 时间窗秒数(App 据此设独立的时间筛选 cutoff)。
    let seconds: Int
    /// 落在该窗口内的任务数(近期任务切片内)。
    let taskCount: Int
    /// 该窗口内未读失败数(驱动「值得关注」推荐)。
    let failedUnseen: Int
    /// 工作台「值得关注」标记(确定性)。
    let recommended: Bool

    func markingRecommended() -> ActivityWorkbenchTimeBand {
        ActivityWorkbenchTimeBand(id: id, seconds: seconds, taskCount: taskCount,
                                  failedUnseen: failedUnseen, recommended: true)
    }
}

nonisolated enum ActivityAIWorkbenchBuilder {
    static let schema = "simplezip.ai.activityWorkbench.v1"

    /// 默认排序是**确定性、廉价的**:running 置顶,其余按时间倒序(新→旧)。**不接 AI** —— 默认视图根本
    /// 不需要 AI 排序(那既蠢又是 render 热路径性能灾难)。AI 排序只属于 AI 主导的输出(真建议 / 搜索筛选结果),
    /// 不在这里。cards/chips 沿用这个顺序,不再各自重排。
    static func snapshot(records: [AITaskRecord], limit: Int = 50) -> ActivityAIWorkbenchSnapshot {
        let effectiveLimit = max(0, limit)
        let ranked = records.sorted(by: defaultOrder)
        let kept = Array(ranked.prefix(effectiveLimit))
        var omissions: [AIContextOmission] = []
        if ranked.count > kept.count {
            omissions.append(.truncated(
                type: "activity_workbench_tasks",
                omitted: ranked.count - kept.count,
                reason: "candidate_budget"))
        }
        let summary = ActivityAIWorkbenchSummary(records: kept)
        return ActivityAIWorkbenchSnapshot(
            summary: summary,
            cards: cards(summary: summary, records: kept),
            filterChips: filterChips(records: kept),
            omissions: omissions)
    }

    /// 默认任务排序(确定性、廉价、**不接 AI**):running 置顶,其余按完成 / 开始时间倒序(新→旧),tie 按 id。
    /// 纯字符串 / 布尔比较,无脱敏、无正则、无 formatter —— 可放在任何 render 路径。
    private static func defaultOrder(_ lhs: AITaskRecord, _ rhs: AITaskRecord) -> Bool {
        let lRunning = lhs.status == "running", rRunning = rhs.status == "running"
        if lRunning != rRunning { return lRunning }
        let left = lhs.finishedAt ?? lhs.startedAt ?? ""
        let right = rhs.finishedAt ?? rhs.startedAt ?? ""
        if left != right { return left > right }
        return lhs.id < rhs.id
    }

    private static func cards(summary: ActivityAIWorkbenchSummary,
                              records: [AITaskRecord]) -> [ActivityAIWorkbenchCard] {
        var cards = [
            ActivityAIWorkbenchCard(
                id: "currentListSummary",
                kind: .currentListSummary,
                facts: summaryFacts(summary))
        ]
        // records 已由 snapshot 确定性排序(running 置顶 + 时间序);未读失败保持该顺序,不再各自重排。
        let unseenFailed = records.filter { $0.status == "failed" && !$0.failureSeen }
        if !unseenFailed.isEmpty {
            cards.append(ActivityAIWorkbenchCard(
                id: "needsAttention",
                kind: .needsAttention,
                sourceRefs: sourceRefs(unseenFailed, limit: 3),
                facts: ["failedUnseen=\(unseenFailed.count)"]))
        }
        return cards
    }

    private static func filterChips(records: [AITaskRecord]) -> [ActivityAIWorkbenchFilterChip] {
        // records 已确定性排序;failed 子集保持该时间序(chip 的 sourceRefs 取最近的几个)。
        let failed = records.filter { $0.status == "failed" }
        guard !failed.isEmpty else { return [] }
        var chips: [ActivityAIWorkbenchFilterChip] = [
            chip(id: "failed", records: failed, filter: .init(status: "failed"))
        ]
        let unseen = failed.filter { !$0.failureSeen }
        if !unseen.isEmpty {
            chips.append(chip(id: "unseenFailures", records: unseen, filter: .init(status: "failed")))
        }
        let finderExtract = failed.filter { $0.source == "finder" && $0.kind == "extract" }
        if !finderExtract.isEmpty {
            chips.append(chip(
                id: "finderExtractionFailures",
                records: finderExtract,
                filter: .init(status: "failed", source: "finder", kindTokens: ["extract"])))
        }
        let verificationKinds = ["compare", "hash", "inspect", "test"]
        let cliVerify = failed.filter { $0.source == "cli" && verificationKinds.contains($0.kind) }
        if !cliVerify.isEmpty {
            chips.append(chip(
                id: "cliVerificationFailures",
                records: cliVerify,
                filter: .init(status: "failed", source: "cli", kindTokens: verificationKinds)))
        }
        // 按操作类型补齐常见失败入口(不限来源)—— 覆盖 app / cli 的 创建 / 压缩 / 转换 失败:
        // 之前只有 finder+extract 和 cli 校验类有专属 chip,app/cli 创建、cli 压缩、转换等无入口(BUG-W8)。
        // 解压不另加通用 chip —— finderExtractionFailures 已覆盖最常见的 Finder 自动解压失败,通用 extract chip
        // 会与之重复(同一条 finder 解压失败出现在两个 chip 里)。app/cli 纯解压失败暂仍走「全部失败」总入口。
        for entry in [("creationFailures", "create"),
                      ("compressionFailures", "compress"), ("conversionFailures", "convert")] {
            let matched = failed.filter { $0.kind == entry.1 }
            if !matched.isEmpty {
                chips.append(chip(id: entry.0, records: matched,
                                  filter: .init(status: "failed", kindTokens: [entry.1])))
            }
        }
        // 自动化失败(Shortcuts / Siri = intent 来源)。
        let automation = failed.filter { $0.source == "intent" }
        if !automation.isEmpty {
            chips.append(chip(id: "automationFailures", records: automation,
                              filter: .init(status: "failed", source: "intent")))
        }
        for tag in ["permission-denied", "missing-volume", "checksum-mismatch"] {
            let tagged = failed.filter { $0.diagnostics.tags.contains(tag) }
            if !tagged.isEmpty {
                chips.append(chip(
                    id: chipID(forDiagnosticTag: tag),
                    records: tagged,
                    filter: .init(status: "failed", diagnosticTags: [tag])))
            }
        }
        return chips
    }

    /// 建议六 v2「真建议」候选发现:对失败任务按 source × kind × tag 的单维 + 双维交叉计数,保留达阈值
    /// (≥minCount)的**真实聚集**,同成员集去冗余(双维先枚举 → 更具体的优先留)。这是"真建议"的候选池 ——
    /// 来自真实数据、任意交叉,不是写死维度;后台 pass 让模型在这些真实聚集上**择优 + 自然语言命名**。
    /// 确定性、可单测;模型不扫列表选行,只命名 App 发现的真实聚集(守拒绝假AI)。
    static func discoverClusters(records: [AITaskRecord],
                                 minCount: Int = 2, limit: Int = 24) -> [AIWorkbenchCluster] {
        let failed = records.filter { $0.status == "failed" }
        guard records.count >= minCount else { return [] }   // 全状态:无任务才退;失败聚集 + 全状态高频聚集都发现
        var seenMembers = Set<String>()
        var clusters: [AIWorkbenchCluster] = []
        func add(_ filter: ActivityAIWorkbenchFilterSpec, _ matched: [AITaskRecord], _ facts: [String], min: Int = minCount) {
            guard matched.count >= min else { return }
            let memberKey = matched.map(\.id).sorted().joined(separator: ",")
            guard seenMembers.insert(memberKey).inserted else { return }   // 同成员集只留先来的(双维先=更具体)
            clusters.append(AIWorkbenchCluster(
                filter: filter, matchCount: matched.count,
                sampleRefs: matched.prefix(5).map { AIContextSourceRef(kind: .task, id: $0.id) },
                dimensionFacts: facts))
        }
        let sources = Set(failed.map(\.source)).sorted()
        let kinds = Set(failed.map(\.kind)).sorted()
        let tags = Set(failed.flatMap { $0.diagnostics.tags }).sorted()
        // 双维先枚举(更具体 → 同成员集时优先保留它的具体 filter / 命名)。
        for s in sources { for k in kinds {
            add(.init(status: "failed", source: s, kindTokens: [k]),
                failed.filter { $0.source == s && $0.kind == k }, ["source=\(s)", "kind=\(k)"])
        }}
        for s in sources { for t in tags {
            add(.init(status: "failed", source: s, diagnosticTags: [t]),
                failed.filter { $0.source == s && $0.diagnostics.tags.contains(t) }, ["source=\(s)", "tag=\(t)"])
        }}
        for k in kinds { for t in tags {
            add(.init(status: "failed", kindTokens: [k], diagnosticTags: [t]),
                failed.filter { $0.kind == k && $0.diagnostics.tags.contains(t) }, ["kind=\(k)", "tag=\(t)"])
        }}
        // 单维(较通用)补充。
        for s in sources { add(.init(status: "failed", source: s), failed.filter { $0.source == s }, ["source=\(s)"]) }
        for k in kinds { add(.init(status: "failed", kindTokens: [k]), failed.filter { $0.kind == k }, ["kind=\(k)"]) }
        for t in tags { add(.init(status: "failed", diagnosticTags: [t]), failed.filter { $0.diagnostics.tags.contains(t) }, ["tag=\(t)"]) }
        // 全状态高频聚集(不只失败 → 无 / 少失败时工作台也有丰富真建议):按 kind / source 的常用操作组,阈值更高
        // (成功任务多,避免噪声)、filter 不带 status = 全状态(如"所有压缩任务""Downloads 来源的任务")。
        let bulkMin = max(minCount, 3)
        for k in Set(records.map(\.kind)).sorted() {
            add(.init(kindTokens: [k]), records.filter { $0.kind == k }, ["kind=\(k)"], min: bulkMin)
        }
        for s in Set(records.map(\.source)).sorted() {
            add(.init(source: s), records.filter { $0.source == s }, ["source=\(s)"], min: bulkMin)
        }
        // 时间维度**不再内嵌进聚集 chip** —— 它是独立的一组可切换时间带(`timeDimensions`),与建议筛选 chip
        // 双重叠加(用户可同时选「今天」+「从 Finder 解压失败的」)。内嵌会和独立维度冲突,故移走。
        // 命中多优先,同命中数双维(更具体)优先;cap。
        return Array(clusters
            .sorted { ($0.matchCount, $0.dimensionFacts.count) > ($1.matchCount, $1.dimensionFacts.count) }
            .prefix(limit))
    }

    /// 建议六 v2「学习到的习惯」:从近期任务确定性算常用来源 / 格式 / 位置(按频次取 top N)。**只摘要、不含
    /// 完整路径**(来源 token / 扩展名 / 位置类别 token)。确定性、可单测。
    static func habitSummary(records: [AITaskRecord], limit: Int = 3) -> ActivityWorkbenchHabits {
        func top(_ values: [String]) -> [String] {
            var counts: [String: Int] = [:]
            for v in values where !v.isEmpty { counts[v, default: 0] += 1 }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit).map(\.key)
        }
        return ActivityWorkbenchHabits(
            topSources: top(records.map(\.source)),
            topFormats: top(records.compactMap { $0.files.archiveExtension }),
            topLocations: top(records.flatMap { $0.files.locationKinds }),
            taskCount: records.count)
    }

    /// 建议六 v2「自动化建议」:找重复最稳定的「手动来源 × 操作」组合(达阈值)→ 提示自动化。只看手动来源
    /// (app / finder);intent / cli / urlScheme 本就是自动化,排除。无达阈值组合 → nil。
    static func automationHint(records: [AITaskRecord], minCount: Int = 5) -> ActivityWorkbenchAutomationHint? {
        let manual = records.filter { $0.source == "app" || $0.source == "finder" }
        guard manual.count >= minCount else { return nil }
        var counts: [String: (source: String, kind: String, n: Int)] = [:]
        for r in manual {
            let key = "\(r.source)|\(r.kind)"
            var entry = counts[key] ?? (r.source, r.kind, 0)
            entry.n += 1
            counts[key] = entry
        }
        guard let top = counts.values
            .filter({ $0.n >= minCount })
            .sorted(by: { $0.n != $1.n ? $0.n > $1.n : "\($0.source)|\($0.kind)" < "\($1.source)|\($1.kind)" })
            .first else { return nil }
        return ActivityWorkbenchAutomationHint(source: top.source, kind: top.kind, count: top.n)
    }

    /// 建议六 v2「AI 推荐时间维度」:把近期任务切片确定性分到今天 / 本周 / 本月三带,标出**值得关注**的那带
    /// (有未读失败的最窄带 = 最近且可处理)。无任务落入某带则不返回它;全无失败 → 不推荐任何带(纯导航维度)。
    /// **独立于建议筛选**,前台可双重叠加。`now` 由 App 传(本层不取时钟)。确定性、可单测。
    static func timeDimensions(records: [AITaskRecord], now: Date) -> [ActivityWorkbenchTimeBand] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // 每条只解析一次时间戳(render 路径友好)。
        let dated: [(date: Date, unseenFail: Bool)] = records.compactMap { r in
            guard let stamp = r.finishedAt ?? r.startedAt, let date = formatter.date(from: stamp) else { return nil }
            return (date, r.status == "failed" && !r.failureSeen)
        }
        let bands: [(id: String, window: AITimeWindow)] = [
            ("today", .last24Hours), ("thisWeek", .last7Days), ("thisMonth", .last30Days)
        ]
        var result: [ActivityWorkbenchTimeBand] = []
        for band in bands {
            let inWindow = dated.filter { band.window.contains($0.date, now: now) }
            guard !inWindow.isEmpty else { continue }
            result.append(ActivityWorkbenchTimeBand(
                id: band.id, seconds: band.window.seconds,
                taskCount: inWindow.count, failedUnseen: inWindow.filter(\.unseenFail).count,
                recommended: false))
        }
        // 推荐「值得关注」= 有未读失败的最窄带(seconds 最小)。无失败 → 不推荐。
        if let target = result.filter({ $0.failedUnseen > 0 }).min(by: { $0.seconds < $1.seconds }) {
            result = result.map { $0.id == target.id ? $0.markingRecommended() : $0 }
        }
        return result
    }

    private static func chip(id: String, records: [AITaskRecord],
                             filter: ActivityAIWorkbenchFilterSpec) -> ActivityAIWorkbenchFilterChip {
        ActivityAIWorkbenchFilterChip(
            id: id,
            filter: filter,
            sourceRefs: sourceRefs(records, limit: 5),
            facts: ["matches=\(records.count)"])
    }

    private static func sourceRefs(_ records: [AITaskRecord], limit: Int) -> [AIContextSourceRef] {
        records.prefix(limit).map { AIContextSourceRef(kind: .task, id: $0.id) }
    }

    private static func summaryFacts(_ summary: ActivityAIWorkbenchSummary) -> [String] {
        [
            "total=\(summary.total)",
            "running=\(summary.running)",
            "failedUnseen=\(summary.failedUnseen)",
            "failedSeen=\(summary.failedSeen)",
            "succeeded=\(summary.succeeded)",
            "skipped=\(summary.skipped)",
            "cancelled=\(summary.cancelled)"
        ]
    }

    private static func chipID(forDiagnosticTag tag: String) -> String {
        switch tag {
        case "permission-denied": return "permissionDenied"
        case "missing-volume": return "missingVolume"
        case "checksum-mismatch": return "checksumMismatch"
        default: return tag
        }
    }
}

// MARK: - 工作台预烘焙缓存键 + 派生值(独立 AI 进程改造:从 AIBackgroundIndexer 抽进 Core)
//
// 这些是**纯确定性**的指纹 / 稳定 id / chip 派生值。白皮书反复强调「**两边必须用同一函数**」:agent 的后台预烘焙
// pass 用它们算缓存 key、前台(ActivityView)用同一函数判断缓存是否仍匹配当前输入才套用。agent 调不到 app-target
// 的 `AIBackgroundIndexer`,故放进 Core 共享 —— 是「确定性逻辑 → Core」,不是「AI 后端」。
enum ActivityAIWorkbenchKeys {
    /// chip 池指纹:chip id + 匹配数(池构成或计数变了才重排;否则幂等跳过)。
    nonisolated static func chipPoolFingerprint(_ chips: [ActivityAIWorkbenchFilterChip]) -> String {
        chips.map { "\($0.id):\(chipMatchCount($0))" }.joined(separator: "|")
    }

    /// chip 的匹配任务数(从 facts 的 "matches=N" 抽)。
    nonisolated static func chipMatchCount(_ chip: ActivityAIWorkbenchFilterChip) -> Int {
        let prefix = "matches="
        for fact in chip.facts where fact.hasPrefix(prefix) { return Int(fact.dropFirst(prefix.count)) ?? 0 }
        return 0
    }

    /// chip 的英文语义描述(喂模型用;由 filter 维度拼,**不含敏感路径**)。
    nonisolated static func chipPromptLabel(_ chip: ActivityAIWorkbenchFilterChip) -> String {
        var dims: [String] = []
        let f = chip.filter
        if let status = f.status { dims.append("status=\(status)") }
        if let source = f.source { dims.append("source=\(source)") }
        if !f.kindTokens.isEmpty { dims.append("kind=\(f.kindTokens.joined(separator: "/"))") }
        if !f.diagnosticTags.isEmpty { dims.append("tags=\(f.diagnosticTags.joined(separator: "/"))") }
        return "\(chip.id) — \(dims.isEmpty ? chip.id : dims.joined(separator: ", "))"
    }

    /// 某分类的「未读失败任务集」指纹(未读失败任务 id 排序后 join)。后台据此决定是否重生成「需要处理」解读、
    /// 前台据此判断缓存是否匹配当前列表 —— **两边必须用同一函数**,保证幂等且不显示旧任务的解读。
    nonisolated static func needsAttentionFingerprint(_ records: [AITaskRecord]) -> String {
        records.filter { $0.status == "failed" && !$0.failureSeen }
            .map(\.id).sorted().joined(separator: ",")
    }

    /// 某失败任务的脱敏诊断指纹(类型 / 来源 / 标签 / 脱敏失败消息 / 脱敏错误行)。后台据此决定是否重生成失败解释、
    /// 前台据此判断缓存是否仍对应该任务当前的失败态 —— **两边用同一函数**。**全部已脱敏,无原始路径。**
    nonisolated static func failureExplanationFingerprint(_ record: AITaskRecord) -> String {
        let diag = record.diagnostics
        var parts = ["\(record.kind)|\(record.source)|\(diag.tags.sorted().joined(separator: "+"))"]
        if let message = diag.failureMessage, !message.isEmpty { parts.append(message) }
        if !diag.errorLines.isEmpty { parts.append(diag.errorLines.joined(separator: "\n")) }
        return AIStableHash.stableID64(parts.joined(separator: "\u{1f}"))
    }

    /// 真实聚集池指纹:每个聚集的 filter 维度 id + 命中数(构成或计数变了才重命名;否则幂等跳过)。
    nonisolated static func clusterFingerprint(_ clusters: [AIWorkbenchCluster]) -> String {
        clusters.map { "\(clusterChipID($0.filter)):\($0.matchCount)" }.joined(separator: "|")
    }

    /// 真建议 chip 的稳定 id(从 filter 维度拼,前台据此去重写死 chip + 应用 filter)。
    nonisolated static func clusterChipID(_ filter: ActivityAIWorkbenchFilterSpec) -> String {
        var parts = ["cluster"]
        if let status = filter.status { parts.append("st-\(status)") }
        if let source = filter.source { parts.append("so-\(source)") }
        if !filter.kindTokens.isEmpty { parts.append("k-\(filter.kindTokens.sorted().joined(separator: "+"))") }
        if !filter.diagnosticTags.isEmpty { parts.append("t-\(filter.diagnosticTags.sorted().joined(separator: "+"))") }
        if let window = filter.timeWindowSeconds { parts.append("tw-\(window)") }
        return parts.joined(separator: "_")
    }
}
