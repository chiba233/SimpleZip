//
//  AISemanticTagTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:受控语义标签集 + 排序 + 纠错降权 + 模型输出校验(白皮书 Feat 1 / 5 / 11)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISemanticTagTests {
    @Test func tokenParsingRejectsUnknown() {
        #expect(AISemanticTag(token: "release-artifact") == .releaseArtifact)
        #expect(AISemanticTag(token: "source-archive") == .sourceArchive)
        #expect(AISemanticTag(token: "totally-made-up") == nil)
        #expect(AISemanticTag(token: "") == nil)
    }

    @Test func rawTokensMatchArchiveProfileVocabulary() {
        // ArchiveProfile 产的 string tags 必须都能被这个受控集解析(对齐,不漂移)。
        for token in ["source-archive", "swift-project", "localized-app", "release-artifact",
                      "signed-container-related", "installer", "documentation", "application-bundle"] {
            #expect(AISemanticTag(token: token) != nil, "ArchiveProfile token \(token) 应在受控集内")
        }
    }

    @Test func archiveRoleClassification() {
        #expect(AISemanticTag.releasePackage.isArchiveRole)
        #expect(AISemanticTag.sourceArchive.isArchiveRole)
        #expect(AISemanticTag.testFixture.isArchiveRole)
        #expect(!AISemanticTag.documentation.isArchiveRole)
        #expect(!AISemanticTag.swiftProject.isArchiveRole)
        #expect(!AISemanticTag.signedContainerRelated.isArchiveRole)
    }

    @Test func rankSortsByScoreDescendingThenToken() {
        let cands = [
            AISemanticTagCandidate(tag: .backup, deterministicScore: 0.5),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.9),
            AISemanticTagCandidate(tag: .installer, deterministicScore: 0.5),
        ]
        let ranked = AISemanticTagRanker.rank(cands)
        #expect(ranked.map { $0.tag } == [.releaseArtifact, .backup, .installer]) // 0.9 先;0.5 同分按 token 升序 backup<installer
    }

    @Test func negativeFeedbackDemotes() {
        let cands = [
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.8),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.7),
        ]
        // sourceArchive 被点 3 次「不对」→ 0.8 - 0.15 = 0.65 < 0.7,排到 releaseArtifact 后面。
        let ranked = AISemanticTagRanker.rank(cands, negativeFeedback: ["source-archive": 3])
        #expect(ranked.map { $0.tag } == [.releaseArtifact, .sourceArchive])
    }

    @Test func negativeFeedbackRequiresFourHitsForBenchmarkGap() {
        let cands = [
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.88),
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.72),
        ]
        #expect(AISemanticTagRanker.rank(cands, negativeFeedback: ["release-artifact": 3]).first?.tag == .releaseArtifact)
        #expect(AISemanticTagRanker.rank(cands, negativeFeedback: ["release-artifact": 4]).first?.tag == .sourceArchive)
    }

    @Test func negativeFeedbackIsCapped() {
        let cands = [
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.8),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.5),
        ]
        // 即使点 100 次,最多衰减 5*0.05=0.25 → 0.55 > 0.5,不会无限掉到底。
        let ranked = AISemanticTagRanker.rank(cands, negativeFeedback: ["source-archive": 100])
        #expect(ranked.first?.tag == .sourceArchive)
        let effectiveSource = ranked.first { $0.tag == .sourceArchive }
        #expect(effectiveSource != nil)
    }

    @Test func rankLimitTruncates() {
        let cands = (0..<5).map {
            AISemanticTagCandidate(tag: AISemanticTag.allCases[$0], deterministicScore: Double(5 - $0) / 5)
        }
        #expect(AISemanticTagRanker.rank(cands, limit: 2).count == 2)
        #expect(AISemanticTagRanker.rank(cands, limit: 0).isEmpty)
    }

    @Test func validateChosenDropsInventedAndDeduplicates() {
        let cands = [
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.9),
            AISemanticTagCandidate(tag: .signedContainer, deterministicScore: 0.6),
        ]
        // 模型给:有效 + 候选外(testFixture 不在候选) + 发明(garbage) + 重复(releaseArtifact)。
        let chosen = AISemanticTagRanker.validateChosen(
            ["release-artifact", "test-fixture", "garbage-tag", "signed-container", "release-artifact"],
            against: cands)
        #expect(chosen == [.releaseArtifact, .signedContainer]) // 保序、去重、丢候选外与发明
    }

    @Test func positiveFeedbackPromotes() {
        let cands = [
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.5),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.6),
        ]
        // sourceArchive 被确认 2 次 → 0.5 + 0.20 = 0.70 > 0.6,排到前面
        let ranked = AISemanticTagRanker.rank(cands, positiveFeedback: ["source-archive": 2])
        #expect(ranked.first?.tag == .sourceArchive)
    }

    @Test func positiveFeedbackIsCapped() {
        let cands = [
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.0),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.9),
        ]
        // 即使确认 100 次,最多提升 5*0.10=0.50 → 0.50 < 0.9,仍排在 releaseArtifact 后面
        let ranked = AISemanticTagRanker.rank(cands, positiveFeedback: ["source-archive": 100])
        #expect(ranked.first?.tag == .releaseArtifact)
    }

    @Test func posNegFeedbackCombined() {
        let cands = [
            AISemanticTagCandidate(tag: .sourceArchive, deterministicScore: 0.8),
            AISemanticTagCandidate(tag: .releaseArtifact, deterministicScore: 0.5),
        ]
        // sourceArchive 被踩 5 次(-0.25) 又被确认 3 次(+0.30) → 0.8 - 0.25 + 0.30 = 0.85 > 0.5
        let ranked = AISemanticTagRanker.rank(
            cands,
            negativeFeedback: ["source-archive": 5],
            positiveFeedback: ["source-archive": 3])
        #expect(ranked.first?.tag == .sourceArchive)
    }

    @Test func candidateCodableRoundTrip() throws {
        let c = AISemanticTagCandidate(
            tag: .releasePackage, deterministicScore: 0.88,
            evidence: [AIEvidenceFact(label: "marker", facts: ["SHA256SUMS"])])
        let decoded = try JSONDecoder().decode(
            AISemanticTagCandidate.self, from: JSONEncoder().encode(c))
        #expect(decoded == c)
    }
}
