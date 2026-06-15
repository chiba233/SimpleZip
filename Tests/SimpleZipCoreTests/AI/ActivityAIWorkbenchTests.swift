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
}
