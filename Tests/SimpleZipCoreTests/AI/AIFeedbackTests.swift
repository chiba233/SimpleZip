//
//  AIFeedbackTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 纠错反馈聚合(Feat 11)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFeedbackTests {
    private func event(_ kind: AIFeedbackEvent.Kind, target: AIFeedbackEvent.TargetKind = .workspace,
                       id: String = "x", from: String? = nil, to: String? = nil,
                       tokens: [String] = []) -> AIFeedbackEvent {
        AIFeedbackEvent(targetKind: target, targetID: id, kind: kind,
                        fromTag: from, toTag: to, evidenceTokens: tokens,
                        createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func positiveAndNegativeClassification() {
        #expect(event(.useful).isPositive)
        #expect(event(.doMoreLikeThis).isPositive)
        #expect(event(.dismissed).isNegative)
        #expect(event(.tooBroad).isNegative)
        #expect(event(.tooNoisy).isNegative)
        #expect(event(.doLessLikeThis).isNegative)
        #expect(!event(.wrongReason).isPositive && !event(.wrongReason).isNegative)
    }

    @Test func aggregatesPositivePatterns() {
        let summary = AIFeedbackAggregator.summarize([
            event(.useful, tokens: ["release", "checksum"]),
            event(.useful, tokens: ["checksum", "release"]), // 同一组(顺序无关)
            event(.dismissed, tokens: ["downloads-cleanup"])
        ])
        let release = summary.positivePatterns.first { $0.tokens == ["checksum", "release"] }
        #expect(release?.count == 2)
        #expect(summary.negativePatterns.contains { $0.tokens == ["downloads-cleanup"] && $0.count == 1 })
    }

    @Test func aggregatesTagCorrections() {
        let summary = AIFeedbackAggregator.summarize([
            event(.wrongTag, target: .archiveRole, from: "source-package", to: "test-fixture"),
            event(.wrongTag, target: .archiveRole, from: "source-package", to: "test-fixture"),
            event(.wrongTag, target: .archiveRole, from: "release-package", to: "backup-package")
        ])
        let c = summary.tagCorrections.first { $0.from == "source-package" }
        #expect(c?.to == "test-fixture")
        #expect(c?.count == 2)
        #expect(summary.tagCorrections.count == 2)
    }

    @Test func emptyEventsYieldEmptySummary() {
        #expect(AIFeedbackAggregator.summarize([]).isEmpty)
    }

    @Test func summaryIsDeterministic() {
        let events = [
            event(.useful, tokens: ["a", "b"]),
            event(.dismissed, tokens: ["c"]),
            event(.wrongTag, from: "x", to: "y")
        ]
        #expect(AIFeedbackAggregator.summarize(events) == AIFeedbackAggregator.summarize(events))
    }

    @Test func patternsSortedByCountDescending() {
        let summary = AIFeedbackAggregator.summarize([
            event(.useful, id: "1", tokens: ["rare"]),
            event(.useful, id: "2", tokens: ["common"]),
            event(.useful, id: "3", tokens: ["common"])
        ])
        #expect(summary.positivePatterns.first?.tokens == ["common"])
        #expect(summary.positivePatterns.first?.count == 2)
    }
}
