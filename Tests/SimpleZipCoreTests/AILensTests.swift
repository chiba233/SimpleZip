//
//  AILensTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI Lens → 确定性 query plan(白皮书 Feat 2)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AILensTests {
    @Test func everyLensHasStableTokenAndIcon() {
        for lens in AILens.allCases {
            #expect(!lens.rawValue.isEmpty)
            #expect(!lens.iconSystemName.isEmpty)
        }
    }

    @Test func releaseLensPlanTargetsReleaseSignals() {
        let plan = AILens.release.queryPlan
        #expect(plan.semanticTags.contains("release-artifact"))
        #expect(plan.markerFiles.contains("SHA256SUMS"))
        #expect(plan.taskTags.contains("checksum-mismatch"))
        #expect(plan.includeReports)
        #expect(!plan.isEmpty)
    }

    @Test func sourceLensPlanTargetsSourceMarkers() {
        let plan = AILens.source.queryPlan
        #expect(plan.semanticTags.contains("source-archive"))
        #expect(plan.markerFiles.contains("Package.swift"))
        #expect(!plan.includeTasks)
        #expect(!plan.isEmpty)
    }

    @Test func failuresLensCoversAllDiagnosticTags() {
        let plan = AILens.failures.queryPlan
        #expect(Set(plan.taskTags) == Set(AIDiagnosticTag.allCases.map(\.rawValue)))
        #expect(!plan.includeArchives)
        #expect(plan.includeTasks)
    }

    @Test func everyLensPlanIsNonEmpty() {
        for lens in AILens.allCases {
            #expect(!lens.queryPlan.isEmpty, "lens \(lens.rawValue) produced an empty plan")
        }
    }

    @Test func lensRoundTripsThroughCodable() throws {
        for lens in AILens.allCases {
            let data = try JSONEncoder().encode(lens)
            #expect(try JSONDecoder().decode(AILens.self, from: data) == lens)
        }
    }

    @Test func releaseLensRecallsReleaseArchive() {
        // 端到端:lens plan 经执行器真的能召回带 release-artifact 标签的归档记忆。
        let profile = ArchiveProfile(
            semanticTags: ["release-artifact"], markerFiles: ["SHA256SUMS"],
            dominantExtensions: [.init(ext: "dmg", count: 1)],
            structure: .init(topLevelShape: "scattered_files", topLevelNames: ["SHA256SUMS"],
                             entryCount: 3, fileCount: 3, directoryCount: 0, encryptedEntryCount: 0),
            riskHints: [], omissions: [])
        let record = ArchiveMemoryRecord(
            archiveID: "arch-rel", archiveName: "release-assets.7z", archiveExtension: "7z",
            location: AILocationContext(kind: .projectFolder, pathHash: "loc-1", folderNameTokens: ["release"]),
            recordedAt: Date(timeIntervalSince1970: 100), archiveByteSize: 1000,
            entryStats: .init(totalEntries: 3, visibleEntries: 3, encryptedEntriesOmitted: 0, truncated: false),
            profile: profile, samplePaths: ["SHA256SUMS"], largestFiles: [], omissions: [])
        let matched = AIWorkspaceQueryExecutor.matchArchives(AILens.release.queryPlan, in: [record])
        #expect(matched.map(\.archiveID) == ["arch-rel"])
    }
}
