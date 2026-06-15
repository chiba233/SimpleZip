//
//  AIDataGapTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:通用跨 surface 数据缺口(白皮书工程补充一·加固 3)。additive + 从工作区缺口桥接。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDataGapTests {
    private let ws = AIStableHash.deterministicUUID("ws-1")
    private let fileRef = AIContextSourceRef(kind: .file, id: "fs-1")
    private let archRef = AIContextSourceRef(kind: .archive, id: "arch-1")

    @Test func missingHashBindsEnrichment() {
        let gap = AIDataGap.missingHash(id: "g1", surface: .activityCenter, refs: [fileRef],
                                        reason: "no hash yet", urgency: .high)
        #expect(gap.kind == .missingHash)
        #expect(gap.surface == .activityCenter)
        #expect(gap.urgency == .high)
        #expect(gap.suggestedEnrichmentAction == .calculateHashes(sourceRefs: [fileRef], algorithms: [.sha256]))
    }

    @Test func missingArchiveListingBindsEnrichment() {
        let gap = AIDataGap.missingArchiveListing(id: "g2", surface: .archiveFinder, refs: [archRef],
                                                  reason: "listing not cached")
        #expect(gap.kind == .missingArchiveListing)
        #expect(gap.suggestedEnrichmentAction == .refreshArchiveListing(sourceRefs: [archRef]))
    }

    @Test func bridgesFromWorkspaceGapPreservingFields() {
        let wsGap = AIWorkspaceEvidenceGap.missingHash(id: "wg1", workspaceID: ws, refs: [fileRef],
                                                       reason: "workspace needs hash", urgency: .high)
        let gap = AIDataGap.from(workspaceGap: wsGap, surface: .sidebar)
        #expect(gap.id == "wg1")
        #expect(gap.kind == .missingHash)
        #expect(gap.surface == .sidebar)
        #expect(gap.urgency == .high)
        #expect(gap.affectedSourceRefs == [fileRef])
        #expect(gap.reason == "workspace needs hash")
        #expect(gap.suggestedEnrichmentAction == wsGap.suggestedEnrichmentAction)
    }

    @Test func bridgeMapsWorkspaceOnlyKinds() {
        // archiveHealth / recentOpenSignal 是工作区缺口独有,桥接后落到对应通用 kind。
        let health = AIWorkspaceEvidenceGap(id: "h", workspaceID: ws, kind: .missingArchiveHealth,
                                            affectedSourceRefs: [archRef], reason: "untested", urgency: .normal)
        #expect(AIDataGap.from(workspaceGap: health).kind == .missingArchiveHealth)
        let recent = AIWorkspaceEvidenceGap(id: "r", workspaceID: ws, kind: .missingRecentOpenSignal,
                                            affectedSourceRefs: [], reason: "no recent open", urgency: .low)
        let bridged = AIDataGap.from(workspaceGap: recent)
        #expect(bridged.kind == .missingRecentOpenSignal)
        #expect(bridged.urgency == .low)
    }

    @Test func generalOnlyKindsExist() {
        // 白皮书新增的通用 kind(工作区缺口没有的)。
        #expect(AIDataGap.Kind.allCases.contains(.missingTime))
        #expect(AIDataGap.Kind.allCases.contains(.missingActivityOutcome))
    }

    @Test func codableRoundTrip() throws {
        let gap = AIDataGap.missingHash(id: "g", surface: .mainWindowSuggestion, refs: [fileRef], reason: "r")
        #expect(try JSONDecoder().decode(AIDataGap.self, from: JSONEncoder().encode(gap)) == gap)
    }
}
