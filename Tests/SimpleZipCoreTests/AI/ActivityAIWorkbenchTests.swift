//
//  ActivityAIWorkbenchTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80: deterministic Activity Center AI workbench cards/chips.
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ActivityAIWorkbenchTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func record(_ id: String,
                        kind: String = "extract",
                        source: String = "app",
                        status: String = "failed",
                        title: String = "Extract app.zip",
                        failure: String? = "ERROR: Permission denied",
                        failureSeen: Bool = false) -> AITaskRecord {
        AITaskRecord.make(
            id: id,
            category: "archive",
            kind: kind,
            source: source,
            status: status,
            title: title,
            startedAt: now.addingTimeInterval(-120),
            finishedAt: now,
            archivePath: "/Users/tester/Downloads/app.zip",
            failureMessage: failure,
            rawOutput: failure,
            home: "/Users/tester",
            canRerun: true,
            failureSeen: failureSeen)
    }

    @Test func summaryCountsVisibleTaskStates() {
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [
            record("failed-unseen", failureSeen: false),
            record("failed-seen", failureSeen: true),
            record("running", status: "running", failure: nil),
            record("ok", status: "succeeded", failure: nil)
        ], now: now)

        #expect(snapshot.schema == "simplezip.ai.activityWorkbench.v1")
        #expect(snapshot.summary.total == 4)
        #expect(snapshot.summary.running == 1)
        #expect(snapshot.summary.failedUnseen == 1)
        #expect(snapshot.summary.failedSeen == 1)
        #expect(snapshot.summary.succeeded == 1)
    }

    @Test func needsAttentionCardReferencesUnseenFailures() {
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [
            record("seen", failureSeen: true),
            record("unseen-new", failureSeen: false),
            record("unseen-old", failureSeen: false)
        ], now: now)

        let card = snapshot.cards.first { $0.kind == .needsAttention }
        #expect(card?.sourceRefs.map(\.id) == ["unseen-new", "unseen-old"])
        #expect(card?.facts.contains("failedUnseen=2") == true)
    }

    @Test func suggestedFilterChipsAreDeterministicAndActionable() {
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [
            record("finder", source: "finder", title: "Extract mods.zip"),
            record("cli-test", kind: "test", source: "cli", title: "Test release.7z",
                   failure: "ERROR: CRC Failed"),
            record("ok", status: "succeeded", failure: nil)
        ], now: now)

        #expect(snapshot.filterChips.map(\.id) == [
            "failed",
            "unseenFailures",
            "finderExtractionFailures",
            "cliVerificationFailures",
            "permissionDenied",
            "checksumMismatch"
        ])
        #expect(snapshot.filterChips.first { $0.id == "finderExtractionFailures" }?.filter.source == "finder")
        #expect(snapshot.filterChips.first { $0.id == "finderExtractionFailures" }?.filter.kindTokens == ["extract"])
        #expect(snapshot.filterChips.first { $0.id == "checksumMismatch" }?.filter.diagnosticTags == ["checksum-mismatch"])
    }

    @Test func emptySnapshotHasOnlyCurrentSummaryCard() {
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [], now: now)

        #expect(snapshot.summary.total == 0)
        #expect(snapshot.cards.map(\.kind) == [.currentListSummary])
        #expect(snapshot.filterChips.isEmpty)
    }

    /// AIRanker 接入验证:任务列表按 严重度(在跑 > 未读失败 > 成功)+ recency(新 > 旧)可解释排序,
    /// 替掉裸时间序。输入故意打乱,期望「需要处理」卡里未读失败按 新→旧。
    @Test func taskListRankedBySeverityThenRecency() {
        func aged(_ id: String, status: String, seen: Bool, ageDays: Int) -> AITaskRecord {
            AITaskRecord.make(
                id: id, category: "archive", kind: "extract", source: "app",
                status: status, title: "Task \(id)",
                startedAt: now.addingTimeInterval(-Double(ageDays) * 86_400 - 60),
                finishedAt: now.addingTimeInterval(-Double(ageDays) * 86_400),
                failureMessage: status == "failed" ? "ERROR: boom" : nil,
                failureSeen: seen)
        }
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [
            aged("old-unseen", status: "failed", seen: false, ageDays: 10),
            aged("ok", status: "succeeded", seen: false, ageDays: 0),
            aged("new-unseen", status: "failed", seen: false, ageDays: 0),
            aged("running", status: "running", seen: false, ageDays: 0)
        ], now: now)
        // running(5+recency) 最高、两个未读失败(4+recency)按 recency 排 new(+3) > old(+0.8)、succeeded 垫底。
        let card = snapshot.cards.first { $0.kind == .needsAttention }
        #expect(card?.sourceRefs.map(\.id) == ["new-unseen", "old-unseen"])
    }
}
