//
//  AISystemWorkspaceFactsTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80: AI system workspace facts are the deterministic payload
//  exported from DevTools and reused by the read-only AI folder UI.
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISystemWorkspaceFactsTests {
    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_010_000)

    private func task(_ id: String, kind: String, status: AISystemWorkspaceTaskFact.Status,
                      title: String = "Task", finishedAt: Date? = nil) -> AISystemWorkspaceTaskFact {
        AISystemWorkspaceTaskFact(
            id: id,
            category: "archive",
            kind: kind,
            source: "app",
            title: title,
            status: status,
            startedAt: older,
            finishedAt: finishedAt)
    }

    private func archive(_ path: String, name: String, recordedAt: Date,
                         encrypted: Int = 0, truncated: Bool = false) -> AISystemWorkspaceArchiveFact {
        AISystemWorkspaceArchiveFact(
            archivePath: path,
            archiveName: name,
            recordedAt: recordedAt,
            totalEntryCount: 12,
            fileEntryCount: 9,
            encryptedEntryCount: encrypted,
            truncated: truncated)
    }

    @Test func needsAttentionKeepsFailedTasksNewestFirst() {
        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(
            kind: .needsAttention,
            tasks: [
                task("ok", kind: "test", status: .succeeded, finishedAt: newer),
                task("old-fail", kind: "extract", status: .failed, finishedAt: older),
                task("new-fail", kind: "compress", status: .failed, finishedAt: newer)
            ],
            archives: [])

        #expect(snapshot.schema == "simplezip.ai.systemWorkspaceFacts.v1")
        #expect(snapshot.workspaceKind == .needsAttention)
        #expect(snapshot.nodes.map(\.id) == ["task:new-fail", "task:old-fail"])
        #expect(snapshot.nodes.map(\.sourceRef.kind) == [.task, .task])
        #expect(snapshot.omissions.isEmpty)
    }

    @Test func releaseAndVerifyKeepsOnlyVerificationKinds() {
        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(
            kind: .releaseAndVerify,
            tasks: [
                task("inspect", kind: "inspect", status: .succeeded, finishedAt: older),
                task("hash", kind: "hash", status: .failed, finishedAt: newer),
                task("copy", kind: "copy", status: .succeeded, finishedAt: newer)
            ],
            archives: [])

        #expect(snapshot.nodes.map(\.id) == ["task:hash", "task:inspect"])
        #expect(snapshot.nodes.allSatisfy { $0.suggestedAction == .openActivityTask })
    }

    @Test func recentArchivesKeepsNewestAndReportsPrivacyOmissions() {
        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(
            kind: .recentArchives,
            tasks: [],
            archives: [
                archive("/archives/old.zip", name: "old.zip", recordedAt: older),
                archive("/archives/new.7z", name: "new.7z", recordedAt: newer, encrypted: 3, truncated: true)
            ])

        #expect(snapshot.nodes.map(\.id) == ["archive:/archives/new.7z", "archive:/archives/old.zip"])
        #expect(snapshot.nodes.first?.facts.contains("encryptedEntryCount=3") == true)
        #expect(snapshot.omissions.contains(.encryptedEntryNames(count: 3)))
        #expect(snapshot.omissions.contains(AIContextOmission(
            type: "archive_entry_names",
            count: 1,
            policy: "cache_entry_budget")))
    }

    @Test func candidateBudgetAddsOmission() {
        let tasks = (0..<52).map {
            task("fail-\($0)", kind: "test", status: .failed,
                 finishedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + $0)))
        }

        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(kind: .needsAttention, tasks: tasks, archives: [])

        #expect(snapshot.nodes.count == 50)
        #expect(snapshot.omissions.contains(AIContextOmission(
            type: "ai_workspace_candidate_tasks",
            count: 2,
            policy: "candidate_budget")))
    }

    @Test func snapshotJSONIsStableAndCodable() throws {
        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(
            kind: .recentArchives,
            tasks: [],
            archives: [archive("/archives/app.zip", name: "app.zip", recordedAt: newer)])

        let data = try AISystemWorkspaceFactsBuilder.encodedJSON(for: [snapshot])
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"schema\" : \"simplezip.ai.systemWorkspaceFacts.v1\""))
        #expect(text.contains("\"workspaceKind\" : \"recentArchives\""))
        #expect(try JSONDecoder().decode([AISystemWorkspaceFactsSnapshot].self, from: data) == [snapshot])
    }
}
