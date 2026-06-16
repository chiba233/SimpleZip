//
//  AIStartupSuggestion.swift
//  SimpleZip
//
//  0.4.5 #80:基于时间习惯的智能启动目录(白皮书工程补充九)。「晚上常打开哪个目录、常做什么」——
//  很适合本地 AI:不需要世界知识,只需要本机习惯事件、时间段、最近项目和当前可用路径。
//
//  关键:**候选只来自用户已给过 App 上下文的路径**(启动目录 / last folder / custom history / pinned-recent /
//  预索引白名单 / 工作区绑定目录 / 最近打开对象所在目录),确定性打分为主,模型只对相近候选起标题 / 写理由。
//  真正打开目录时 App 只接受 candidate id 再回查 URL —— 模型不能直接返回路径被执行。
//
//  这里只放纯值类型 + 确定性时间分桶 + 确定性排序;`aiStartupSuggestionMode` 的 AppPreferences 接线、
//  GeneralPane UI、候选采集在 App 层。纯函数,SwiftPM 可断言。
//

import Foundation

/// 智能启动建议模式(独立于现有 `StartupLocation`,避免破坏欢迎页 / 健康检查 / 设置备份)。
nonisolated enum AIStartupSuggestionMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// 保持现有启动目录逻辑。
    case off
    /// 仍打开配置目录,但启动后显示「今晚常用目录」建议(推荐默认)。
    case suggestOnly = "suggest-only"
    /// 从候选里打开最匹配的真实目录(须用户明确开启)。
    case openBestMatch = "open-best-match"
    /// 打开最匹配的 AI 虚拟工作区,而不是真实目录。
    case openWorkspace = "open-workspace"
}

/// 一天的时间分桶(稳定英文 token)。
nonisolated enum AITimeBucket: String, Codable, Equatable, CaseIterable, Sendable {
    case morning   // 05:00–11:59
    case afternoon // 12:00–17:59
    case evening   // 18:00–21:59
    case night     // 22:00–04:59

    /// 由小时(0–23)确定性分桶。越界小时归 night。
    static func bucket(forHour hour: Int) -> AITimeBucket {
        switch hour {
        case 5...11: return .morning
        case 12...17: return .afternoon
        case 18...21: return .evening
        default: return .night
        }
    }
}

nonisolated enum AIWeekdayBucket: String, Codable, Equatable, CaseIterable, Sendable {
    case weekday
    case weekend
}

/// 一个启动候选目录(从兴趣事件按时间桶聚合而来)。不含完整路径 —— 用 source ref + 低敏信号 + 可见别名。
nonisolated struct AIStartupCandidate: Codable, Equatable, Sendable {
    let sourceRef: AIContextSourceRef
    let locationKind: String
    /// 用户可见别名(固定路径别名 / 目录名),已脱敏。
    let displayAlias: String
    /// 同一时间桶内最近 30 天访问次数(主排序信号)。
    let visitsInSameBucket: Int
    let medianDwellSeconds: Int
    /// 距上次打开的天数(越小越新)。
    let recencyDays: Int
    /// 负面信号数量(打开后秒退 / 点过不感兴趣)。
    let negativeSignalCount: Int

    init(sourceRef: AIContextSourceRef, locationKind: String, displayAlias: String,
         visitsInSameBucket: Int, medianDwellSeconds: Int = 0, recencyDays: Int = 0,
         negativeSignalCount: Int = 0) {
        self.sourceRef = sourceRef
        self.locationKind = locationKind
        self.displayAlias = displayAlias
        self.visitsInSameBucket = visitsInSameBucket
        self.medianDwellSeconds = medianDwellSeconds
        self.recencyDays = recencyDays
        self.negativeSignalCount = negativeSignalCount
    }
}

/// 候选 + 确定性分数(给调试 / 模型挑相近候选)。
nonisolated struct AIStartupRankedCandidate: Codable, Equatable, Sendable {
    let candidate: AIStartupCandidate
    let score: Double
}

nonisolated enum AIStartupDirectoryRanker {
    /// 确定性打分排序:访问次数为主,停留时长 / 新鲜度加分,负面信号减分。同分按 source ref id 稳定升序。
    static func rank(_ candidates: [AIStartupCandidate]) -> [AIStartupRankedCandidate] {
        candidates
            .map { AIStartupRankedCandidate(candidate: $0, score: score($0)) }
            .sorted {
                $0.score != $1.score ? $0.score > $1.score : $0.candidate.sourceRef.id < $1.candidate.sourceRef.id
            }
    }

    /// 最匹配候选:最高分且 ≥ 阈值,否则 nil(信号太弱时不乱开目录,退回配置目录)。
    /// 默认阈值 4.0 ≈ 至少几次重复访问 —— 单次访问的目录不会被当作「最匹配」自动打开。
    static func bestMatch(_ candidates: [AIStartupCandidate], minScore: Double = 4.0) -> AIStartupCandidate? {
        guard let top = rank(candidates).first, top.score >= minScore else { return nil }
        return top.candidate
    }

    /// 访问次数对数压缩(防旧目录雪球)+ 指数新鲜度(半衰期 14d);停留封顶 +1.0,负面信号每个 -2.0。
    /// 旧公式: visits 线性无界 + linear recency → 40d 旧目录永远压过 1d 新目录(startup_correct=0 bug)。
    /// 新公式: log2(visits+1) 让访问差从 2.0 压到 0.26; exp recency 差 0.81 > 0.26 → 新目录胜出。
    static func score(_ c: AIStartupCandidate) -> Double {
        let visits = log2(Double(c.visitsInSameBucket) + 1)                  // 对数压缩，防雪球
        let dwell = min(1.0, Double(c.medianDwellSeconds) / 600.0)
        let recency = pow(0.5, Double(c.recencyDays) / 14.0)                 // 指数衰减，半衰期 14d
        let penalty = 2.0 * Double(c.negativeSignalCount)
        return visits + dwell + recency - penalty
    }
}
