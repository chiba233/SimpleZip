//
//  AITimeSemantics.swift
//  SimpleZip
//
//  0.4.5 #80:统一时间语义工具(白皮书工程补充一·加固 4)。让「昨晚失败」「最近 10 分钟」「长期未动」
//  「同一时段反复失败」不再由每个场景各自解析。活动中心的 startedAt / finishedAt / durationSeconds、
//  文件 modifiedAt / lastOpenedAt、归档打开时间都折进这几个结构,供工作区主题、动作排序、启动目录共用。
//
//  时段 / 工作日桶复用 AIStartupSuggestion.swift 的 `AITimeBucket` / `AIWeekdayBucket`(不重造,A2)。
//  **Core 不取 wall-clock、不做时区解析** —— `now` 与每个时刻的 (hour, isWeekend) 由 App 用 Calendar 提取后
//  传入,本层只做确定性算术与分桶,SwiftPM 可断言。
//

import Foundation

/// 「某事多久以前发生 / 多久没动过」的年龄事实。从一个时刻 + App 提供的 `now` 算出,绝不自取时钟。
nonisolated struct AIAgeFacts: Codable, Equatable, Sendable {
    /// 粗粒度年龄桶(稳定英文 token)。
    nonisolated enum Bucket: String, Codable, Equatable, CaseIterable, Sendable {
        case justNow      // < 1h
        case today        // < 24h
        case thisWeek     // < 7d
        case thisMonth    // < 30d
        case thisQuarter  // < 90d
        case stale        // >= 90d(长期未动)
    }

    /// 距 `now` 的秒数(已钳到 >= 0:未来时刻视为刚刚)。
    let ageSeconds: Int
    let ageDays: Int
    let bucket: Bucket

    /// 从「事件时刻」与「现在」确定性算出。`now < date`(时钟回拨 / 未来时间戳)钳为 age 0 → justNow。
    static func make(from date: Date, now: Date) -> AIAgeFacts {
        let raw = now.timeIntervalSince(date)
        let seconds = Int(max(0, raw))
        let days = seconds / 86_400
        return AIAgeFacts(ageSeconds: seconds, ageDays: days, bucket: bucket(forSeconds: seconds))
    }

    static func bucket(forSeconds s: Int) -> Bucket {
        switch s {
        case ..<3_600: return .justNow
        case ..<86_400: return .today
        case ..<604_800: return .thisWeek
        case ..<2_592_000: return .thisMonth
        case ..<7_776_000: return .thisQuarter
        default: return .stale
        }
    }

    /// 长期未动(≥ 90 天)—— 驱动「长期未动的大文件」这类工作区主题。
    var isStale: Bool { bucket == .stale }
}

/// 一个命名的「最近窗口」(最近 10 分钟 / 24 小时 / 7 天 / 30 天)。判定某时刻是否落在窗口内。
nonisolated struct AITimeWindow: Codable, Equatable, Sendable {
    /// 稳定英文 token(`last-10-min` / `last-24h` / `last-7d` / `last-30d`)。
    let label: String
    let seconds: Int

    /// 某时刻是否在 `[now - seconds, now]` 内(未来时刻不算落入)。
    func contains(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= Double(seconds)
    }

    static let last10Minutes = AITimeWindow(label: "last-10-min", seconds: 600)
    static let lastHour = AITimeWindow(label: "last-1h", seconds: 3_600)
    static let last24Hours = AITimeWindow(label: "last-24h", seconds: 86_400)
    static let last7Days = AITimeWindow(label: "last-7d", seconds: 604_800)
    static let last30Days = AITimeWindow(label: "last-30d", seconds: 2_592_000)

    static let common: [AITimeWindow] = [last10Minutes, lastHour, last24Hours, last7Days, last30Days]
}

/// 一串时刻的时段规律(白皮书:「同一时间段反复失败」「晚上常打开某项目」)。从 App 预提取的
/// (hour, isWeekend) 序列确定性聚合 —— 时区 / Calendar 解析在 App 侧,本层只分桶计数。
nonisolated struct AITemporalPattern: Codable, Equatable, Sendable {
    nonisolated struct BucketCount: Codable, Equatable, Sendable {
        let bucket: AITimeBucket
        let count: Int
    }

    /// 最常出现的时段桶(样本为空则 nil)。
    let dominantBucket: AITimeBucket?
    /// 最常出现的工作日 / 周末桶。
    let dominantWeekday: AIWeekdayBucket?
    let bucketCounts: [BucketCount]
    /// 是否集中在某一时段(主桶占比 ≥ 阈值)。
    let isConcentrated: Bool
    let sampleCount: Int

    /// 从 App 预提取的 (hour 0–23, isWeekend) 序列检测规律。`concentrationThreshold` 默认 0.6。
    static func detect(hourWeekdayPairs pairs: [(hour: Int, isWeekend: Bool)],
                       concentrationThreshold: Double = 0.6) -> AITemporalPattern {
        guard !pairs.isEmpty else {
            return AITemporalPattern(dominantBucket: nil, dominantWeekday: nil,
                                     bucketCounts: [], isConcentrated: false, sampleCount: 0)
        }
        var bucketCounts: [AITimeBucket: Int] = [:]
        var weekendCount = 0
        for pair in pairs {
            bucketCounts[AITimeBucket.bucket(forHour: pair.hour), default: 0] += 1
            if pair.isWeekend { weekendCount += 1 }
        }
        // 确定性排序:计数降序,再按桶声明序(CaseIterable index)稳定 tie-break。
        let order = Dictionary(uniqueKeysWithValues: AITimeBucket.allCases.enumerated().map { ($1, $0) })
        let counts = bucketCounts
            .map { BucketCount(bucket: $0.key, count: $0.value) }
            .sorted { a, b in
                a.count != b.count ? a.count > b.count : (order[a.bucket] ?? 0) < (order[b.bucket] ?? 0)
            }
        let dominant = counts.first
        let total = pairs.count
        let concentrated = (dominant.map { Double($0.count) / Double(total) } ?? 0) >= concentrationThreshold
        let weekday: AIWeekdayBucket = weekendCount * 2 > total ? .weekend : .weekday
        return AITemporalPattern(dominantBucket: dominant?.bucket, dominantWeekday: weekday,
                                 bucketCounts: counts, isConcentrated: concentrated, sampleCount: total)
    }
}
