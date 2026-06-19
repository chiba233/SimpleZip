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

    init(status: String? = nil, source: String? = nil, kindTokens: [String] = [], diagnosticTags: [String] = []) {
        self.status = status
        self.source = source
        self.kindTokens = kindTokens
        self.diagnosticTags = diagnosticTags
    }
}

nonisolated struct ActivityAIWorkbenchFilterChip: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let filter: ActivityAIWorkbenchFilterSpec
    let sourceRefs: [AIContextSourceRef]
    let facts: [String]

    init(id: String, filter: ActivityAIWorkbenchFilterSpec,
         sourceRefs: [AIContextSourceRef] = [], facts: [String] = []) {
        self.id = id
        self.filter = filter
        self.sourceRefs = sourceRefs
        self.facts = facts
    }
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

nonisolated enum ActivityAIWorkbenchBuilder {
    static let schema = "simplezip.ai.activityWorkbench.v1"

    /// `now` 由 App 传(Core 不自取时钟):任务列表用统一 `AIRanker` 排序 —— 状态严重度(在跑 > 未读失败 >
    /// 已读失败 > 取消)+ recency(`AIAgeFacts` 年龄桶),可解释 decision。同分按输入序(越新越上)稳定兜底。
    /// 替掉原来的裸 `isNewer` 时间序;cards/chips 沿用排好序的结果,不再各自重排。
    static func snapshot(records: [AITaskRecord], limit: Int = 50, now: Date) -> ActivityAIWorkbenchSnapshot {
        let effectiveLimit = max(0, limit)
        let ranked = AIRanker.rank(records) { taskRankingContext($0, now: now) }.map(\.item)
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

    /// 一个任务的排序上下文(喂 `AIRanker`):**确定性、可解释**。状态严重度给基础权重,recency 给时间衰减。
    /// 后续可追加全局记忆信号(负反馈降权 / 兴趣 boost)—— 那是闭环的下一环,本刀先确定性。
    private static func taskRankingContext(_ r: AITaskRecord, now: Date) -> AIRankingContext {
        var signals: [AIRankingSignal] = []
        switch r.status {
        case "running":
            signals.append(.boost("running", 5, reason: "in-progress"))
        case "failed":
            signals.append(r.failureSeen
                ? .boost("failed-seen", 1, reason: "failed")
                : .boost("failed-unseen", 4, reason: "unseen-failure"))
        case "cancelled":
            signals.append(.demote("cancelled", 0.5, reason: "cancelled"))
        default:
            break   // succeeded / skipped:仅 recency,不加严重度
        }
        if let stamp = r.finishedAt ?? r.startedAt, let date = parseISO(stamp) {
            let age = AIAgeFacts.make(from: date, now: now)
            signals.append(.boost("recency", recencyWeight(age.bucket), reason: age.bucket.rawValue))
        }
        return AIRankingContext(base: 0, signals: signals)
    }

    /// 年龄桶 → recency 权重(越新越高)。
    private static func recencyWeight(_ bucket: AIAgeFacts.Bucket) -> Double {
        switch bucket {
        case .justNow: return 3
        case .today: return 2.5
        case .thisWeek: return 1.5
        case .thisMonth: return 0.8
        case .thisQuarter: return 0.3
        case .stale: return 0
        }
    }

    private static func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func cards(summary: ActivityAIWorkbenchSummary,
                              records: [AITaskRecord]) -> [ActivityAIWorkbenchCard] {
        var cards = [
            ActivityAIWorkbenchCard(
                id: "currentListSummary",
                kind: .currentListSummary,
                facts: summaryFacts(summary))
        ]
        // records 已由 snapshot 经 AIRanker 排好序(未读失败靠前);这里保持其顺序,不再各自重排。
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
        // records 已经过 AIRanker 排序;failed 子集保持该顺序(chip 的 sourceRefs 取前若干即最值得先看的)。
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
