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
        ])

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
        ])

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
        ])

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
        let snapshot = ActivityAIWorkbenchBuilder.snapshot(records: [])

        #expect(snapshot.summary.total == 0)
        #expect(snapshot.cards.map(\.kind) == [.currentListSummary])
        #expect(snapshot.filterChips.isEmpty)
    }

    /// 默认排序确定性(不接 AI):running 置顶,其余按时间倒序(新→旧)。输入故意打乱,
    /// 期望「需要处理」卡里未读失败按 新→旧(时间序)。
    @Test func taskListSortsRunningFirstThenNewest() {
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
        ])
        // running 置顶;其余按时间倒序,未读失败 new(刚刚) > old(10天前);succeeded 不进「需要处理」。
        let card = snapshot.cards.first { $0.kind == .needsAttention }
        #expect(card?.sourceRefs.map(\.id) == ["new-unseen", "old-unseen"])
    }

    /// 建议六 v2「真建议」候选发现:从真实数据按维度交叉聚集(不是写死维度),同成员集去冗余。
    @Test func discoverClustersFindsRealCrossDimensionGroupsDeduped() {
        func f(_ id: String, source: String, kind: String, fail: String) -> AITaskRecord {
            AITaskRecord.make(id: id, category: "archive", kind: kind, source: source, status: "failed",
                              title: "T \(id)", startedAt: now, finishedAt: now,
                              failureMessage: fail, rawOutput: fail)
        }
        let records = [
            f("a", source: "finder", kind: "extract", fail: "ERROR: Permission denied"),
            f("b", source: "finder", kind: "extract", fail: "ERROR: Permission denied"),
            f("c", source: "finder", kind: "extract", fail: "ERROR: Permission denied"),
            f("d", source: "finder", kind: "extract", fail: "ERROR: Permission denied"),
            f("e", source: "cli", kind: "test", fail: "ERROR: CRC Failed"),
            f("g", source: "cli", kind: "test", fail: "ERROR: CRC Failed")
        ]
        let clusters = ActivityAIWorkbenchBuilder.discoverClusters(records: records)
        // 真实聚集:finder×extract(4) 最大、cli×test(2);同成员集去冗余(不重复冒 finder×permission / 单维 等)。
        #expect(clusters.count == 2)
        #expect(clusters[0].matchCount == 4)
        #expect(clusters[0].filter.source == "finder")
        #expect(clusters[1].matchCount == 2)
        #expect(clusters[1].filter.source == "cli")
        // 单个孤立失败(< 阈值)不成聚集。
        let lonely = ActivityAIWorkbenchBuilder.discoverClusters(records: [f("x", source: "app", kind: "create", fail: "ERROR: boom")])
        #expect(lonely.isEmpty)
    }

    /// 建议六 v2「学习到的习惯」:确定性算常用来源 / 格式 / 位置(按频次)。
    @Test func habitSummaryRanksTopPatterns() {
        func r(_ id: String, source: String, archive: String) -> AITaskRecord {
            AITaskRecord.make(id: id, category: "archive", kind: "extract", source: source, status: "succeeded",
                              title: "T", startedAt: now, finishedAt: now, archivePath: archive, home: "/Users/tester")
        }
        let habits = ActivityAIWorkbenchBuilder.habitSummary(records: [
            r("a", source: "finder", archive: "/Users/tester/Downloads/x.zip"),
            r("b", source: "finder", archive: "/Users/tester/Downloads/y.zip"),
            r("c", source: "app", archive: "/Users/tester/Desktop/z.7z")
        ])
        #expect(habits.topSources.first == "finder")   // finder 2 > app 1
        #expect(habits.topFormats.contains("zip"))
        #expect(habits.topLocations.contains("downloads"))
        #expect(habits.taskCount == 3)
        #expect(ActivityAIWorkbenchBuilder.habitSummary(records: []).isEmpty)
    }
}
