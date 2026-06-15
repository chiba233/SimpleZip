//
//  AIInterventionGateTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 打扰阈值门(白皮书「轻工具优先」)。AI 出现强度由规则决定,无风险不打扰、自动解压不打断。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIInterventionGateTests {
    @Test func levelOrdering() {
        #expect(AIInterventionLevel.silent < .statusOnly)
        #expect(AIInterventionLevel.statusOnly < .inlineHint)
        #expect(AIInterventionLevel.inlineHint < .adviceCards)
        #expect(AIInterventionLevel.adviceCards < .requirePreview)
    }

    @Test func userRequestedAIAllowsCards() {
        let input = AIInterventionGateInput(surface: .sidebar, source: "app", userRequestedAI: true)
        #expect(AIInterventionGate.level(for: input) == .adviceCards)
    }

    @Test func finderDoubleClickSmallSafeZipIsQuiet() {
        // 从 Finder 双击 5MB 图片 zip,无覆盖/缺卷/可疑/符号链接/低空间 → statusOnly。
        let input = AIInterventionGateInput(
            surface: .archiveTableEmptyState, source: "finder",
            fileByteSize: 5_000_000, archiveExtension: "zip")
        #expect(AIInterventionGate.level(for: input) == .statusOnly)
    }

    @Test func autoExtractNoRiskIsSilent() {
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "finder", finderAutoExtract: true)
        #expect(AIInterventionGate.level(for: input) == .silent)
    }

    @Test func autoExtractWithRiskIsRestrainedToInlineHint() {
        // 自动解压路径即便有覆盖风险也只升到 inlineHint,绝不弹重型面板打断自动流。
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "finder", overwriteCount: 5, finderAutoExtract: true)
        #expect(AIInterventionGate.level(for: input) == .inlineHint)
    }

    @Test func autoExtractClampHoldsEvenWhenUserRequestedAI() {
        // 对抗审计 MEDIUM 回归:userRequestedAI 也不能突破自动解压天花板。
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "finder", suspiciousEntryCount: 9,
            finderAutoExtract: true, userRequestedAI: true)
        #expect(AIInterventionGate.level(for: input) == .inlineHint)
    }

    @Test func suspiciousPathInDialogEscalatesToCards() {
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "app", suspiciousEntryCount: 1)
        #expect(AIInterventionGate.level(for: input) == .adviceCards)
    }

    @Test func missingVolumeEscalatesToCards() {
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "app", missingVolumeCount: 2)
        #expect(AIInterventionGate.level(for: input) == .adviceCards)
    }

    @Test func highValueRoleEscalatesEvenWithoutRisk() {
        let input = AIInterventionGateInput(
            surface: .archiveSelection, source: "app", archiveRoleTags: ["release-artifact"])
        #expect(AIInterventionGate.level(for: input) == .adviceCards)
    }

    @Test func plainAppDialogNoRiskIsInlineHint() {
        let input = AIInterventionGateInput(
            surface: .createDialog, source: "app", archiveRoleTags: ["documentation"])
        #expect(AIInterventionGate.level(for: input) == .inlineHint)
    }

    @Test func hasRiskSignalReflectsAnySignal() {
        #expect(!AIInterventionGateInput(surface: .createDialog, source: "app").hasRiskSignal)
        #expect(AIInterventionGateInput(surface: .createDialog, source: "app", symlinkCount: 1).hasRiskSignal)
        #expect(AIInterventionGateInput(surface: .createDialog, source: "app", lowSpaceWarning: true).hasRiskSignal)
    }

    @Test func inputCodableRoundTrip() throws {
        let input = AIInterventionGateInput(
            surface: .extractDialog, source: "finder", overwriteCount: 3, archiveRoleTags: ["source-archive"])
        let decoded = try JSONDecoder().decode(
            AIInterventionGateInput.self, from: JSONEncoder().encode(input))
        #expect(decoded == input)
    }
}
