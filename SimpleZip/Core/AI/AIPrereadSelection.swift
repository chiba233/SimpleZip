//
//  AIPrereadSelection.swift
//  SimpleZip
//
//  0.4.5 #80:**AI 驱动的预读选择**(用户拍板,见 memory ai_suggestion_inline_direction)。
//
//  旧逻辑(`summarizeIfWorthwhile`)用**死规则**挑要不要读内容:只有 md / 配置 / 校验自动读,text / 源码要命中
//  marker 才读 —— 文件一多,用户关心的文件「到死都排不上」。新逻辑:文件太多读不完,就用**确定性 AI 排序**
//  (角色重要性 / 近期修改 / 用户兴趣)把预算花在最该读的前 N 个文件上,长尾低价值文件不读(无所谓)。
//
//  复用现有排序原语 `AIRanker` + 可读性判定 `AIFileReadabilityPolicy.enrichable`(不另造)。只挑**文本可总结**类
//  (md/text/source/config/checksum);二进制 / 媒体 / 归档 / 应用包不进(无文本总结,office/PDF 二期)。
//  纯函数 + 确定性,SwiftPM 可断言。**不读文件系统、不跑模型** —— 只决定「该读哪些」,真正读内容 + 端上模型
//  总结由 App 侧后台索引器对选中集执行。
//

import Foundation

nonisolated enum AIPrereadSelection {
    /// 从一批文件记录里挑「最该做内容总结」的前 `budget` 个(预算化,确定性)。
    ///
    /// - Parameters:
    ///   - records: 本轮可选的文件记录(已过红线:疑似密钥文件在扫描层就没生成记录)。
    ///   - budget: 本轮最多读多少篇(预算,来自活跃度档位)。
    ///   - now: 当前时间(App 传入,Core 不读墙钟)—— 算近期衰减用。
    ///   - interestRoleTags: 用户近期常碰的角色标签(`AIInterestSummary` 派生),命中加权。
    ///   - recencyHalfLifeDays: 近期衰减半衰期(天)。
    /// - Returns: 排序后取前 budget 的记录(高价值在前)。空预算 → 空。
    static func selectForSummary(
        records: [AIFileMemoryRecord],
        budget: Int,
        now: Date,
        interestRoleTags: Set<String> = [],
        recencyHalfLifeDays: Double = 14
    ) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        // 只挑文本可总结类(复用现有可读性判定;记录到这里已非密钥文件,故 contentReadable 视为 true)。
        let summarizable = records.filter {
            AIFileReadabilityPolicy.enrichable(type: $0.type, contentReadable: true)
        }
        guard !summarizable.isEmpty else { return [] }
        let ranked = AIRanker.rank(summarizable) { rec in
            context(for: rec, now: now, interestRoleTags: interestRoleTags, halfLifeDays: recencyHalfLifeDays)
        }
        return Array(ranked.prefix(budget).map(\.item))
    }

    /// 一条记录的排序上下文:角色重要性 + 近期修改 + 用户兴趣(全正向 boost,确定性)。
    private static func context(for rec: AIFileMemoryRecord, now: Date,
                                interestRoleTags: Set<String>, halfLifeDays: Double) -> AIRankingContext {
        var signals: [AIRankingSignal] = []
        signals.append(.boost("role", roleWeight(rec.roleTags), reason: "role-importance"))
        if let mod = rec.modifiedAt {
            let days = max(0, now.timeIntervalSince(mod) / 86_400)
            let recency = pow(0.5, days / max(0.5, halfLifeDays))   // 1(刚改)→ 0(久远)
            if recency > 0 { signals.append(.boost("recency", recency * 2.0, reason: "recent-modification")) }
        }
        if !interestRoleTags.isEmpty, !interestRoleTags.isDisjoint(with: Set(rec.roleTags)) {
            signals.append(.boost("interest", 1.5, reason: "recent-user-interest"))
        }
        return AIRankingContext(base: 0, signals: signals)
    }

    /// 角色 → 总结价值权重。项目文档 / 发布说明最值得读;参考数据 / 通用文档次之;源码 / 配置再次。
    static func roleWeight(_ roleTags: [String]) -> Double {
        let set = Set(roleTags)
        if set.contains("project-doc") || set.contains("release-notes") { return 3.0 }
        if set.contains("document") || set.contains("reference-data") { return 2.0 }
        if set.contains("integrity-data") || set.contains("checksum") || set.contains("signature") { return 1.5 }
        if set.contains("source") { return 1.0 }
        if set.contains("config") { return 0.8 }
        return 0.5
    }
}
