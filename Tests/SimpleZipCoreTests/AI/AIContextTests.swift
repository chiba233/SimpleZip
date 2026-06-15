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

    private func sampleEnvelope() throws -> AIContextEnvelope<SampleFacts> {
        try AIContextEnvelope.make(
            purpose: .reportExplanation,
            privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 3),
            omissions: [.encryptedEntryNames(count: 2), .passwords],
            sourceRefs: [AIContextSourceRef(kind: .archive, id: "arch-1")]
        )
    }

    @Test func envelopeStampsSchemaVersion() throws {
        #expect(try sampleEnvelope().schema == "simplezip.ai.context.v1")
        #expect(AIContextEnvelope<SampleFacts>.schemaVersion == "simplezip.ai.context.v1")
    }

    @Test func jsonIsDeterministic() throws {
        #expect(try sampleEnvelope().jsonString() == sampleEnvelope().jsonString())
    }

    @Test func jsonCarriesStableEnglishTokens() throws {
        let json = try sampleEnvelope().jsonString()
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

    @Test func deepModeFlagsLocalTextSnippets() throws {
        let standard = try AIContextEnvelope.make(
            purpose: .archiveFinder, privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 1))
        #expect(standard.privacy.mode == .standardLocalContext)
        #expect(standard.privacy.localTextSnippetsIncluded == false)

        let deep = try AIContextEnvelope.make(
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
        let env = try AIContextEnvelope.make(
            purpose: .archiveFinder,
            privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a/b/c.zip", fileCount: 1)
        )
        #expect(try env.jsonString().contains("a/b/c.zip"))
    }

    @Test func roundTripsThroughCodable() throws {
        let env = try sampleEnvelope()
        let data = Data(try env.jsonString().utf8)
        let decoded = try JSONDecoder().decode(AIContextEnvelope<SampleFacts>.self, from: data)
        #expect(decoded == env)
    }

    @Test func blockedSensitiveIsNeverAssemblable() {
        #expect(AIPrivacyLevel.blockedSensitive.isAssemblable == false)
        #expect(AIPrivacyLevel.localUserMetadata.isAssemblable)
        #expect(AIPrivacyLevel.publicAppCatalog.isAssemblable)
        #expect(AIPrivacyLevel.diagnostics.isAssemblable)
    }

    // MARK: - 边界一:信封只能经安全工厂进入模型(白皮书工程补充一)

    @Test func blockedSensitiveEnvelopeCannotBeBuilt() {
        #expect(throws: AIContextBuildError.blockedSensitivePayload(.failureExplanation)) {
            try AIContextEnvelope.make(
                purpose: .failureExplanation,
                privacyLevel: .blockedSensitive,
                facts: SampleFacts(archiveName: "secret.zip", fileCount: 1))
        }
    }

    @Test func standardLocalContextEnvelopeCanBeBuilt() throws {
        let env = try AIContextEnvelope.make(
            purpose: .activityFilter,
            privacyLevel: .localUserMetadata,
            facts: SampleFacts(archiveName: "a.zip", fileCount: 1))
        #expect(env.privacy.level == .localUserMetadata)
        // diagnostics / publicAppCatalog 也可组装。
        #expect(throws: Never.self) {
            try AIContextEnvelope.make(
                purpose: .failureExplanation, privacyLevel: .diagnostics,
                facts: SampleFacts(archiveName: "a.zip", fileCount: 1))
        }
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

    // MARK: - 边界二:身份强度 + 空引用策略(白皮书工程补充一)

    @Test func stableSourceRefIDsAreLongEnoughForPromptRoundTrip() {
        // 64-bit → 16 hex;128-bit → 32 hex,远强于 fnv1a32 的 8 hex。
        #expect(AIStableHash.stableID64("/Users/x/papers/thesis.pdf").count == 16)
        #expect(AIStableHash.stableID128("/Users/x/papers/thesis.pdf").count == 32)
        #expect(AIStableHash.fnv1a32Hex("/Users/x/papers/thesis.pdf").count == 8)
        // 确定性 + 判别性。
        #expect(AIStableHash.stableID64("a") == AIStableHash.stableID64("a"))
        #expect(AIStableHash.stableID64("a") != AIStableHash.stableID64("b"))
        #expect(AIStableHash.stableID128("a") != AIStableHash.stableID128("b"))
    }

    @Test func sourceRefRegistryRejectsCollisionWithinCandidateSet() throws {
        var registry = AIContextRefRegistry()
        let a = try registry.ref(for: "/Users/x/a.zip", kind: .archive)
        let b = try registry.ref(for: "/Users/x/b.zip", kind: .archive)
        #expect(a.id != b.id)
        #expect(registry.count == 2)
        // 同身份串幂等,不增计数。
        #expect(try registry.ref(for: "/Users/x/a.zip", kind: .archive) == a)
        #expect(registry.count == 2)
        // 模型回传 id 落回真实身份。
        #expect(registry.canonical(forID: a.id) == "/Users/x/a.zip")
        #expect(registry.allowedRefIDs.contains(a.id))

        // 强制碰撞:同 id 绑不同 canonical → 拒绝。
        var collide = AIContextRefRegistry()
        try collide.register(id: "archive-dup", canonical: "/p/one")
        var threw = false
        do {
            try collide.register(id: "archive-dup", canonical: "/p/two")
        } catch {
            threw = true
            #expect(error as? AIContextRefRegistry.RegistryError
                    == .idCollision(id: "archive-dup", existing: "/p/one", incoming: "/p/two"))
        }
        #expect(threw)
    }

    @Test func workspaceNodeRejectsEmptySourceRefs() {
        let a = AIContextSourceRef(kind: .file, id: "f1")
        let allowed: Set = [a]
        // allRefsValid 空集默认拒绝。
        #expect(!AIContextSourceRefValidator.allRefsValid([], allowed: allowed))
        // keepingValid 默认 .reject:空 ref 节点被丢弃,只剩有 ref 的。
        let nodes = [RefNode(refs: [a]), RefNode(refs: [])]
        #expect(AIContextSourceRefValidator.keepingValid(nodes, allowed: allowed) { $0.refs }.count == 1)
    }

    @Test func globalSettingsSuggestionMayAllowEmptySourceRefs() {
        let a = AIContextSourceRef(kind: .setting, id: "s1")
        let allowed: Set = [a]
        // 显式 .allow:与具体对象无关的建议(全局设置)放行空 ref。
        #expect(AIContextSourceRefValidator.allRefsValid([], allowed: allowed, emptyPolicy: .allow))
        let nodes = [RefNode(refs: [])]
        #expect(AIContextSourceRefValidator.keepingValid(
            nodes, allowed: allowed, emptyPolicy: .allow) { $0.refs }.count == 1)
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
