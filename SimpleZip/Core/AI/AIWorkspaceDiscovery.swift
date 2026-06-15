//
//  AIWorkspaceDiscovery.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 文件夹的**多源候选组装 + 发现流水线**(白皮书统一框架的中段)。
//
//      全局 AI 数据层 → [本文件] 组装候选池 → 跨位置语义聚类 → 衰减抑制 → 排序主题
//
//  把全局 AI 数据层的各类**派生记录**(持久文件索引 `AIFileMemoryRecord`、活动任务 `AITaskRecord`,后续接
//  归档画像 / 归档内非加密条目 / 版本关系 / 发布账本)统一映射成 `AIVirtualNodeCandidate`,喂给跨位置语义
//  聚类器。**位置只随候选带过去当注意力权重,绝不作内容边界 / 成员资格**(见 `AIWorkspaceThemeEngine`)。
//
//  红线:映射只用已脱敏的派生记录字段(文件名 / 角色 / marker / 内容摘要的标题与字段名 / 任务标题与路径
//  token);绝不引入口令 / 密钥 / 加密条目名 / 完整路径。纯值 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 推荐质量 + 数量策略(白皮书 / 用户:**完整、有质量的工作区才能自动推荐,数量必须有限制**)。
/// 「完整」= 足够成员 + 跨源 / 跨位置 / 上规模(不是随手 2-3 个同目录文件那种你本来就能浏览的);数量封顶。
nonisolated struct AIRecommendationPolicy: Equatable, Sendable {
    /// 进聚类的最小簇大小(传给引擎)。
    let minClusterSize: Int
    /// 成为推荐的最小成员数。
    let minMembers: Int
    /// 成员数达到此值即视为「上规模」,直接算有质量(无需跨源信号)。
    let richMemberCount: Int
    /// 侧边栏推荐工作区数量上限。
    let maxThemes: Int
    /// 是否启用质量门控(关掉只看成员数 —— 测机制用)。
    let gateQuality: Bool

    init(minClusterSize: Int = 3, minMembers: Int = 3, richMemberCount: Int = 5,
         maxThemes: Int = 6, gateQuality: Bool = true) {
        self.minClusterSize = max(2, minClusterSize)
        self.minMembers = max(2, minMembers)
        self.richMemberCount = max(self.minMembers, richMemberCount)
        self.maxThemes = max(1, maxThemes)
        self.gateQuality = gateQuality
    }

    static let `default` = AIRecommendationPolicy()
    /// 测机制用:不卡质量、允许 2 成员。
    static let permissive = AIRecommendationPolicy(minClusterSize: 2, minMembers: 2, gateQuality: false)

    /// 「完整 / 有质量」判定:足够成员,且(上规模 OR 跨位置 OR 混了任务 / 归档 / 报告)。
    func isQuality(_ t: AIWorkspaceThemeCandidate) -> Bool {
        guard t.sourceRefs.count >= minMembers else { return false }
        guard gateQuality else { return true }
        if t.sourceRefs.count >= richMemberCount { return true }
        if t.scoreSignals.contains(where: { $0.hasPrefix("cross-location") }) { return true }
        let richKinds: Set<String> = ["has-task", "has-archive", "has-report"]
        return t.scoreSignals.contains(where: { richKinds.contains($0) })
    }
}

