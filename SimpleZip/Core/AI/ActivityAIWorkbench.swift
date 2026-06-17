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

    static func snapshot(records: [AITaskRecord], limit: Int = 50) -> ActivityAIWorkbenchSnapshot {
        let effectiveLimit = max(0, limit)
        let sorted = records.sorted(by: isNewer)
        let kept = Array(sorted.prefix(effectiveLimit))
        var omissions: [AIContextOmission] = []
        if sorted.count > kept.count {
            omissions.append(.truncated(
                type: "activity_workbench_tasks",
                omitted: sorted.count - kept.count,
                reason: "candidate_budget"))
        }
        let summary = ActivityAIWorkbenchSummary(records: kept)
        return ActivityAIWorkbenchSnapshot(
            summary: summary,
            cards: cards(summary: summary, records: kept),
            filterChips: filterChips(records: kept),
            omissions: omissions)
    }

    private static func cards(summary: ActivityAIWorkbenchSummary,
                              records: [AITaskRecord]) -> [ActivityAIWorkbenchCard] {
        var cards = [
            ActivityAIWorkbenchCard(
                id: "currentListSummary",
                kind: .currentListSummary,
                facts: summaryFacts(summary))
        ]
        let unseenFailed = records
            .filter { $0.status == "failed" && !$0.failureSeen }
            .sorted(by: isNewer)
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
        let failed = records.filter { $0.status == "failed" }.sorted(by: isNewer)
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

    private static func isNewer(_ lhs: AITaskRecord, _ rhs: AITaskRecord) -> Bool {
        let left = lhs.finishedAt ?? lhs.startedAt ?? ""
        let right = rhs.finishedAt ?? rhs.startedAt ?? ""
        if left != right { return left > right }
        return lhs.id < rhs.id
    }
}
