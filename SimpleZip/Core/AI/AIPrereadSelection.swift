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
        return rankAndTake(records.filter { isPrereadSummarizable($0.type) },
                           budget: budget, now: now, interest: interestRoleTags, halfLifeDays: recencyHalfLifeDays)
    }

    /// **AI 建议显示阈值**(②c):一个文件的「AI 建议评分」要 ≥ 这个值,才值得花一次端上模型去产出一句话摘要 +
    /// 建议动作。判据 = 同一套预读价值评分(角色 + 近期 + 兴趣)。门槛卡在「文档级文字」:project-doc / report /
    /// document / release-notes / note 这类天然过线;config / reference-data 要靠近期或兴趣加权才过;checksum /
    /// media 基本永不过线。用户原话:「至少这个文件评分要接近 ai 建议显示的阈值,一句话总结完才有价值,才触发 ai 建议」。
    static let suggestionScoreThreshold: Double = 2.5

    /// 一个文件的「AI 建议评分」(标量)。**与 `context(for:)` 同一套权重**(角色重要性 + 近期修改 + 用户兴趣),
    /// 只是这里求和成单值用于阈值门控。改一处务必同步另一处。
    static func suggestionScore(for record: AIFileMemoryRecord, now: Date,
                               interestRoleTags: Set<String> = [], recencyHalfLifeDays: Double = 14) -> Double {
        var score = roleWeight(record.roleTags)
        if let mod = record.modifiedAt {
            let days = max(0, now.timeIntervalSince(mod) / 86_400)
            let recency = pow(0.5, days / max(0.5, recencyHalfLifeDays))
            if recency > 0 { score += recency * 2.0 }
        }
        if !interestRoleTags.isEmpty, !interestRoleTags.isDisjoint(with: Set(record.roleTags)) { score += 1.5 }
        return score
    }

    /// 从一批已预读(有结构摘要)的文件记录里挑「该让模型出一句话摘要 + 建议动作」的前 `budget` 个(②b/②c)。
    /// 门控三连:① 文本可总结类(同预读 eligibility,排源码 / 二进制 / 媒体 / 归档);② **已有结构摘要但模型摘要
    /// 还没产出**(`contentSummary != nil && shortSummary == nil`)—— 指纹变了时阶段一会把摘要清回 nil,于是自动
    /// 重新进入候选(渐进覆盖,和预读同款);③ **AI 建议评分 ≥ 显示阈值**(拒绝给低价值文件白费模型)。
    /// 再按评分排序取前 budget(高价值先做)。空预算 → 空。
    static func selectForModelSuggestion(records: [AIFileMemoryRecord], budget: Int, now: Date,
                                         interestRoleTags: Set<String> = [],
                                         recencyHalfLifeDays: Double = 14) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        let eligible = records.filter { rec in
            isPrereadSummarizable(rec.type)
                && rec.contentSummary != nil
                && (rec.contentSummary?.shortSummary?.isEmpty ?? true)
                && suggestionScore(for: rec, now: now, interestRoleTags: interestRoleTags,
                                   recencyHalfLifeDays: recencyHalfLifeDays) >= suggestionScoreThreshold
        }
        return rankAndTake(eligible, budget: budget, now: now,
                           interest: interestRoleTags, halfLifeDays: recencyHalfLifeDays)
    }

    /// 从一批已预读记录里挑「**阈值下、空闲时也慢慢补摘要**」的前 `budget` 个(backlog 第5项:阈值当优先级而非硬闸)。
    /// 与 `selectForModelSuggestion` 互补 —— 同样要求文本可总结 + 已有结构摘要 + 模型摘要还没出,但**评分 < 显示阈值**
    /// (高分的由 `selectForModelSuggestion` 先吃)。按评分排序取前 budget。**每文件一次**,做完后台逐渐平静。
    /// 调用方只在高分队列吃不满预算(都补完了)时用它填剩余预算 → 高价值永远优先,空闲再轮到长尾。空预算 → 空。
    static func selectForIdleSummary(records: [AIFileMemoryRecord], budget: Int, now: Date,
                                     interestRoleTags: Set<String> = [],
                                     recencyHalfLifeDays: Double = 14) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        let eligible = records.filter { rec in
            isPrereadSummarizable(rec.type)
                && rec.contentSummary != nil
                && (rec.contentSummary?.shortSummary?.isEmpty ?? true)
                && suggestionScore(for: rec, now: now, interestRoleTags: interestRoleTags,
                                   recencyHalfLifeDays: recencyHalfLifeDays) < suggestionScoreThreshold
        }
        return rankAndTake(eligible, budget: budget, now: now,
                           interest: interestRoleTags, halfLifeDays: recencyHalfLifeDays)
    }

    /// 从一批记录里挑「最该**列清单**」的归档前 `budget` 个(归档内容预读用)。和 `selectForSummary` **同一套排序**
    /// (角色 / 近期 / 兴趣);归档角色统一(archive,同权重),故实际由近期 + 兴趣主导 —— 近期碰过 / 改过的包先列。
    /// 「指纹没变就跳过、变了重列」的渐进覆盖由调用方按归档清单缓存的 (大小+修改时间) 先筛掉再传进来。
    static func selectArchivesForListing(records: [AIFileMemoryRecord], budget: Int, now: Date,
                                         interestRoleTags: Set<String> = []) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        return rankAndTake(records.filter { $0.type == .archive },
                           budget: budget, now: now, interest: interestRoleTags, halfLifeDays: 14)
    }

    /// 从一批记录里挑「该评估 App 安装建议」的 `.dmg` 前 `budget` 个(磁盘镜像建议用 —— backlog 推荐打开方式之后)。
    /// 门控:① 是磁盘镜像;② **还没评估过**(`contentSummary == nil` —— 评估后会写一条 `disk-image` 摘要标记已评估,
    /// 指纹变了时阶段一把摘要清回 nil 即自动重新进入候选,渐进覆盖同款);③ 有真实路径(7zz 只读 peek 要用)。
    /// 排序复用同一套(installer 角色权重低 → 实际由近期主导:近期下载 / 改过的 dmg 先评估)。空预算 → 空。
    static func selectDiskImagesForSuggestion(records: [AIFileMemoryRecord], budget: Int, now: Date,
                                              interestRoleTags: Set<String> = []) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        let eligible = records.filter {
            $0.type == .diskImage && $0.contentSummary == nil && $0.path != nil
        }
        return rankAndTake(eligible, budget: budget, now: now, interest: interestRoleTags, halfLifeDays: 14)
    }

    /// 从已预读文本记录里挑「可重读脱敏头部并抽 URL」的前 `budget` 个。真正的 URL 抽取和模型筛选在 App 层;
    /// Core 只做 eligibility:文本可总结、有结构摘要、有真实路径、还没有 `urlOpen` 结果。
    static func selectForURLSuggestion(records: [AIFileMemoryRecord], budget: Int, now: Date,
                                       interestRoleTags: Set<String> = []) -> [AIFileMemoryRecord] {
        guard budget > 0 else { return [] }
        let eligible = records.filter {
            isPrereadSummarizable($0.type)
                && $0.contentSummary != nil
                && $0.path != nil
                && $0.contentSummary?.action(forToken: "urlOpen") == nil
        }
        return rankAndTake(eligible, budget: budget, now: now, interest: interestRoleTags, halfLifeDays: 14)
    }

    /// 排序 + 取前 N(共用:summary 和 archive 两个入口都走这,只是各自的 eligibility 过滤不同)。
    private static func rankAndTake(_ records: [AIFileMemoryRecord], budget: Int, now: Date,
                                    interest: Set<String>, halfLifeDays: Double) -> [AIFileMemoryRecord] {
        guard !records.isEmpty else { return [] }
        let ranked = AIRanker.rank(records) { rec in
            context(for: rec, now: now, interestRoleTags: interest, halfLifeDays: halfLifeDays)
        }
        return Array(ranked.prefix(budget).map(\.item))
    }

    /// 预读「能不能总结」判据(和通用 `enrichable` 不同,专为预读)。
    /// - **纳入所有可能是文本的类型**:md / text / config / checksum + `unknown` —— 覆盖**无后缀文本**和
    ///   `.log` / `.csv` 这类未识别文本(unix 生态极常见);真二进制由读取时的 UTF-8 判定剔除(只浪费一次读)。
    /// - **排除源码**:端上 3B 模型读不懂代码,预读纯浪费预算。
    /// - 排除已知二进制 / 媒体 / 归档 / 应用包 / 签名 / 文件夹。
    static func isPrereadSummarizable(_ type: AIFileType) -> Bool {
        switch type {
        case .markdown, .text, .config, .checksum, .unknown: return true
        case .sourceCode: return false
        case .folder, .archive, .signature, .image, .video, .audio,
             .appBundle, .diskImage, .package, .binary: return false
        }
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

    /// 角色 → **预读价值**权重。判据不是「文件类型重不重要」,而是「**LLM 读了这类文件能拿到多少独特、有效的
    /// 上下文 token**」。所以 source/report/task-summary 浮顶,checksum/media/installer 沉底(纯二进制 / 无结构 →
    /// 读它浪费预算)。覆盖系统里实际出现的全部 tag(类型兜底 / 名称覆盖 / 虚拟节点三套来源),不漏到 default。
    static func roleWeight(_ roleTags: [String]) -> Double {
        let set = Set(roleTags)
        // Tier 1:项目级文字知识 —— LLM 从这里得到最多独特上下文。
        if set.contains("project-doc") { return 5.0 }
        // Tier 2:高密度结构化文本。
        if set.contains("report") { return 4.5 }
        if set.contains("source") { return 4.0 }
        // Tier 3:历史 / 任务上下文 —— 对 AI 建议直接有用。
        if set.contains("task-summary") { return 3.5 }
        if set.contains("release-notes") { return 3.5 }
        if set.contains("task") { return 3.0 }
        if set.contains("document") { return 3.0 }
        if set.contains("note") { return 2.5 }
        // Tier 4:辅助文本 —— 有内容但质量参差。
        if set.contains("reference-data") { return 2.0 }
        if set.contains("config") { return 1.8 }
        if set.contains("action") { return 1.5 }
        // Tier 5:有限价值。
        if set.contains("archive") { return 0.8 }
        if set.contains("importance-low") { return 0.3 }
        if set.contains("installer") { return 0.3 }
        // Tier 6:二进制 / 无结构 —— 预读浪费带宽。
        if set.contains("checksum") || set.contains("signature") || set.contains("integrity-data") { return 0.2 }
        if set.contains("media") { return 0.1 }
        if set.contains("junk") || set.contains("temporary") { return 0.1 }
        return 0.4
    }
}
