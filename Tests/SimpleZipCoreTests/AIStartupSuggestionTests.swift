//
//  AIStartupSuggestionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:智能启动目录 —— 模式/时间分桶/确定性排序(工程补充九)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIStartupSuggestionTests {
    private func candidate(_ id: String, visits: Int, dwell: Int = 0, recency: Int = 0, negatives: Int = 0)
        -> AIStartupCandidate {
        AIStartupCandidate(sourceRef: AIContextSourceRef(kind: .folder, id: id),
                           locationKind: "project-folder", displayAlias: id,
                           visitsInSameBucket: visits, medianDwellSeconds: dwell,
                           recencyDays: recency, negativeSignalCount: negatives)
    }

    @Test func everyModeAndBucketHasStableToken() {
        for m in AIStartupSuggestionMode.allCases { #expect(!m.rawValue.isEmpty) }
        for b in AITimeBucket.allCases { #expect(!b.rawValue.isEmpty) }
    }

    @Test func timeBucketsByHour() {
        #expect(AITimeBucket.bucket(forHour: 8) == .morning)
        #expect(AITimeBucket.bucket(forHour: 14) == .afternoon)
        #expect(AITimeBucket.bucket(forHour: 20) == .evening)
        #expect(AITimeBucket.bucket(forHour: 23) == .night)
        #expect(AITimeBucket.bucket(forHour: 3) == .night)
    }

    @Test func moreVisitsRankHigher() {
        let ranked = AIStartupDirectoryRanker.rank([
            candidate("downloads", visits: 4), candidate("release", visits: 12)
        ])
        #expect(ranked.first?.candidate.sourceRef.id == "release")
    }

    @Test func negativeSignalsDemote() {
        // 同访问次数,有负面信号的降到后面。
        let ranked = AIStartupDirectoryRanker.rank([
            candidate("noisy", visits: 6, negatives: 3), candidate("liked", visits: 6)
        ])
        #expect(ranked.first?.candidate.sourceRef.id == "liked")
    }

    @Test func bestMatchRespectsThreshold() {
        // 单次访问、无其它信号 → 分数低于阈值 2.0 → nil。
        #expect(AIStartupDirectoryRanker.bestMatch([candidate("weak", visits: 1)]) == nil)
        #expect(AIStartupDirectoryRanker.bestMatch([candidate("strong", visits: 9)])?.sourceRef.id == "strong")
    }

    @Test func freshnessBreaksVisitTies() {
        let ranked = AIStartupDirectoryRanker.rank([
            candidate("stale", visits: 5, recency: 18), candidate("fresh", visits: 5, recency: 0)
        ])
        #expect(ranked.first?.candidate.sourceRef.id == "fresh")
    }

    @Test func rankingIsDeterministic() {
        let cands = [candidate("b", visits: 3), candidate("a", visits: 3)]
        #expect(AIStartupDirectoryRanker.rank(cands) == AIStartupDirectoryRanker.rank(cands))
        // 同分按 id 升序。
        #expect(AIStartupDirectoryRanker.rank(cands).first?.candidate.sourceRef.id == "a")
    }

    @Test func candidateRoundTripsThroughCodable() throws {
        let c = candidate("x", visits: 3, dwell: 120, recency: 2)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(AIStartupCandidate.self, from: data) == c)
    }
}
