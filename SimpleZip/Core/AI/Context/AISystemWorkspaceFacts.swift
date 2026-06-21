//
//  AISystemWorkspaceFacts.swift
//  SimpleZip
//
//  0.4.5 #80: Deterministic facts for the built-in AI system workspaces.
//  The App target converts task/cache models into these pure value inputs;
//  DevTools can export the same facts/omissions that the read-only AI folders
//  render, without asking a model to invent paths or actions.
//

import Foundation

nonisolated struct AISystemWorkspaceTaskFact: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        case skipped
        case failed
        case cancelled
    }

    let id: String
    let category: String
    let kind: String
    let source: String
    let title: String
    let status: Status
    let startedAt: Date
    let finishedAt: Date?

    init(id: String, category: String, kind: String, source: String, title: String,
         status: Status, startedAt: Date, finishedAt: Date?) {
        self.id = id
        self.category = category
        self.kind = kind
        self.source = source
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var effectiveDate: Date { finishedAt ?? startedAt }
}

nonisolated struct AISystemWorkspaceArchiveFact: Codable, Equatable, Sendable {
    let archivePath: String
    let archiveName: String
    let recordedAt: Date
    let totalEntryCount: Int
    let fileEntryCount: Int
    let encryptedEntryCount: Int
    let truncated: Bool

    init(archivePath: String, archiveName: String, recordedAt: Date, totalEntryCount: Int,
         fileEntryCount: Int, encryptedEntryCount: Int, truncated: Bool) {
        self.archivePath = archivePath
        self.archiveName = archiveName
        self.recordedAt = recordedAt
        self.totalEntryCount = totalEntryCount
        self.fileEntryCount = fileEntryCount
        self.encryptedEntryCount = encryptedEntryCount
        self.truncated = truncated
    }
}

nonisolated struct AISystemWorkspaceFactNode: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Equatable, Sendable {
        case task
        case archive
    }

    enum SuggestedAction: String, Codable, Equatable, Sendable {
        case openActivityTask
        case openArchive
    }

    let id: String
    let kind: Kind
    let title: String
    let occurredAt: Date
    let sourceRef: AIContextSourceRef
    let suggestedAction: SuggestedAction
    let facts: [String]

    init(id: String, kind: Kind, title: String, occurredAt: Date, sourceRef: AIContextSourceRef,
         suggestedAction: SuggestedAction, facts: [String]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.occurredAt = occurredAt
        self.sourceRef = sourceRef
        self.suggestedAction = suggestedAction
        self.facts = facts
    }
}

nonisolated struct AISystemWorkspaceFactsSnapshot: Codable, Equatable, Sendable {
    let schema: String
    let workspaceKind: AISystemWorkspaceKind
    let nodes: [AISystemWorkspaceFactNode]
    let omissions: [AIContextOmission]

    init(schema: String = AISystemWorkspaceFactsBuilder.schema,
         workspaceKind: AISystemWorkspaceKind,
         nodes: [AISystemWorkspaceFactNode],
         omissions: [AIContextOmission]) {
        self.schema = schema
        self.workspaceKind = workspaceKind
        self.nodes = nodes
        self.omissions = omissions
    }
}

nonisolated enum AISystemWorkspaceFactsBuilder {
    static let schema = "simplezip.ai.systemWorkspaceFacts.v1"
    static let defaultLimit = 50

    static func snapshot(kind: AISystemWorkspaceKind,
                         tasks: [AISystemWorkspaceTaskFact],
                         archives: [AISystemWorkspaceArchiveFact],
                         limit: Int = defaultLimit) -> AISystemWorkspaceFactsSnapshot {
        switch kind {
        case .needsAttention:
            return taskSnapshot(
                kind: kind,
                tasks: tasks.filter { $0.status == .failed },
                limit: limit,
                omittedType: "ai_workspace_candidate_tasks")
        case .releaseAndVerify:
            let verifyKinds: Set<String> = ["inspect", "test", "hash", "compare"]
            return taskSnapshot(
                kind: kind,
                tasks: tasks.filter { verifyKinds.contains($0.kind) },
                limit: limit,
                omittedType: "ai_workspace_candidate_tasks")
        case .recentArchives:
            return archiveSnapshot(kind: kind, archives: archives, limit: limit)
        }
    }

    static func encodedJSON(for snapshots: [AISystemWorkspaceFactsSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshots)
    }

    private static func taskSnapshot(kind: AISystemWorkspaceKind,
                                     tasks: [AISystemWorkspaceTaskFact],
                                     limit: Int,
                                     omittedType: String) -> AISystemWorkspaceFactsSnapshot {
        let sorted = tasks.sorted {
            if $0.effectiveDate != $1.effectiveDate { return $0.effectiveDate > $1.effectiveDate }
            return $0.id < $1.id
        }
        let kept = Array(sorted.prefix(limit))
        var omissions: [AIContextOmission] = []
        if sorted.count > kept.count {
            omissions.append(.truncated(type: omittedType, omitted: sorted.count - kept.count, reason: "candidate_budget"))
        }
        return AISystemWorkspaceFactsSnapshot(
            workspaceKind: kind,
            nodes: kept.map(taskNode),
            omissions: omissions)
    }

    private static func archiveSnapshot(kind: AISystemWorkspaceKind,
                                        archives: [AISystemWorkspaceArchiveFact],
                                        limit: Int) -> AISystemWorkspaceFactsSnapshot {
        let sorted = archives.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.archivePath < $1.archivePath
        }
        let kept = Array(sorted.prefix(limit))
        var omissions: [AIContextOmission] = []
        let encryptedCount = kept.reduce(0) { $0 + $1.encryptedEntryCount }
        if encryptedCount > 0 {
            omissions.append(.encryptedEntryNames(count: encryptedCount))
        }
        let truncatedArchives = kept.filter(\.truncated).count
        if truncatedArchives > 0 {
            omissions.append(AIContextOmission(
                type: "archive_entry_names",
                count: truncatedArchives,
                policy: "cache_entry_budget"))
        }
        if sorted.count > kept.count {
            omissions.append(.truncated(
                type: "ai_workspace_candidate_archives",
                omitted: sorted.count - kept.count,
                reason: "candidate_budget"))
        }
        return AISystemWorkspaceFactsSnapshot(
            workspaceKind: kind,
            nodes: kept.map(archiveNode),
            omissions: omissions)
    }

    private static func taskNode(_ task: AISystemWorkspaceTaskFact) -> AISystemWorkspaceFactNode {
        AISystemWorkspaceFactNode(
            id: "task:\(task.id)",
            kind: .task,
            title: task.title,
            occurredAt: task.effectiveDate,
            sourceRef: AIContextSourceRef(kind: .task, id: task.id),
            suggestedAction: .openActivityTask,
            facts: [
                "category=\(task.category)",
                "kind=\(task.kind)",
                "source=\(task.source)",
                "status=\(task.status.rawValue)"
            ])
    }

    private static func archiveNode(_ archive: AISystemWorkspaceArchiveFact) -> AISystemWorkspaceFactNode {
        AISystemWorkspaceFactNode(
            id: "archive:\(archive.archivePath)",
            kind: .archive,
            title: archive.archiveName,
            occurredAt: archive.recordedAt,
            sourceRef: AIContextSourceRef(kind: .archive, id: archive.archivePath),
            suggestedAction: .openArchive,
            facts: [
                "totalEntryCount=\(archive.totalEntryCount)",
                "fileEntryCount=\(archive.fileEntryCount)",
                "encryptedEntryCount=\(archive.encryptedEntryCount)",
                "truncated=\(archive.truncated)"
            ])
    }
}
