//
//  AIEmptyStateReasonTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI「为什么没有推荐」确定性推导(建议二十三)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIEmptyStateReasonTests {
    @Test func everyTokenIsStable() {
        for c in AIEmptyStateReasonCode.allCases { #expect(!c.rawValue.isEmpty) }
        for s in AIEmptyStateNextStep.allCases { #expect(!s.rawValue.isEmpty) }
    }

    @Test func healthyStateYieldsNoReasons() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 10, nearbyArchiveCount: 5, archiveCacheCount: 20)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .sidebar, inputs: inputs)
        #expect(reason.isEmpty)
    }

    @Test func emptyCacheExplainedWithOpenArchiveStep() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 10, nearbyArchiveCount: 0, archiveCacheCount: 0)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .archiveFinder, inputs: inputs)
        #expect(reason.codes.contains(.archiveCacheEmpty))
        #expect(reason.codes.contains(.noNearbyArchives))
        #expect(reason.safeNextSteps.contains(.openArchive))
    }

    @Test func encryptedListingComesFirst() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 0, nearbyArchiveCount: 0, archiveCacheCount: 0,
                                        currentArchiveEncryptedListing: true)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .archiveSelection, inputs: inputs)
        #expect(reason.codes.first == .encryptedListingUnavailable)
    }

    @Test func disabledHabitLearningSuggestsEnabling() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 10, nearbyArchiveCount: 5, archiveCacheCount: 20,
                                        habitLearningEnabled: false)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .sidebar, inputs: inputs)
        #expect(reason.codes == [.habitLearningDisabled])
        #expect(reason.safeNextSteps.contains(.enableHabitLearning))
        #expect(reason.safeNextSteps.contains(.openAIPrivacySettings))
    }

    @Test func modelUnavailableReported() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 10, nearbyArchiveCount: 5, archiveCacheCount: 20,
                                        modelAvailable: false)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .mainToolbar, inputs: inputs)
        #expect(reason.codes == [.modelUnavailable])
    }

    @Test func nextStepsAreDeduplicated() {
        let inputs = AIEmptyStateInputs(recentTaskCount: 0, nearbyArchiveCount: 0, archiveCacheCount: 0)
        let reason = AIEmptyStateAnalyzer.analyze(surface: .sidebar, inputs: inputs)
        #expect(Set(reason.safeNextSteps).count == reason.safeNextSteps.count)
    }

    @Test func deterministicAndCodable() throws {
        let inputs = AIEmptyStateInputs(recentTaskCount: 1, nearbyArchiveCount: 0, archiveCacheCount: 0,
                                        candidatesBlockedBySafety: 2)
        let a = AIEmptyStateAnalyzer.analyze(surface: .sidebar, inputs: inputs)
        let b = AIEmptyStateAnalyzer.analyze(surface: .sidebar, inputs: inputs)
        #expect(a == b)
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(AIEmptyStateReason.self, from: data) == a)
    }
}
