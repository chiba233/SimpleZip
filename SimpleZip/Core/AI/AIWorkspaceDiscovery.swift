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

nonisolated enum AIWorkspaceDiscovery {
    /// 发现结果:放行的主题(已排序)+ 被衰减抑制压住的(主题 + 当前抑制权重,供「为什么没推荐」)。
    nonisolated struct Output: Equatable, Sendable {
        let themes: [AIWorkspaceThemeCandidate]
        let suppressed: [SuppressedTheme]
    }

    nonisolated struct SuppressedTheme: Equatable, Sendable {
        let theme: AIWorkspaceThemeCandidate
        let weight: Double
    }

    /// 端到端:组装候选池 → 跨位置聚类 → 套衰减抑制 → 输出。`attention` 只影响排序,`suppression` 过滤已不感兴趣。
    static func discover(
        files: [AIFileMemoryRecord] = [],
        tasks: [AITaskRecord] = [],
        attention: AIAttentionContext = AIAttentionContext(),
        suppression: AIThemeSuppressionLedger = AIThemeSuppressionLedger(),
        now: Date,
        minClusterSize: Int = 2
    ) -> Output {
        let pool = assemblePool(files: files, tasks: tasks)
        let all = AIWorkspaceThemeEngine.discoverThemes(
            from: pool, attention: attention, now: now, minClusterSize: minClusterSize)
        let part = suppression.partition(all, now: now)
        return Output(themes: part.kept,
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