nonisolated enum AIWorkspaceDiscovery {
    /// 发现结果:放行的主题(已排序 + 质量门控 + 数量封顶)+ 被衰减抑制压住的(主题 + 当前抑制权重,供「为什么没推荐」)。
    nonisolated struct Output: Equatable, Sendable {
        let themes: [AIWorkspaceThemeCandidate]
        let suppressed: [SuppressedTheme]
    }

    nonisolated struct SuppressedTheme: Equatable, Sendable {
        let theme: AIWorkspaceThemeCandidate
        let weight: Double
    }

    /// 端到端:组装候选池 → 跨位置聚类 → **质量门控** → 套衰减抑制 → **数量封顶** → 输出。
    /// `attention` 只影响排序,`suppression` 过滤已不感兴趣,`policy` 决定「完整才推荐 + 数量上限」。
    static func discover(
        files: [AIFileMemoryRecord] = [],
        tasks: [AITaskRecord] = [],
        attention: AIAttentionContext = AIAttentionContext(),
        suppression: AIThemeSuppressionLedger = AIThemeSuppressionLedger(),
        now: Date,
        policy: AIRecommendationPolicy = .default
    ) -> Output {
        let pool = assemblePool(files: files, tasks: tasks)
        let all = AIWorkspaceThemeEngine.discoverThemes(
            from: pool, attention: attention, now: now, minClusterSize: policy.minClusterSize)
        let quality = all.filter(policy.isQuality)            // 完整才推荐
        let part = suppression.partition(quality, now: now)
        let capped = Array(part.kept.prefix(policy.maxThemes))  // 数量有限
        return Output(themes: capped,
                      suppressed: part.suppressed.map { SuppressedTheme(theme: $0.candidate, weight: $0.weight) })
    }

    /// 多源 → 统一候选池(去重 by candidate id)。
    static func assemblePool(files: [AIFileMemoryRecord] = [],
                             tasks: [AITaskRecord] = []) -> [AIVirtualNodeCandidate] {
        var pool: [AIVirtualNodeCandidate] = []
        var seen = Set<String>()
        func add(_ c: AIVirtualNodeCandidate) { if seen.insert(c.id).inserted { pool.append(c) } }
        for r in files { add(candidate(from: r)) }
        for r in tasks { add(candidate(from: r)) }
        return pool
    }

    // MARK: - 记录 → 候选(映射器)

    /// 持久文件索引记录 → 候选。归档自身 id(按名字派生)进 `relatedArchiveIDs`,便于和「同名归档的条目 /
    /// 处理它的任务」连通。语义 token 取 marker + 内容摘要的标题 / 字段名(已脱敏)。
    static func candidate(from r: AIFileMemoryRecord) -> AIVirtualNodeCandidate {
        let kind: AIVirtualNode.Kind = r.type == .folder ? .folder : (r.type == .archive ? .archive : .file)
        let refKind: AIContextSourceRef.Kind = kind == .folder ? .folder : (kind == .archive ? .archive : .file)
        let archiveIDs = kind == .archive ? [archiveID(forName: r.fileName)] : []
        var semantic = r.markerTags
        if let s = r.contentSummary { semantic += s.headings + s.fieldNames }
        return AIVirtualNodeCandidate(
            id: "cand-" + r.id, kind: kind, displayName: r.fileName,
            sourceRefs: [AIContextSourceRef(kind: refKind, id: r.id)],
            roleTags: r.roleTags, location: r.location,
            relatedArchiveIDs: archiveIDs,
            semanticTokens: dedup(semantic))
    }

    /// 活动任务记录 → 任务候选。`relatedArchiveIDs` 取归档名派生 id(连通到同名归档 / 其条目);语义 token 取
    /// 输入 / 输出名 + 归档名 + 路径 token(都已脱敏),让任务能按语义连到它处理过的文件 / 归档。
    static func candidate(from r: AITaskRecord) -> AIVirtualNodeCandidate {
        let archiveIDs = r.files.archiveName.map { [archiveID(forName: $0)] } ?? []
        let semantic = r.files.inputNames + r.files.outputNames
            + (r.files.archiveName.map { [$0] } ?? []) + r.files.pathTokens
        let locKind = AILocationKind(rawValue: r.files.locationKinds.first ?? "other") ?? .other
        let loc = AILocationContext(kind: locKind, pathHash: "loc-task-" + r.id,
                                    folderNameTokens: Array(r.files.pathTokens.prefix(6)))
        return AIVirtualNodeCandidate(
            id: "cand-" + r.id, kind: .task, displayName: r.title,
            sourceRefs: [AIContextSourceRef(kind: .task, id: r.id)],
            roleTags: dedup(["task", r.category]), location: loc,
            relatedTaskIDs: [r.id], relatedArchiveIDs: archiveIDs,
            semanticTokens: dedup(semantic),
            scoreSignals: [r.status])
    }

    // MARK: - 工具

    /// 归档名 → 稳定连通 id(同名归档 / 其条目 / 处理它的任务共享此 id 即连通)。名字已脱敏、小写。
    static func archiveID(forName name: String) -> String {
        "arc-" + AIStableHash.stableID64((name as NSString).lastPathComponent.lowercased())
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }
}
