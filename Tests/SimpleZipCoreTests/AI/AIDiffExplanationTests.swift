//
//  AIDiffExplanationTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 对比解释(白皮书 Feat 9)。确定性 facts→attention/action 稳定 id;无变化空计划;
//  发布信号→发布检查动作;hash 变化→提醒;sanitize 剔除 allowlist 外 id。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIDiffExplanationTests {
    @Test func noChangesProducesEmptyPlan() {
        let f = AIDiffExplanationFacts(addedCount: 0, removedCount: 0, changedCount: 0, unchangedCount: 40)
        #expect(!f.hasChanges)
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(plan.isEmpty)
    }

    @Test func releaseSignalsProduceInspectionAndBodyDraft() {
        let f = AIDiffExplanationFacts(
            addedCount: 2, signals: [.addedChecksums, .addedSignature, .addedAppBundle])
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(plan.attentionIDs.contains("looks-like-release-build"))
        #expect(plan.suggestedActionIDs.contains("runReleaseInspection"))
        #expect(plan.suggestedActionIDs.contains("generateReleaseBodyDraft"))
    }

    @Test func archiveRoleAloneCountsAsReleaseLike() {
        let f = AIDiffExplanationFacts(addedCount: 1, archiveRole: AIArchiveRole.releasePackage.rawValue)
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(plan.attentionIDs.contains("looks-like-release-build"))
        #expect(plan.suggestedActionIDs.contains("runReleaseInspection"))
        // 无校验/签名信号 → 不建议生成发布正文。
        #expect(!plan.suggestedActionIDs.contains("generateReleaseBodyDraft"))
    }

    @Test func changedReadmeInReleaseTriggersNotesSync() {
        let f = AIDiffExplanationFacts(changedCount: 1, signals: [.addedChecksums, .changedReadme])
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(plan.attentionIDs.contains("release-notes-may-need-sync"))
    }

    @Test func changedReadmeWithoutReleaseDoesNotTriggerSync() {
        let f = AIDiffExplanationFacts(changedCount: 1, signals: [.changedReadme])
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(!plan.attentionIDs.contains("release-notes-may-need-sync"))
    }

    @Test func hashChangesProduceAttention() {
        let f = AIDiffExplanationFacts(changedCount: 12, hashChangedCount: 12)
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(plan.attentionIDs.contains("content-hashes-changed"))
    }

    @Test func onlyAdditionsAndOnlyRemovals() {
        let added = AIDiffExplanationRuleEngine.deterministicPlan(
            from: AIDiffExplanationFacts(addedCount: 3))
        #expect(added.attentionIDs.contains("only-additions"))
        #expect(!added.attentionIDs.contains("only-removals"))

        let removed = AIDiffExplanationRuleEngine.deterministicPlan(
            from: AIDiffExplanationFacts(removedCount: 3))
        #expect(removed.attentionIDs.contains("only-removals"))
        #expect(!removed.attentionIDs.contains("only-additions"))
    }

    @Test func openDiffReportAlwaysPresentWhenChanged() {
        let plan = AIDiffExplanationRuleEngine.deterministicPlan(
            from: AIDiffExplanationFacts(changedCount: 1))
        #expect(plan.suggestedActionIDs.contains("openDiffReport"))
    }

    @Test func sanitizeStripsInventedIDsAndDedupes() {
        let dirty = AIDiffExplanationPlan(
            summary: "改了发布产物",
            attentionIDs: ["looks-like-release-build", "looks-like-release-build", "made-up-attention"],
            suggestedActionIDs: ["runReleaseInspection", "rm -rf /", "openDiffReport", "openDiffReport"])
        let clean = AIDiffExplanationRuleEngine.sanitize(dirty)
        #expect(clean.summary == "改了发布产物")
        #expect(clean.attentionIDs == ["looks-like-release-build"])
        #expect(clean.suggestedActionIDs == ["runReleaseInspection", "openDiffReport"])
    }

    @Test func deterministicPlanOutputIsStable() {
        let f = AIDiffExplanationFacts(
            addedCount: 2, changedCount: 1, hashChangedCount: 1,
            signals: [.addedChecksums, .addedSignature, .changedReadme])
        let a = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        let b = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        #expect(a == b)
    }

    @Test func codableRoundTrip() throws {
        let f = AIDiffExplanationFacts(
            addedCount: 1, removedCount: 1, changedCount: 1, hashChangedCount: 1,
            netSizeDeltaBytes: -2048, addedSamples: ["SHA256SUMS"], signals: [.addedChecksums],
            archiveRole: "release-package", locationKind: "project-folder")
        let decodedFacts = try JSONDecoder().decode(
            AIDiffExplanationFacts.self, from: JSONEncoder().encode(f))
        #expect(decodedFacts == f)

        let plan = AIDiffExplanationRuleEngine.deterministicPlan(from: f)
        let decodedPlan = try JSONDecoder().decode(
            AIDiffExplanationPlan.self, from: JSONEncoder().encode(plan))
        #expect(decodedPlan == plan)
    }
}
