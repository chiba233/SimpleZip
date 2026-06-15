//
//  AIContextTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:统一 AI 数据层契约 —— 确定性编码 / 隐私分级 / 省略说明 / 证据卡 / 来源引用。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIContextTests {
    private struct SampleFacts: Codable, Equatable, Sendable {
        let archiveName: String
        let fileCount: Int
    }

    private var sampleEnvelope: AIContextEnvelope<SampleFacts> {
        AIContextEnvelope(
            purpose: .reportExplanation,
            privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 3),
            omissions: [.encryptedEntryNames(count: 2), .passwords],
            sourceRefs: [AIContextSourceRef(kind: .archive, id: "arch-1")]
        )
    }

    @Test func envelopeStampsSchemaVersion() {
        #expect(sampleEnvelope.schema == "simplezip.ai.context.v1")
        #expect(AIContextEnvelope<SampleFacts>.schemaVersion == "simplezip.ai.context.v1")
    }

    @Test func jsonIsDeterministic() throws {
        #expect(try sampleEnvelope.jsonString() == sampleEnvelope.jsonString())
    }

    @Test func jsonCarriesStableEnglishTokens() throws {
        let json = try sampleEnvelope.jsonString()
        #expect(json.contains("\"schema\":\"simplezip.ai.context.v1\""))
        #expect(json.contains("\"purpose\":\"reportExplanation\""))
        // 隐私描述块:执行位置 + 强度 + 级别。
        #expect(json.contains("\"execution\":\"on_device_apple_foundation_models\""))
        #expect(json.contains("\"mode\":\"standard_local_context\""))
        #expect(json.contains("\"level\":\"localUserMetadata\""))
        #expect(json.contains("\"passwordsIncluded\":false"))
        #expect(json.contains("\"encryptedEntryNamesIncluded\":false"))
        // facts 内联 + 路径斜杠不转义。
        #expect(json.contains("\"archiveName\":\"a.zip\""))
        #expect(json.contains("\"fileCount\":3"))
        // 省略说明在场:加密条目名永不进 AI。
        #expect(json.contains("\"type\":\"encrypted_entry_names\""))
        #expect(json.contains("\"policy\":\"never_included\""))
    }

    @Test func deepModeFlagsLocalTextSnippets() {
        let standard = AIContextEnvelope(
            purpose: .archiveFinder, privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 1))
        #expect(standard.privacy.mode == .standardLocalContext)
        #expect(standard.privacy.localTextSnippetsIncluded == false)

        let deep = AIContextEnvelope(
            purpose: .archiveFinder, privacyLevel: .localUserMetadata, mode: .deepLocalContext,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 1))
        #expect(deep.privacy.mode == .deepLocalContext)
        #expect(deep.privacy.localTextSnippetsIncluded == true)
        // 深度模式仍不含红线类别。
        #expect(deep.privacy.passwordsIncluded == false)
        #expect(deep.privacy.encryptedEntryNamesIncluded == false)
        #expect(deep.privacy.decryptedContentIncluded == false)
    }

    @Test func slashesAreNotEscaped() throws {
        let env = AIContextEnvelope(
            purpose: .archiveFinder,
            privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a/b/c.zip", fileCount: 1)
        )
        #expect(try env.jsonString().contains("a/b/c.zip"))
    }

    @Test func roundTripsThroughCodable() throws {
        let data = Data(try sampleEnvelope.jsonString().utf8)
        let decoded = try JSONDecoder().decode(AIContextEnvelope<SampleFacts>.self, from: data)
        #expect(decoded == sampleEnvelope)
    }

    @Test func blockedSensitiveIsNeverAssemblable() {
        #expect(AIPrivacyLevel.blockedSensitive.isAssemblable == false)
        #expect(AIPrivacyLevel.localUserMetadata.isAssemblable)
        #expect(AIPrivacyLevel.publicAppCatalog.isAssemblable)
        #expect(AIPrivacyLevel.diagnostics.isAssemblable)
    }

    @Test func omissionConvenienceConstructors() {
        #expect(AIContextOmission.passwords.type == "passwords")
        #expect(AIContextOmission.passwords.policy == "never_included")
        #expect(AIContextOmission.encryptedEntryNames(count: 5).count == 5)
        #expect(AIContextOmission.truncated(type: "tasks", omitted: 12).count == 12)
    }

    @Test func sourceRefValidatorRejectsInventedRefs() {
        let a = AIContextSourceRef(kind: .task, id: "t1")
        let b = AIContextSourceRef(kind: .archive, id: "arch1")
        let invented = AIContextSourceRef(kind: .task, id: "ghost")
        let allowed: Set = [a, b]

        #expect(AIContextSourceRefValidator.isValid(a, allowed: allowed))
        #expect(!AIContextSourceRefValidator.isValid(invented, allowed: allowed))

        let (valid, rejected) = AIContextSourceRefValidator.partition([a, invented, b], allowed: allowed)
        #expect(valid == [a, b])
        #expect(rejected == [invented])

        #expect(AIContextSourceRefValidator.allRefsValid([a, b], allowed: allowed))
        #expect(!AIContextSourceRefValidator.allRefsValid([a, invented], allowed: allowed))
    }

    private struct RefNode { let refs: [AIContextSourceRef] }

    @Test func sourceRefValidatorDropsNodesWithInventedRefs() {
        let a = AIContextSourceRef(kind: .task, id: "t1")
        let b = AIContextSourceRef(kind: .archive, id: "arch1")
        let invented = AIContextSourceRef(kind: .task, id: "ghost")
        let allowed: Set = [a, b]
        let nodes = [RefNode(refs: [a]), RefNode(refs: [a, invented]), RefNode(refs: [b])]
        let kept = AIContextSourceRefValidator.keepingValid(nodes, allowed: allowed) { $0.refs }
        #expect(kept.count == 2)
    }

    @Test func evidenceCardKeepsFactsAndRefs() {
        let card = AIEvidenceCard(
            title: "Re-test release.7z",
            reason: "Recent CLI test failed with Data Error.",
            evidence: [AIEvidenceFact(
                label: "Recent test failed",
                facts: ["source=cli", "status=failed", "tag=checksum-mismatch"],
                sourceRef: AIContextSourceRef(kind: .task, id: "task-7B2F")
            )]
        )
        #expect(card.evidence.first?.sourceRef?.kind == .task)
        #expect(card.evidence.first?.facts.contains("tag=checksum-mismatch") == true)
    }
}
