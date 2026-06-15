//
//  AIWorkspaceEvidenceTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 工作区候选池的三类输出(白皮书建议四扩写):
//  证据缺口(绑只读增强动作)、抑制原因(为什么没推荐)、主题合并候选(Jaccard 重叠)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceEvidenceTests {
    private let ws = AIStableHash.deterministicUUID("workspace-paper")
    private let f1 = AIContextSourceRef(kind: .file, id: "file-001")
    private let f2 = AIContextSourceRef(kind: .file, id: "file-002")

    // MARK: - 证据缺口

    @Test func missingHashGapCarriesSha256EnrichmentAction() {
        let gap = AIWorkspaceEvidenceGap.missingHash(
            id: "gap-1", workspaceID: ws, refs: [f1, f2],
            reason: "这组大文件可能重复但缺 SHA256", urgency: .high)
        #expect(gap.kind == .missingHash)
        #expect(gap.urgency == .high)
        #expect(gap.affectedSourceRefs == [f1, f2])
        guard case let .calculateHashes(refs, algos) = gap.suggestedEnrichmentAction else {
            Issue.record("expected calculateHashes enrichment"); return
        }
        #expect(refs == [f1, f2])
        #expect(algos == [.sha256])
    }

    @Test func missingArchiveListingGapCarriesRefreshAction() {
        let gap = AIWorkspaceEvidenceGap.missingArchiveListing(
            id: "gap-2", workspaceID: ws, refs: [f1], reason: "未建立清单缓存")
        #expect(gap.kind == .missingArchiveListing)
        #expect(gap.urgency == .normal)
        if case .refreshArchiveListing = gap.suggestedEnrichmentAction {} else {
            Issue.record("expected refreshArchiveListing enrichment")
        }
    }

    @Test func evidenceGapCodableRoundTrips() throws {
        let gap = AIWorkspaceEvidenceGap(
            id: "gap-3", workspaceID: ws, kind: .missingDefaultOpenApp,
            affectedSourceRefs: [f1], reason: "缺默认打开方式")
        let data = try JSONEncoder().encode(gap)
        let back = try JSONDecoder().decode(AIWorkspaceEvidenceGap.self, from: data)
        #expect(back == gap)
        #expect(back.suggestedEnrichmentAction == nil)
    }

    // MARK: - 抑制原因

    @Test func suppressionReasonStableCodes() {
        #expect(AIRecommendationSuppressionReason.estimatedSavingTooLow == "estimatedSavingTooLow")
        #expect(AIRecommendationSuppressionReason.permissionUnreadable == "permissionUnreadable")
        #expect(AIRecommendationSuppressionReason.dismissedByUser == "dismissedByUser")
        #expect(AIRecommendationSuppressionReason.noCandidates == "noCandidates")
    }

    @Test func suppressionReasonCodableRoundTrips() throws {
        let r = AIRecommendationSuppressionReason(
            targetKind: "storageSavingSuggestion",
            reasonCode: AIRecommendationSuppressionReason.estimatedSavingTooLow,
            facts: ["dominantTypes=mp4,jpeg,zip", "estimatedSavingRatio=0.04"],
            userVisibleSummary: "这些文件多数已压缩,预计节省很低。")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(AIRecommendationSuppressionReason.self, from: data)
        #expect(back == r)
        #expect(back.targetID == nil)
    }

    // MARK: - 主题合并候选

    @Test func overlapRatioJaccard() {
        let a: Set<AIContextSourceRef> = [f1, f2]
        let b: Set<AIContextSourceRef> = [f2]
        #expect(AIWorkspaceMergeCandidate.overlapRatio(a, b) == 0.5)   // {f2} / {f1,f2}
        #expect(AIWorkspaceMergeCandidate.overlapRatio(a, a) == 1.0)
        #expect(AIWorkspaceMergeCandidate.overlapRatio(a, [AIContextSourceRef(kind: .file, id: "z")]) == 0.0)
        #expect(AIWorkspaceMergeCandidate.overlapRatio([], []) == 0.0)  // 两空集 → 0
    }

    @Test func mergeCandidateHoldsTitleSeed() {
        let seed = AIWorkspaceThemeCandidate(id: "theme-merged", titleSeed: "paper materials")
        let m = AIWorkspaceMergeCandidate(
            sourceWorkspaceIDs: [ws, AIStableHash.deterministicUUID("ws2")],
            sharedSourceRefRatio: 0.7, sharedPathRoots: ["/Users/yumeka/Desktop/论文"],
            evidence: ["sharedRefs=7"], suggestedTitleInput: seed)
        #expect(m.sourceWorkspaceIDs.count == 2)
        #expect(m.suggestedTitleInput.titleSeed == "paper materials")
    }
}
