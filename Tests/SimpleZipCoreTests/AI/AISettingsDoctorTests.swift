//
//  AISettingsDoctorTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 设置医生(白皮书 Feat 19)。动作走「适用性」allowlist(剔除 no-op / 发明的);AI 关闭只给开启;
//  无模型兜底打开设置页。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISettingsDoctorTests {
    private func state(ai: Bool = true, bg: AIBackgroundActivityLevel = .off,
                       preRead: Bool = false, folder: Bool = false, spotlight: Bool = true) -> AISettingsState {
        AISettingsState(aiEnabled: ai, backgroundActivity: bg, archivePreRead: preRead,
                        folderPreIndex: folder, spotlightIndexing: spotlight)
    }

    @Test func alwaysOffersOpenSettingsAndPrivacy() {
        let a = AISettingsDoctor.applicableActions(for: state())
        #expect(a.contains("openAISettings"))
        #expect(a.contains("openPrivacyData"))
    }

    @Test func aiDisabledOnlyOffersEnable() {
        let a = AISettingsDoctor.applicableActions(for: state(ai: false))
        #expect(a.contains("enableAI"))
        #expect(!a.contains("setBackgroundBalanced"))
        #expect(!a.contains("enableArchivePreRead"))
    }

    @Test func backgroundOffersOtherLevelsNotCurrent() {
        let a = AISettingsDoctor.applicableActions(for: state(bg: .off))
        #expect(a.contains("setBackgroundBalanced"))
        #expect(a.contains("setBackgroundPowerSaver"))
        #expect(a.contains("setBackgroundAggressive"))
        #expect(!a.contains("setBackgroundOff")) // 已是 off,不重复建议
    }

    @Test func archivePreReadOffersEnableWhenOff() {
        let a = AISettingsDoctor.applicableActions(for: state(preRead: false))
        #expect(a.contains("enableArchivePreRead"))
        #expect(!a.contains("disableArchivePreRead"))
    }

    @Test func archivePreReadOffersDisableWhenOn() {
        let a = AISettingsDoctor.applicableActions(for: state(preRead: true))
        #expect(a.contains("disableArchivePreRead"))
        #expect(!a.contains("enableArchivePreRead"))
    }

    @Test func sanitizeDropsNonApplicableNoOps() {
        // backgroundActivity 已是 off → 模型再建议 setBackgroundOff 是 no-op,应剔除。
        let clean = AISettingsDoctor.sanitize(
            ["setBackgroundBalanced", "setBackgroundOff", "openPrivacyData"], for: state(bg: .off))
        #expect(clean == ["setBackgroundBalanced", "openPrivacyData"])
    }

    @Test func sanitizeStripsInventedActions() {
        let clean = AISettingsDoctor.sanitize(
            ["openAISettings", "rm -rf /", "deleteAllArchives"], for: state())
        #expect(clean == ["openAISettings"])
    }

    @Test func sanitizeDedupes() {
        let clean = AISettingsDoctor.sanitize(
            ["openAISettings", "openAISettings", "openPrivacyData"], for: state())
        #expect(clean == ["openAISettings", "openPrivacyData"])
    }

    @Test func deterministicAnswerOpensSettings() {
        let ans = AISettingsDoctor.deterministicAnswer(
            for: AISettingsDoctorFacts(userIntent: "想更懂我但别耗电", state: state(bg: .off)))
        #expect(ans.answer == nil)
        #expect(ans.actionIDs == ["openAISettings"])
    }

    @Test func codableRoundTrip() throws {
        let facts = AISettingsDoctorFacts(userIntent: "balance", state: state(ai: true, bg: .balanced, preRead: true))
        let decoded = try JSONDecoder().decode(AISettingsDoctorFacts.self, from: JSONEncoder().encode(facts))
        #expect(decoded == facts)
    }
}
