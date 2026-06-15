//
//  AIContextPipelineTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:统一 Core 级 AI pipeline(白皮书工程补充一·加固 1 / acceptance #1)。
//  固定流程 make→encode→compact→produce request + 集中 source-ref 校验 + 预算守卫。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIContextPipelineTests {
    private struct SmallFacts: Codable, Equatable, Sendable { let archiveName: String }
    private struct TagFacts: Codable, Equatable, Sendable { let diagnosticTags: [String] }
    private struct RefNode { let refs: [AIContextSourceRef] }

    private let ref = AIContextSourceRef(kind: .archive, id: "arch-1")

    @Test func producesEnvelopeAndDeterministicPrompt() throws {
        let req = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata,
            facts: SmallFacts(archiveName: "a.zip"), sourceRefs: [ref])
        #expect(req.envelope.purpose == .reportExplanation)
        #expect(req.promptJSON.contains("a.zip"))
        #expect(req.allowedSourceRefs == [ref])
        #expect(req.charCount > 0)
        // 确定性:同输入逐字节一致请求。
        let again = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata,
            facts: SmallFacts(archiveName: "a.zip"), sourceRefs: [ref])
        #expect(req == again)
    }

    @Test func rejectsBlockedSensitive() {
        #expect(throws: AIContextBuildError.self) {
            try AIContextPipeline.makeRequest(
                purpose: .failureExplanation, privacyLevel: .blockedSensitive,
                facts: SmallFacts(archiveName: "secret"))
        }
    }

    @Test func smallPayloadNotCompacted() throws {
        let req = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata,
            facts: SmallFacts(archiveName: "a.zip"))
        #expect(!req.compacted)
        #expect(req.promptJSON == (try req.envelope.jsonString()))   // 原样确定性 JSON
    }

    @Test func largePayloadGetsCompacted() throws {
        let req = try AIContextPipeline.makeRequest(
            purpose: .activityFilter, privacyLevel: .localUserMetadata,
            facts: TagFacts(diagnosticTags: Array(repeating: "checksum-mismatch", count: 200)))
        #expect(req.compacted)
        #expect(req.promptJSON.contains("csm"))                       // 压缩短 token
        #expect(!req.promptJSON.contains("checksum-mismatch"))
    }

    @Test func centralizesSourceRefValidation() throws {
        let invented = AIContextSourceRef(kind: .archive, id: "ghost")
        let req = try AIContextPipeline.makeRequest(
            purpose: .archiveFinder, privacyLevel: .localUserMetadata,
            facts: SmallFacts(archiveName: "a"), sourceRefs: [ref])
        #expect(req.validate([ref]))
        #expect(!req.validate([invented]))
        #expect(!req.validate([]))                                    // 空 ref 默认拒绝(边界二)
        #expect(req.validate([], emptyPolicy: .allow))
        let kept = req.keepingValid([RefNode(refs: [ref]), RefNode(refs: [invented])]) { $0.refs }
        #expect(kept.count == 1)
    }

    @Test func flagsBudgetConsumption() throws {
        let facts = SmallFacts(archiveName: "a.zip")
        let tiny = AIBudget(maxItems: 1, maxTextChars: 1, maxSamplesPerGroup: 1, maxTotalChars: 5)
        let over = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata, facts: facts, budget: tiny)
        #expect(over.withinBudget == false)

        let big = AIBudget(maxItems: 1, maxTextChars: 1, maxSamplesPerGroup: 1, maxTotalChars: 100_000)
        let under = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata, facts: facts, budget: big)
        #expect(under.withinBudget == true)

        let noBudget = try AIContextPipeline.makeRequest(
            purpose: .reportExplanation, privacyLevel: .localUserMetadata, facts: facts)
        #expect(noBudget.withinBudget == nil)
    }
}
