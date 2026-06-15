//
//  AISecurityAttentionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 安全关注点摘要(白皮书 Feat 17)。核心是**安全钳制**:模型绝不能把级别压到确定性下限以下,
//  stop 级强制主动作=查看安全报告,动作走 allowlist。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISecurityAttentionTests {
    @Test func floorLevelFromHints() {
        #expect(AISecurityAttentionRuleEngine.floorLevel(
            for: AISecurityAttentionFacts(riskHints: ["path-traversal"])) == .stop)
        #expect(AISecurityAttentionRuleEngine.floorLevel(
            for: AISecurityAttentionFacts(riskHints: ["executable"])) == .caution)
        #expect(AISecurityAttentionRuleEngine.floorLevel(
            for: AISecurityAttentionFacts(riskHints: ["macos-junk"])) == .info)
        #expect(AISecurityAttentionRuleEngine.floorLevel(
            for: AISecurityAttentionFacts(riskHints: [])) == .none)
    }

    @Test func floorTakesHighestHint() {
        let f = AISecurityAttentionFacts(riskHints: ["macos-junk", "executable", "path-traversal"])
        #expect(AISecurityAttentionRuleEngine.floorLevel(for: f) == .stop)
    }

    @Test func deterministicPlanForTraversalLeadsToSecurityReport() {
        let f = AISecurityAttentionFacts(riskHints: ["path-traversal", "executable"], archiveRole: "unknown",
                                         entrySamples: ["bin/install.sh", "../escape.txt"])
        let plan = AISecurityAttentionRuleEngine.deterministicPlan(from: f)
        #expect(plan.level == .stop)
        #expect(plan.primaryActionID == "openSecurityReport")
        #expect(plan.attentionIDs.contains("path-escape-samples"))
        #expect(plan.attentionIDs.contains("executable-content"))
    }

    // MARK: - 安全钳制(红线:模型不能降低级别)

    @Test func clampRejectsModelLoweringLevel() {
        let f = AISecurityAttentionFacts(riskHints: ["path-traversal"])
        // 模型试图把 stop 降成 none、并引导直接解压。
        let evil = AISecurityAttentionPlan(level: .none, headline: "没事", summary: "应该可以直接解压",
                                           primaryActionID: "extractWithReview")
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.level == .stop)                       // 级别被钳回下限
        #expect(clamped.primaryActionID == "openSecurityReport") // stop 级强制安全动作
    }

    @Test func clampRejectsLoweringAtCaution() {
        let f = AISecurityAttentionFacts(riskHints: ["executable"])
        let evil = AISecurityAttentionPlan(level: .info, primaryActionID: "cancel")
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.level == .caution)
        // caution 级 + 模型给的是合法动作(cancel 在 allowlist)→ 保留模型动作。
        #expect(clamped.primaryActionID == "cancel")
    }

    @Test func clampFillsSafeActionWhenMissingAtCaution() {
        let f = AISecurityAttentionFacts(riskHints: ["symlink"])
        let evil = AISecurityAttentionPlan(level: .caution, primaryActionID: nil)
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.primaryActionID == "openSecurityReport")
    }

    @Test func clampStripsInventedAction() {
        let f = AISecurityAttentionFacts(riskHints: ["executable"])
        let evil = AISecurityAttentionPlan(level: .caution, primaryActionID: "rm -rf /")
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.primaryActionID == "openSecurityReport") // 非法动作被剔除后补安全动作
    }

    @Test func clampAllowsModelToRaiseLevel() {
        // 模型升级级别是允许的(更保守不违反红线)。
        let f = AISecurityAttentionFacts(riskHints: ["macos-junk"]) // floor = info
        let cautious = AISecurityAttentionPlan(level: .stop, primaryActionID: "openSecurityReport")
        let clamped = AISecurityAttentionRuleEngine.clamp(cautious, against: f)
        #expect(clamped.level == .stop)
    }

    @Test func clampStripsInventedAttention() {
        let f = AISecurityAttentionFacts(riskHints: ["executable"])
        let evil = AISecurityAttentionPlan(level: .caution, primaryActionID: "openSecurityReport",
                                           attentionIDs: ["executable-content", "made-up", "made-up"])
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.attentionIDs == ["executable-content"])
    }

    @Test func clampRestoresDroppedDeterministicAttention() {
        // 红线:模型不能靠隐去确定性提醒(path-escape / encrypted)悄悄弱化警告。clamp 必须并回。
        let f = AISecurityAttentionFacts(riskHints: ["path-traversal", "executable"], encryptedEntryCount: 2)
        let evil = AISecurityAttentionPlan(level: .stop, primaryActionID: "openSecurityReport",
                                           attentionIDs: ["executable-content"]) // 故意只留一条
        let clamped = AISecurityAttentionRuleEngine.clamp(evil, against: f)
        #expect(clamped.attentionIDs.contains("path-escape-samples"))
        #expect(clamped.attentionIDs.contains("executable-content"))
        #expect(clamped.attentionIDs.contains("encrypted-entries-present"))
    }

    @Test func clampPreservesModelText() {
        let f = AISecurityAttentionFacts(riskHints: ["path-traversal"])
        let plan = AISecurityAttentionPlan(level: .stop, headline: "先别直接解压",
                                           summary: "包含路径逃逸样本", primaryActionID: "openSecurityReport")
        let clamped = AISecurityAttentionRuleEngine.clamp(plan, against: f)
        #expect(clamped.headline == "先别直接解压")
        #expect(clamped.summary == "包含路径逃逸样本")
    }

    @Test func noRiskGivesNoneLevelNoAction() {
        let f = AISecurityAttentionFacts(riskHints: [], encryptedEntryCount: 3)
        let plan = AISecurityAttentionRuleEngine.deterministicPlan(from: f)
        #expect(plan.level == .none)
        #expect(plan.primaryActionID == nil)
        // 加密只是说明,不是风险,但仍作为提醒列出。
        #expect(plan.attentionIDs.contains("encrypted-entries-present"))
    }

    @Test func codableRoundTrip() throws {
        let f = AISecurityAttentionFacts(riskHints: ["path-traversal", "executable"], archiveRole: "unknown",
                                         entrySamples: ["../x"], encryptedEntryCount: 1)
        let plan = AISecurityAttentionRuleEngine.deterministicPlan(from: f)
        let decodedFacts = try JSONDecoder().decode(AISecurityAttentionFacts.self, from: JSONEncoder().encode(f))
        let decodedPlan = try JSONDecoder().decode(AISecurityAttentionPlan.self, from: JSONEncoder().encode(plan))
        #expect(decodedFacts == f)
        #expect(decodedPlan == plan)
    }
}
