//
//  AIRankingTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:统一 ranking 三件套(白皮书工程补充一·加固 8)。可解释升权 / 降权 / 压制,确定性。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIRankingTests {

    @Test func boostDemoteConvenience() {
        #expect(AIRankingSignal.boost("recency", 0.3, reason: "opened-today").delta == 0.3)
        #expect(AIRankingSignal.demote("dismissed", 0.5, reason: "user-x").delta == -0.5)
        // 给 boost 负数也会被取绝对值(防调用方传错符号)。
        #expect(AIRankingSignal.boost("x", -0.2, reason: "r").delta == 0.2)
    }

    @Test func evaluateSumsSignals() {
        let ctx = AIRankingContext(base: 0.4, signals: [
            .boost("recency", 0.3, reason: "r1"), .demote("stale", 0.1, reason: "r2"),
        ])
        #expect(AIRankingDecision.evaluate(ctx).score == 0.6)   // 0.4 + 0.3 - 0.1
    }

    @Test func verdictPromotedNeutralDemoted() {
        #expect(AIRankingDecision.evaluate(
            AIRankingContext(base: 0, signals: [.boost("a", 0.5, reason: "r")])).verdict == .promoted)
        #expect(AIRankingDecision.evaluate(
            AIRankingContext(base: 0.5, signals: [])).verdict == .neutral)
        // 净降但未压制(分数仍 ≥ 阈值 0)。
        #expect(AIRankingDecision.evaluate(
            AIRankingContext(base: 0.5, signals: [.demote("b", 0.2, reason: "r")])).verdict == .demoted)
    }

    @Test func verdictSuppressedBelowThreshold() {
        let d = AIRankingDecision.evaluate(
            AIRankingContext(base: 0.1, signals: [.demote("c", 0.5, reason: "x")], suppressionThreshold: 0))
        #expect(d.suppressed)
        #expect(d.verdict == .suppressed)
        #expect(d.score == -0.4)
    }

    @Test func rankedSignalsByInfluence() {
        let d = AIRankingDecision.evaluate(AIRankingContext(base: 0, signals: [
            .boost("z", 0.1, reason: "r"), .demote("a", 0.5, reason: "r"), .boost("m", 0.5, reason: "r"),
        ]))
        // |delta| 降序;两个 0.5 按 kind 升序(a < m),再 0.1 的 z。
        #expect(d.rankedSignals.map(\.kind) == ["a", "m", "z"])
    }

    @Test func rankerDropsSuppressedAndSortsByScore() {
        let contexts: [String: AIRankingContext] = [
            "A": AIRankingContext(base: 0.5),
            "B": AIRankingContext(base: 0.9),
            "C": AIRankingContext(base: 0.1, signals: [.demote("d", 0.5, reason: "r")]),  // → -0.4 压制
        ]
        let ranked = AIRanker.rank(["A", "B", "C"]) { contexts[$0]! }
        #expect(ranked.map(\.item) == ["B", "A"])   // C 被剔除,B(0.9) > A(0.5)
    }

    @Test func rankerStableOnTies() {
        let ranked = AIRanker.rank(["X", "Y", "Z"]) { _ in AIRankingContext(base: 0.5) }
        #expect(ranked.map(\.item) == ["X", "Y", "Z"])   // 同分保持输入序
    }

    @Test func codableRoundTrip() throws {
        let d = AIRankingDecision.evaluate(AIRankingContext(base: 0.3, signals: [.boost("k", 0.2, reason: "r")]))
        #expect(try JSONDecoder().decode(AIRankingDecision.self, from: JSONEncoder().encode(d)) == d)
    }
}
