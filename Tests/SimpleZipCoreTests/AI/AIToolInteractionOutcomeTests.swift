//
//  AIToolInteractionOutcomeTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:工具交互终局 outcome + 归档打开会话(白皮书工程补充八)。
//  核心:工具类软件里短 dwell / 快速关闭不是负反馈;按接受/撤销 patch + 终局结果判定极性。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIToolInteractionOutcomeTests {
    private let ref = AIContextSourceRef(kind: .archive, id: "arch-1")

    private func outcome(_ result: AIToolInteractionOutcome.TerminalResult,
                         optionChanges: Int = 0, accepted: [String] = [],
                         reverted: [String] = [], overrides: [String] = []) -> AIToolInteractionOutcome {
        AIToolInteractionOutcome(sourceRef: ref, operationKind: "extract", firstReaction: .extracted,
                                 terminalResult: result, optionChangesCount: optionChanges,
                                 acceptedPatchIDs: accepted, revertedPatchIDs: reverted,
                                 manualOverrideFields: overrides)
    }

    @Test func acceptedPatchThenCompletedIsPositive() {
        #expect(outcome(.completed, accepted: ["patch-1"]).polarity == .positive)
    }

    @Test func cleanCompletionWithNoChangesIsPositive() {
        // 没改任何选项就成功 = 默认/自动预填正确 = 正反馈(短 dwell 不参与)。
        #expect(outcome(.completed, optionChanges: 0).polarity == .positive)
    }

    @Test func acceptedSuggestionIsPositive() {
        #expect(outcome(.acceptedSuggestion).polarity == .positive)
    }

    @Test func completedWithManualTweaksIsNeutral() {
        #expect(outcome(.completed, optionChanges: 2).polarity == .neutral)
    }

    @Test func revertedOrOverriddenIsNegative() {
        #expect(outcome(.completed, reverted: ["patch-1"]).polarity == .negative)
        #expect(outcome(.completed, overrides: ["skipJunk"]).polarity == .negative)
    }

    @Test func cancelFailUndoDismissAreNegative() {
        #expect(outcome(.cancelled).polarity == .negative)
        #expect(outcome(.failed).polarity == .negative)
        #expect(outcome(.undone).polarity == .negative)
        #expect(outcome(.dismissedSuggestion).polarity == .negative)
        #expect(outcome(.manuallyOverrodeSuggestion).polarity == .negative)
    }

    @Test func outcomeCodableRoundTrips() throws {
        let o = outcome(.completed, accepted: ["p1"], reverted: ["p2"])
        let data = try JSONEncoder().encode(o)
        #expect(try JSONDecoder().decode(AIToolInteractionOutcome.self, from: data) == o)
    }

    // MARK: - 归档打开会话

    @Test func archiveOpenSessionStoresOnlyEncryptedCount() throws {
        let s = AIArchiveOpenSession(
            archiveID: "arch-1", openedAt: Date(timeIntervalSince1970: 1_000), source: .spotlight,
            profileTags: ["release-package"], entryCount: 980, encryptedEntriesOmitted: 42,
            firstReaction: .tested, dwellSeconds: 96)
        #expect(s.encryptedEntriesOmitted == 42)      // 只存计数,不存加密条目名
        #expect(s.firstReaction == .tested)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AIArchiveOpenSession.self, from: data) == s)
    }
}
