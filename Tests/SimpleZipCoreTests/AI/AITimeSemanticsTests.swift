//
//  AITimeSemanticsTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:统一时间语义(白皮书工程补充一·加固 4)。年龄桶 / 最近窗口 / 时段规律,确定性、不取 wall-clock。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AITimeSemanticsTests {
    private let now = Date(timeIntervalSince1970: 100_000_000)
    private func ago(_ seconds: Int) -> Date { now.addingTimeInterval(-Double(seconds)) }

    // MARK: - 年龄事实

    @Test func ageFactsBuckets() {
        #expect(AIAgeFacts.make(from: ago(1_800), now: now).bucket == .justNow)        // 30 min
        #expect(AIAgeFacts.make(from: ago(5 * 3_600), now: now).bucket == .today)        // 5h
        #expect(AIAgeFacts.make(from: ago(3 * 86_400), now: now).bucket == .thisWeek)     // 3d
        #expect(AIAgeFacts.make(from: ago(10 * 86_400), now: now).bucket == .thisMonth)   // 10d
        #expect(AIAgeFacts.make(from: ago(60 * 86_400), now: now).bucket == .thisQuarter) // 60d
        let stale = AIAgeFacts.make(from: ago(200 * 86_400), now: now)
        #expect(stale.bucket == .stale)
        #expect(stale.isStale)
        #expect(stale.ageDays == 200)
    }

    @Test func ageFactsClampsFutureToJustNow() {
        let future = AIAgeFacts.make(from: now.addingTimeInterval(10_000), now: now)
        #expect(future.ageSeconds == 0)
        #expect(future.bucket == .justNow)
    }

    // MARK: - 最近窗口

    @Test func timeWindowContains() {
        #expect(AITimeWindow.last10Minutes.contains(ago(300), now: now))   // 5 min 内
        #expect(!AITimeWindow.last10Minutes.contains(ago(1_200), now: now)) // 20 min 外
        #expect(!AITimeWindow.last10Minutes.contains(now.addingTimeInterval(60), now: now)) // 未来不算
        #expect(AITimeWindow.last7Days.contains(ago(3 * 86_400), now: now))
        #expect(AITimeWindow.common.count == 5)
    }

    // MARK: - 时段规律

    @Test func temporalPatternEmptyIsNil() {
        let p = AITemporalPattern.detect(hourWeekdayPairs: [])
        #expect(p.dominantBucket == nil)
        #expect(p.sampleCount == 0)
        #expect(!p.isConcentrated)
    }

    @Test func temporalPatternDetectsConcentratedEvening() {
        let p = AITemporalPattern.detect(hourWeekdayPairs: [
            (19, false), (20, false), (21, false), (19, false),
        ])
        #expect(p.dominantBucket == .evening)
        #expect(p.isConcentrated)                 // 4/4 ≥ 0.6
        #expect(p.dominantWeekday == .weekday)
        #expect(p.sampleCount == 4)
    }

    @Test func temporalPatternNotConcentratedWhenSpread() {
        let p = AITemporalPattern.detect(hourWeekdayPairs: [
            (19, false), (20, false), (9, false), (14, false),
        ])
        #expect(p.dominantBucket == .evening)     // evening 2 vs morning/afternoon 1
        #expect(!p.isConcentrated)                // 2/4 = 0.5 < 0.6
    }

    @Test func temporalPatternWeekendDominant() {
        let p = AITemporalPattern.detect(hourWeekdayPairs: [
            (10, true), (11, true), (14, false),
        ])
        #expect(p.dominantWeekday == .weekend)    // 周末 2 * 2 > 3
    }

    @Test func temporalPatternDeterministicTieBreak() {
        // morning 与 evening 各 1 → 按桶声明序(morning 在 evening 前)稳定取 morning。
        let a = AITemporalPattern.detect(hourWeekdayPairs: [(9, false), (19, false)])
        let b = AITemporalPattern.detect(hourWeekdayPairs: [(19, false), (9, false)])
        #expect(a == b)
        #expect(a.dominantBucket == .morning)
    }
}
