//
//  AIVirtualFolderPlan.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 文件夹**虚拟目录树的薄 plan + builder**(白皮书建议四「AI 虚拟目录的数据结构必须这样落地」
//  1315-1390)。这是当前 AI 工作区「看起来有入口但没有 AI 价值」的核心缺口的填补:`AIWorkspaceStore.virtualTree`
//  不再返回 nil,而是 `候选 → plan → sanitized tree`。
//
//  分工(白皮书硬约束):
//  - **App 确定性召回** `AIVirtualNodeCandidate`(文件 / 归档 / 条目 / 任务 / 报告 / 动作),并打分;
//  - **模型只产薄 plan**:目录标题 / 层级 / 哪些 candidate 放进哪个目录 / 短理由 —— **绝不输出路径**,绝不发明 id;
//  - 模型不可用时,`AIVirtualFolderPlanner.deterministicPlan` 用 roleTags 出**确定性整理**(UI 必须如实标注,
//    不伪装成 AI 生成);
//  - App 把 plan 合并成 `.group` 节点 + `AIVirtualNodeCandidate.toNode()` 叶子,最终 `AIVirtualFolderTree(...).sanitized()`。
//
//  安全:plan 里的 `candidateIDs` 必须能回查到候选,否则丢弃;group title 只做展示,绝不当真实路径 / 绝不写盘;
//  节点动作由 `AIVirtualNodeActionDeriver` 按 kind + 候选集内 source ref **安全推导**(模型不发明路径)。
//
//  纯 Codable 值类型 + 确定性,SwiftPM 可断言。
//

import Foundation

// MARK: - Plan 输入(喂给模型的受控 JSON,非自然语言)

/// 一个工作区的 **prompt-safe 投影**(白皮书 JSON 示例 `workspace`)。只携带受控子集,绝不含真实路径。
nonisolated struct AIWorkspacePromptFact: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    /// `system` / `userCreated` / `recommended`(`AIWorkspace.Origin.rawValue`)。
    let origin: String
    let prompt: String?
    /// query plan 的语义 token(给模型理解主题意图,不含路径)。
    let queryTokens: [String]

    init(id: UUID, title: String, origin: String, prompt: String? = nil, queryTokens: [String] = []) {
        self.id = id
        self.title = title
        self.origin = origin
        self.prompt = prompt
        self.queryTokens = queryTokens
    }

    /// 从一个 `AIWorkspace` 投影(query plan 的语义 / 任务 / 关键词 token 汇成 queryTokens,封顶去重)。
    init(workspace: AIWorkspace) {
        let plan = workspace.queryPlan
        var tokens: [String] = []
        for t in plan.semanticTags + plan.taskTags + plan.keywords + plan.markerFiles
        where !t.isEmpty && !tokens.contains(t) { tokens.append(t) }
        self.init(id: workspace.id, title: workspace.title, origin: workspace.origin.rawValue,
                  prompt: workspace.prompt, queryTokens: Array(tokens.prefix(14)))
    }
}

/// 一个虚拟节点候选的 **prompt 投影**(白皮书 JSON 示例 `candidates[]`)。`candidateID` 回查
/// `AIVirtualNodeCandidate.id`;`kind` 用 token(file / folder / archive / archiveEntry / task / report / action / note)。
nonisolated struct AIVirtualNodePromptCandidate: Codable, Equatable, Sendable {
    let candidateID: String
    let kind: String
    let displayName: String
    let sourceRefs: [AIContextSourceRef]
    let roleTags: [String]
    let scoreSignals: [String]
    let relatedTaskIDs: [String]
    let relatedArchiveIDs: [String]
    let evidence: [AIEvidenceFact]

    init(candidateID: String, kind: String, displayName: String,
         sourceRefs: [AIContextSourceRef] = [], roleTags: [String] = [],
         scoreSignals: [String] = [], relatedTaskIDs: [String] = [],
         relatedArchiveIDs: [String] = [], evidence: [AIEvidenceFact] = []) {
        self.candidateID = candidateID
        self.kind = kind
        self.displayName = displayName
        self.sourceRefs = sourceRefs
        self.roleTags = roleTags
        self.scoreSignals = scoreSignals
        self.relatedTaskIDs = relatedTaskIDs
        self.relatedArchiveIDs = relatedArchiveIDs
        self.evidence = evidence
    }

    /// 从 Core 候选投影(kind 转 token)。
    init(candidate: AIVirtualNodeCandidate) {
        self.init(candidateID: candidate.id, kind: candidate.kind.rawValue,
                  displayName: candidate.displayName, sourceRefs: candidate.sourceRefs,
                  roleTags: candidate.roleTags, scoreSignals: candidate.scoreSignals,
                  relatedTaskIDs: candidate.relatedTaskIDs, relatedArchiveIDs: candidate.relatedArchiveIDs,
                  evidence: candidate.evidence)
    }
}

/// 候选准备指标:量化本轮喂给模型的输入质量(压制了多少噪声、强信号覆盖率、kind 多样性)。
nonisolated struct AIVirtualFolderPrepareMetrics: Equatable, Sendable {
    /// 传入的原始候选总数。
    let inputCount: Int
    /// 被模式折叠压制的候选数(同语义任务群中只保留代表)。
    let suppressedCount: Int
    /// 最终输出给模型的候选数。
    let outputCount: Int
    /// 各重要级别分布:key = "high" / "normal" / "low"。
    let tierCounts: [String: Int]
    /// 各 kind 分布:key = kind.rawValue。
    let kindCounts: [String: Int]
    /// strongTokens 在输出候选中的覆盖率(0.0–1.0);strongTokens 为空时为 0.0。
    let strongTokenCoverage: Double

    static func zero(inputCount: Int) -> Self {
        AIVirtualFolderPrepareMetrics(inputCount: inputCount, suppressedCount: 0, outputCount: 0,
                                      tierCounts: [:], kindCounts: [:], strongTokenCoverage: 0.0)
    }
}

/// 给小模型看的候选输入预处理器。3B 适合最后一厘米的命名 / 分组,不适合从 raw 候选里自己判断权重;
/// 因此 App 先在 Core 里确定性分层:重复任务泛化折叠、加权信号评分、强项目信号提权、探索槽保底。
nonisolated enum AIVirtualFolderModelInputPreparer {
    static let defaultMaxCandidates = 50

    /// 准备 prompt 候选并返回量化指标。
    static func prepareWithMetrics(
        candidates: [AIVirtualNodeCandidate],
        strongTokens: [String],
        maxCandidates: Int = defaultMaxCandidates
    ) -> (candidates: [AIVirtualNodePromptCandidate], metrics: AIVirtualFolderPrepareMetrics) {
        guard maxCandidates > 0 else {
            return ([], .zero(inputCount: candidates.count))
        }
        let strong = Set(strongTokens.map(normalizeToken).filter { !$0.isEmpty && !genericTokens.contains($0) })
        let deduped = dedupe(candidates)
        let (collapsed, suppressedIDs) = collapsedPatternSummaries(from: deduped)
        let originalByID = Dictionary(deduped.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var tierByID: [String: String] = [:]
        var scored: [(AIVirtualNodePromptCandidate, Double)] = deduped.compactMap { candidate in
            guard !suppressedIDs.contains(candidate.id) else { return nil }
            let score = importanceScore(candidate, strongTokens: strong)
            let label = importanceLabel(score)
            tierByID[candidate.id] = label
            return (promptCandidate(from: candidate, importance: label), score)
        }
        for c in collapsed {
            tierByID[c.candidateID] = "low"
            scored.append((c, 0.6))
        }

        let selected = layeredSelection(scored, maxCandidates: maxCandidates)

        // 指标计算。
        let tierCounts = selected.reduce(into: [String: Int]()) {
            $0[tierByID[$1.0.candidateID] ?? "normal", default: 0] += 1
        }
        let kindCounts = selected.reduce(into: [String: Int]()) { $0[$1.0.kind, default: 0] += 1 }
        let selectedOriginals = selected.compactMap { originalByID[$0.0.candidateID] }
        let allSelectedTokens = selectedOriginals.reduce(into: Set<String>()) { $0.formUnion(candidateTokens($1)) }
        let coverage = strong.isEmpty ? 0.0
            : Double(strong.intersection(allSelectedTokens).count) / Double(strong.count)

        let metrics = AIVirtualFolderPrepareMetrics(
            inputCount: candidates.count, suppressedCount: suppressedIDs.count,
            outputCount: selected.count, tierCounts: tierCounts, kindCounts: kindCounts,
            strongTokenCoverage: coverage)

        return (selected.map(\.0), metrics)
    }

    /// 仅返回候选列表(向后兼容)。
    static func prepare(candidates: [AIVirtualNodeCandidate],
                        strongTokens: [String],
                        maxCandidates: Int = defaultMaxCandidates) -> [AIVirtualNodePromptCandidate] {
        prepareWithMetrics(candidates: candidates, strongTokens: strongTokens,
                           maxCandidates: maxCandidates).candidates
    }

    private static let genericTokens: Set<String> = [
        "agent", "agents", "hash", "checksum", "sha", "sha256", "task", "tasks", "succeeded", "success",
        "desktop", "downloads", "documents", "download", "file", "files", "folder", "folders", "archive",
        "archives", "recent", "today", "tmp", "temp", "data", "final", "report", "readme", "md"
    ]

    private static func dedupe(_ candidates: [AIVirtualNodeCandidate]) -> [AIVirtualNodeCandidate] {
        var seen = Set<String>()
        var result: [AIVirtualNodeCandidate] = []
        for candidate in candidates {
            let key = candidate.sourceRefs.map { "\($0.kind.rawValue):\($0.id)" }.sorted().joined(separator: "|")
            let stableKey = key.isEmpty ? candidate.id : key
            guard seen.insert(stableKey).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    // MARK: - 泛化任务模式折叠

    /// 已知重复任务语义模式(按匹配优先级排序,第一个命中即为正则名)。
    private static let taskPatternPriority: [(tokens: Set<String>, canonical: String)] = [
        (["hash", "checksum", "sha", "sha256", "sha512", "md5", "crc", "digest"], "hash"),
        (["compress", "zip", "pack", "tar", "gz"], "compress"),
        (["test", "integrity", "validate", "verify"], "integrity"),
        (["sign", "gpg", "signature", "clearsign", "pgp"], "sign"),
        (["extract", "unzip", "unpack", "decompress", "expand"], "extract"),
        (["convert", "transform", "transcode", "migrate"], "convert"),
    ]

    private static func dominantTaskPattern(_ candidate: AIVirtualNodeCandidate) -> String? {
        let tokens = candidateTokens(candidate)
        for (patternTokens, canonical) in taskPatternPriority {
            if !tokens.isDisjoint(with: patternTokens) { return canonical }
        }
        return nil
    }

    /// 泛化折叠:同一语义模式 ≥4 个任务 → 保留最多 2 个代表 + 1 条摘要。
    /// 任务候选按主导模式聚类(≥4 个同模式才成簇),每簇按「失败优先 + id」稳定排序。
    /// `collapsedPatternSummaries`(模型输入)与 `patternSummaryMembers`(builder 回查)**共用**这一份聚类,
    /// 保证两边算出同一批 `pattern-…` id —— 模型引用的折叠摘要 id,builder 一定查得到全部成员。
    private static func patternClusters(from candidates: [AIVirtualNodeCandidate])
        -> [(pattern: String, ranked: [AIVirtualNodeCandidate])] {
        let tasks = candidates.filter { $0.kind == .task }
        guard tasks.count >= 4 else { return [] }
        var clusters: [String: [AIVirtualNodeCandidate]] = [:]
        for task in tasks {
            if let pattern = dominantTaskPattern(task) {
                clusters[pattern, default: []].append(task)
            }
        }
        return clusters.compactMap { entry in
            guard entry.value.count >= 4 else { return nil }
            let ranked = entry.value.sorted {
                let aFailed = $0.scoreSignals.contains("failed")
                let bFailed = $1.scoreSignals.contains("failed")
                if aFailed != bFailed { return aFailed }
                return $0.id < $1.id
            }
            return (entry.key, ranked)
        }
    }

    /// 折叠摘要的稳定合成 id(模型看到的、builder 回查的都用这一份)。
    static func patternSummaryID(pattern: String, ranked: [AIVirtualNodeCandidate]) -> String {
        "pattern-\(pattern)-\(AIStableHash.fnv1a32Hex(ranked.map(\.id).joined(separator: "|")))"
    }

    /// builder 回查:模型引用的折叠摘要 `pattern-…` id → 被折叠的**全部成员候选**(含被 suppressed 的)。
    /// 折叠只为压缩模型输入的 token 预算;虚拟树里这些任务照常展开,不能因为引用了摘要 id 就静默丢(BUG-P1)。
    static func patternSummaryMembers(from candidates: [AIVirtualNodeCandidate])
        -> [String: [AIVirtualNodeCandidate]] {
        var map: [String: [AIVirtualNodeCandidate]] = [:]
        for cluster in patternClusters(from: dedupe(candidates)) {
            map[patternSummaryID(pattern: cluster.pattern, ranked: cluster.ranked)] = cluster.ranked
        }
        return map
    }

    private static func collapsedPatternSummaries(from candidates: [AIVirtualNodeCandidate])
        -> ([AIVirtualNodePromptCandidate], Set<String>) {
        let clusters = patternClusters(from: candidates)
        guard !clusters.isEmpty else { return ([], []) }
        var summaries: [AIVirtualNodePromptCandidate] = []
        var suppressed = Set<String>()
        for (pattern, ranked) in clusters {
            let keepCount = min(2, ranked.count)
            suppressed.formUnion(ranked.dropFirst(keepCount).map(\.id))
            let representative = ranked[0]
            summaries.append(AIVirtualNodePromptCandidate(
                candidateID: patternSummaryID(pattern: pattern, ranked: ranked),
                kind: representative.kind.rawValue,
                displayName: "\(pattern.capitalized) tasks · \(ranked.count) items · latest: \(representative.displayName)",
                sourceRefs: representative.sourceRefs,
                roleTags: ["task-summary", "repeated-\(pattern)-tasks", "importance-low"],
                scoreSignals: ["collapsed:\(ranked.count)", "collapsedReason=repeated_\(pattern)_tasks", "importance=low"],
                relatedTaskIDs: Array(ranked.flatMap(\.relatedTaskIDs).prefix(12)),
                relatedArchiveIDs: Array(ranked.flatMap(\.relatedArchiveIDs).prefix(8)),
                evidence: Array(ranked.flatMap(\.evidence).prefix(6))))
        }
        return (summaries, suppressed)
    }

    // MARK: - 加权信号评分

    /// 信号权重表。结构化信号(含 ":")视为 0,未知平文本信号视为弱正(0.2)。
    private static let signalWeights: [String: Double] = [
        "project-token": 3.0,
        "source-ref-match": 1.0,
        "failed": 3.0,
        "running": 2.0,
        "recent-interaction": 1.5,
        "same-parent": 1.0,
        "document": 0.5,
        "source": 0.5,
        "same-name": 0.3,
        "recent": 0.3,
        "succeeded": -0.5,
        "repeated": -1.0,
    ]

    private static func signalScore(_ signals: [String]) -> Double {
        signals.reduce(0.0) { $0 + (signalWeights[$1] ?? ($1.contains(":") ? 0.0 : 0.2)) }
    }

    private static func promptCandidate(from candidate: AIVirtualNodeCandidate,
                                        importance: String) -> AIVirtualNodePromptCandidate {
        var roles = candidate.roleTags
        let marker = "importance-\(importance)"
        if !roles.contains(marker) { roles.append(marker) }
        var signals = candidate.scoreSignals
        let signal = "importance=\(importance)"
        if !signals.contains(signal) { signals.append(signal) }
        return AIVirtualNodePromptCandidate(
            candidateID: candidate.id, kind: candidate.kind.rawValue,
            displayName: candidate.displayName, sourceRefs: candidate.sourceRefs,
            roleTags: roles, scoreSignals: signals,
            relatedTaskIDs: candidate.relatedTaskIDs, relatedArchiveIDs: candidate.relatedArchiveIDs,
            evidence: candidate.evidence)
    }

    private static func importanceLabel(_ score: Double) -> String {
        if score >= 7 { return "high" }
        if score <= 1 { return "low" }
        return "normal"
    }

    /// 分层选取:每层有硬性 budget 上限,避免低权重条目填满剩余槽。
    private static func layeredSelection(_ scored: [(AIVirtualNodePromptCandidate, Double)],
                                         maxCandidates: Int) -> [(AIVirtualNodePromptCandidate, Double)] {
        let sorted = scored.sorted(by: sortScored)
        guard sorted.count > maxCandidates else { return sorted }

        let high   = sorted.filter { $0.1 >= 7 }
        let normal = sorted.filter { $0.1 >= 1 && $0.1 < 7 }
        let low    = sorted.filter { $0.1 < 1 }

        // explorationBudget = low 层的硬上限(不是 floor);maxCandidates<4 时不保留探索槽。
        let explorationBudget = low.isEmpty || maxCandidates < 4
            ? 0 : max(1, min(low.count, maxCandidates / 5))
        // normalBudget = 约 2/5 的剩余槽,按实际数量封顶。
        let normalBudget = normal.isEmpty ? 0
            : min(normal.count, max(1, (maxCandidates - explorationBudget) * 2 / 5))
        let highBudget = maxCandidates - normalBudget - explorationBudget

        var result: [(AIVirtualNodePromptCandidate, Double)] = []
        var used = Set<String>()

        func take(_ items: [(AIVirtualNodePromptCandidate, Double)], budget: Int) {
            guard budget > 0 else { return }
            var taken = 0
            for item in items where taken < budget && used.insert(item.0.candidateID).inserted {
                result.append(item)
                taken += 1
            }
        }

        take(high,   budget: highBudget)
        take(normal, budget: normalBudget)
        take(low,    budget: explorationBudget)
        // 填剩余槽(任一层条目不足时补位)。
        take(sorted, budget: maxCandidates - result.count)

        return result.sorted(by: sortScored)
    }

    private static func sortScored(_ a: (AIVirtualNodePromptCandidate, Double),
                                   _ b: (AIVirtualNodePromptCandidate, Double)) -> Bool {
        if a.1 != b.1 { return a.1 > b.1 }
        if a.0.displayName != b.0.displayName { return a.0.displayName < b.0.displayName }
        return a.0.candidateID < b.0.candidateID
    }

    private static func importanceScore(_ candidate: AIVirtualNodeCandidate, strongTokens: Set<String>) -> Double {
        let tokens = candidateTokens(candidate)
        var score = signalScore(candidate.scoreSignals)
        score += Double(tokens.intersection(strongTokens).count) * 4.0
        score += roleWeight(candidate.roleTags)
        score += locationWeight(candidate.location?.kind)
        score += kindWeight(candidate.kind)
        score -= Double(tokens.intersection(genericTokens).count) * 0.8
        return score
    }

    private static func roleWeight(_ roles: [String]) -> Double {
        let normalized = Set(roles.map(normalizeToken))
        var score = 0.0
        if !normalized.isDisjoint(with: [
            "source", "code", "docs", "document", "project-doc", "release-notes",
            "reference-data", "integrity-data", "spec", "reader"
        ]) { score += 2.0 }
        if !normalized.isDisjoint(with: ["project-doc", "release-notes", "reference-data", "integrity-data"]) {
            score += 1.0
        }
        if !normalized.isDisjoint(with: ["junk", "temporary"]) { score -= 2.0 }
        if !normalized.isDisjoint(with: ["checksum"]) { score -= 0.8 }
        return score
    }

    private static func locationWeight(_ kind: AILocationKind?) -> Double {
        switch kind {
        case .projectFolder: return 2.0
        case .documents: return 0.8
        case .desktop, .downloads: return -0.6
        case .temporaryWorkspace: return -1.0
        case .externalDrive, .sameDirectory, .other, nil: return 0
        }
    }

    private static func kindWeight(_ kind: AIVirtualNode.Kind) -> Double {
        switch kind {
        case .file, .folder, .archive, .archiveEntry: return 0.5
        case .task: return -1.0
        case .report: return 0.2
        case .group, .action, .automation, .note: return 0
        }
    }

    private static func candidateTokens(_ candidate: AIVirtualNodeCandidate) -> Set<String> {
        var tokens = Set(candidate.semanticTokens.map(normalizeToken).filter { !$0.isEmpty })
        tokens.formUnion(splitTokens(candidate.displayName))
        tokens.formUnion(candidate.roleTags.map(normalizeToken).filter { !$0.isEmpty })
        tokens.formUnion(candidate.location?.folderNameTokens.map(normalizeToken).filter { !$0.isEmpty } ?? [])
        return tokens
    }

    private static func splitTokens(_ s: String) -> Set<String> {
        var result = Set<String>()
        // 标准扫:按字母/数字逐字符分组,过滤 <2 char 片段。
        var current = ""
        func flush() {
            let token = normalizeToken(current)
            if token.count >= 2 { result.insert(token) }
            current = ""
        }
        for ch in s {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        // 补充段式切割:按连字符/下划线/空格整段保留 —— 版本号「0.4.5」等以整体 token 入集,
        // 否则只剩「0」「4」「5」三个单字符被过滤掉,强 token 永远无法命中。
        for seg in s.components(separatedBy: CharacterSet(charactersIn: " -_")) {
            let token = normalizeToken(seg)
            if token.count >= 2 { result.insert(token) }
        }
        return result
    }

    private static func normalizeToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 一个允许动作的 **prompt 描述符**(白皮书 `allowedActions`)。让模型知道有哪些动作可用,但**不让模型拼动作负载**
/// —— 动作负载(路径 / id)由 App 按候选集回查。
nonisolated struct AISuggestionActionDescriptor: Codable, Equatable, Sendable {
    /// 稳定动作 token(hash / createArchive / test / inspect / search / openWith …)。
    let id: String
    /// 适用的节点 kind token(file / archive / …);空 = 通用。
    let appliesToKinds: [String]
    let requiresConfirmation: Bool
    let userVisibleLabel: String

    init(id: String, appliesToKinds: [String] = [], requiresConfirmation: Bool = false,
         userVisibleLabel: String) {
        self.id = id
        self.appliesToKinds = appliesToKinds
        self.requiresConfirmation = requiresConfirmation
        self.userVisibleLabel = userVisibleLabel
    }
}

/// 用户对 AI 生成目录的重命名偏好(白皮书 1346)。用户把「互联网资料」改成「参考网页」时,**不改 prompt 模板**,
/// 而是新增一条偏好,下次输入给模型学习该 workspace 的命名口味 —— 不变成全局硬编码。
nonisolated struct AIVirtualFolderNamingPreference: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let oldTitle: String
    let userTitle: String
    let matchedRoleTags: [String]
    let matchedEvidenceTokens: [String]
    let occurredAt: Date

    init(workspaceID: UUID, oldTitle: String, userTitle: String,
         matchedRoleTags: [String] = [], matchedEvidenceTokens: [String] = [], occurredAt: Date) {
        self.workspaceID = workspaceID
        self.oldTitle = oldTitle
        self.userTitle = userTitle
        self.matchedRoleTags = matchedRoleTags
        self.matchedEvidenceTokens = matchedEvidenceTokens
        self.occurredAt = occurredAt
    }
}

/// 用户对一个工作区的累积调教信号(架构债 #4 + 白皮书建议四:**自循环必须喂进模型 prompt**,不只 Swift 侧过滤)。
/// 用户固定 / 排除 / 喜欢 / 不喜欢 / 给分组起的名字,都要让模型知道 —— 这样它**学会**该工作区的口味(用户把源码
/// 拖进「源代码」组,以后同类也归源代码),而不是每轮从零分组。配合现有 `AIWorkspaceLearningStore` 的 Swift 侧软
/// 过滤(强负同类不喂),双管齐下。
///
/// 携带展示名(可带来源目录)、角色 token、用户起的分组名。**路径不是隐私风险,可以、也应该让模型看到**
/// (SimpleZip 只彻底保护额外加密的内容,见 [[feedback_privacy_only_encrypted]]);真正的红线只有加密条目名 / 内容、
/// 口令、密文、解密明文、无 read 权限 —— 这些这里本就不会出现(只有用户调教过的非加密成员的名字 / 目录 / 角色)。
nonisolated struct AIWorkspaceLearningHints: Codable, Equatable, Sendable {
    /// 用户明确留在这个工作区的成员(「我很喜欢」/ 手动加入 / 移动进来 → 都落进种子 pin),展示名 + 可选来源目录。
    /// 模型应优先保留同类。
    let keptItemNames: [String]
    /// 用户从这个工作区移除的成员(「我不喜欢」/ 从工作区移除),展示名 + 可选来源目录。模型应避免再把同类选进来。
    let removedItemNames: [String]
    /// 用户偏好的角色标签(来自被喜欢 / 固定的成员)—— 同角色候选更该进来。
    let preferredRoleTags: [String]
    /// 用户排斥的角色标签(来自被移除的成员)—— 同角色候选少进来。
    let rejectedRoleTags: [String]
    /// 用户给虚拟分组起过的名字(把某组叫「源代码」= 这个工作区关心「源代码」)—— 强主题信号,模型分组 / 命名应沿用。
    let userGroupTitles: [String]

    init(keptItemNames: [String] = [], removedItemNames: [String] = [],
         preferredRoleTags: [String] = [], rejectedRoleTags: [String] = [],
         userGroupTitles: [String] = []) {
        self.keptItemNames = keptItemNames
        self.removedItemNames = removedItemNames
        self.preferredRoleTags = preferredRoleTags
        self.rejectedRoleTags = rejectedRoleTags
        self.userGroupTitles = userGroupTitles
    }

    var isEmpty: Bool {
        keptItemNames.isEmpty && removedItemNames.isEmpty && preferredRoleTags.isEmpty
            && rejectedRoleTags.isEmpty && userGroupTitles.isEmpty
    }
}

/// plan 约束(白皮书 `constraints`)—— 防本地模型发散 + 防炸 UI。
nonisolated struct AIVirtualFolderPlanConstraints: Codable, Equatable, Sendable {
    let maxTopLevelGroups: Int
    let maxDepth: Int
    let maxTitleCharacters: Int
    let allowDuplicateSourceRefs: Bool
    let forbidFixedCategoryVocabulary: Bool

    init(maxTopLevelGroups: Int = 6, maxDepth: Int = 2, maxTitleCharacters: Int = 24,
         allowDuplicateSourceRefs: Bool = true, forbidFixedCategoryVocabulary: Bool = true) {
        self.maxTopLevelGroups = max(1, maxTopLevelGroups)
        self.maxDepth = max(1, maxDepth)
        self.maxTitleCharacters = max(4, maxTitleCharacters)
        self.allowDuplicateSourceRefs = allowDuplicateSourceRefs
        self.forbidFixedCategoryVocabulary = forbidFixedCategoryVocabulary
    }

    static let `default` = AIVirtualFolderPlanConstraints()
}

/// 喂给模型的完整 plan 输入(白皮书 `simplezip.ai.workspaceTreePlan.input.v1`)。
nonisolated struct AIVirtualFolderPlanInput: Codable, Equatable, Sendable {
    static let schemaID = "simplezip.ai.workspaceTreePlan.input.v1"
    let schema: String
    let workspace: AIWorkspacePromptFact
    let candidates: [AIVirtualNodePromptCandidate]
    let fileFacts: [AIFilePromptFact]
    let interactionSummary: AIInteractionCounterSummary?
    let evidenceGaps: [AIWorkspaceEvidenceGap]
    let allowedActions: [AISuggestionActionDescriptor]
    let userNamingPreferences: [AIVirtualFolderNamingPreference]
    /// 用户对该工作区的累积调教(固定 / 排除 / 喜欢 / 不喜欢 / 分组命名)—— 让模型据此学口味(架构债 #4)。
    /// optional:旧输入 / 无调教时为 nil(合成 Codable 对 optional 走 decodeIfPresent → 向后兼容)。
    let learningHints: AIWorkspaceLearningHints?
    let constraints: AIVirtualFolderPlanConstraints

    init(workspace: AIWorkspacePromptFact,
         candidates: [AIVirtualNodePromptCandidate],
         fileFacts: [AIFilePromptFact] = [],
         interactionSummary: AIInteractionCounterSummary? = nil,
         evidenceGaps: [AIWorkspaceEvidenceGap] = [],
         allowedActions: [AISuggestionActionDescriptor] = [],
         userNamingPreferences: [AIVirtualFolderNamingPreference] = [],
         learningHints: AIWorkspaceLearningHints? = nil,
         constraints: AIVirtualFolderPlanConstraints = .default) {
        self.schema = Self.schemaID
        self.workspace = workspace
        self.candidates = candidates
        self.fileFacts = fileFacts
        self.interactionSummary = interactionSummary
        self.evidenceGaps = evidenceGaps
        self.allowedActions = allowedActions
        self.userNamingPreferences = userNamingPreferences
        self.learningHints = learningHints
        self.constraints = constraints
    }
}

// MARK: - Plan 输出(模型 / 确定性产出)

/// 模型 / 确定性产出的薄 plan(白皮书 `simplezip.ai.workspaceTreePlan.output.v1`)。
nonisolated struct AIVirtualFolderPlan: Codable, Equatable, Sendable {
    static let schemaID = "simplezip.ai.workspaceTreePlan.output.v1"
    let schema: String
    let workspaceTitle: String?
    let groups: [AIVirtualFolderGroupPlan]
    /// 模型给具体节点的 AI 建议(纯模型生成,非硬编码常驻)。builder 据此给目标叶子挂 `.action` 子节点 →
    /// 有建议才可展开。空 = 这棵树没有 AI 建议(节点都不展开,只能右键)。
    let suggestions: [AINodeSuggestionPlan]

    init(workspaceTitle: String? = nil, groups: [AIVirtualFolderGroupPlan],
         suggestions: [AINodeSuggestionPlan] = []) {
        self.schema = Self.schemaID
        self.workspaceTitle = workspaceTitle
        self.groups = groups
        self.suggestions = suggestions
    }

    private enum CodingKeys: String, CodingKey { case schema, workspaceTitle, groups, suggestions }

    /// 旧 plan(无 `suggestions`)解码兼容 → 缺字段默认 []。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.schemaID
        self.workspaceTitle = try c.decodeIfPresent(String.self, forKey: .workspaceTitle)
        self.groups = try c.decodeIfPresent([AIVirtualFolderGroupPlan].self, forKey: .groups) ?? []
        self.suggestions = try c.decodeIfPresent([AINodeSuggestionPlan].self, forKey: .suggestions) ?? []
    }
}

/// 一个虚拟目录组 plan。`candidateIDs` 只能引用 input.candidates.candidateID;`title` 是 AI 生成的展示名,
/// **绝不是真实路径**。
nonisolated struct AIVirtualFolderGroupPlan: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let reason: String?
    let candidateIDs: [String]
    let children: [AIVirtualFolderGroupPlan]
    /// AI 注意力:是否「该让用户先看到」→ 默认展开这一组(其余收起)。**不是全部展开**(白皮书:折叠接入 AI 注意力)。
    let prominent: Bool

    init(id: String, title: String, reason: String? = nil,
         candidateIDs: [String] = [], children: [AIVirtualFolderGroupPlan] = [], prominent: Bool = false) {
        self.id = id
        self.title = title
        self.reason = reason
        self.candidateIDs = candidateIDs
        self.children = children
        self.prominent = prominent
    }

    private enum CodingKeys: String, CodingKey { case id, title, reason, candidateIDs, children, prominent }

    /// 旧缓存(无 `prominent`)解码兼容 → 缺字段默认 false。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.candidateIDs = try c.decodeIfPresent([String].self, forKey: .candidateIDs) ?? []
        self.children = try c.decodeIfPresent([AIVirtualFolderGroupPlan].self, forKey: .children) ?? []
        self.prominent = try c.decodeIfPresent(Bool.self, forKey: .prominent) ?? false
    }
}

/// 模型给**单个节点**的一条 AI 建议(白皮书建议四 + 用户点名:「ai suggestion 必须 ai 给明确信号才弹,不然只能
/// 右键;每个文件不该全都有展开;把全部功能给 ai 让它自己选」)。模型从 `allowedSuggestionDescriptors` 词表里给某个
/// 候选挑一个动作 token + 一句理由 —— **不拼路径 / 不拼负载**,负载由 App 按 token + 候选回查的路径安全合成。
/// 一个节点**有建议才可展开**(无建议没展开箭头);常驻压缩 / 哈希被这套取代。
nonisolated struct AINodeSuggestionPlan: Codable, Equatable, Sendable {
    /// 目标候选 id(回查 `input.candidates.candidateID`;界外 / 查不到则丢弃)。
    let targetCandidateID: String
    /// 动作 token(`allowedSuggestionDescriptors.id`:hash / compress / test / inspect / convert …)。
    let actionToken: String
    /// 一句给用户看的理由(可空)。
    let reason: String?

    init(targetCandidateID: String, actionToken: String, reason: String? = nil) {
        self.targetCandidateID = targetCandidateID
        self.actionToken = actionToken
        self.reason = reason
    }
}

// MARK: - 确定性 plan(模型不可用时的「确定性整理」)

/// 树的生成方式 —— UI 必须如实标注「确定性整理」,不能把 fallback 伪装成 AI 生成(白皮书 1390)。
nonisolated enum AIVirtualTreeGenerationMode: String, Codable, Equatable, Sendable {
    case deterministic
    case modelAssisted
}

nonisolated enum AIVirtualFolderPlanner {
    /// 模型不可用时的确定性 plan:按候选的 **bucket(kind + 首要 roleTag)** 分组,组标题用稳定 role token
    /// (View 侧本地化展示,raw token 作 fallback)。命中信号多的 bucket 优先;超出 `maxTopLevelGroups` 的
    /// bucket 合并进末尾 `other` 组,绝不丢候选。组内按 `rankNodes` 排序。
    static func deterministicPlan(candidates: [AIVirtualNodeCandidate],
                                  constraints: AIVirtualFolderPlanConstraints = .default)
        -> AIVirtualFolderPlan {
        guard !candidates.isEmpty else { return AIVirtualFolderPlan(groups: []) }

        // 1) 分桶(保持插入序的桶顺序,确定性)。
        var bucketOrder: [String] = []
        var buckets: [String: [AIVirtualNodeCandidate]] = [:]
        for candidate in candidates {
            let bucket = bucketToken(for: candidate)
            if buckets[bucket] == nil { bucketOrder.append(bucket); buckets[bucket] = [] }
            buckets[bucket]?.append(candidate)
        }

        // 2) 桶排序:候选数降序,同分按桶优先级,再按 token 升序(确定性)。
        let sortedBuckets = bucketOrder.sorted { a, b in
            let ca = buckets[a]?.count ?? 0, cb = buckets[b]?.count ?? 0
            if ca != cb { return ca > cb }
            let pa = bucketPriority(a), pb = bucketPriority(b)
            if pa != pb { return pa < pb }
            return a < b
        }

        // 3) 取前 N-1 个桶,其余候选并进末尾 `other` 组(不丢候选)。
        let limit = constraints.maxTopLevelGroups
        var groups: [AIVirtualFolderGroupPlan] = []
        let head = sortedBuckets.count > limit ? Array(sortedBuckets.prefix(limit - 1)) : sortedBuckets
        for bucket in head {
            let ranked = AIWorkspaceCandidateRanker.rankNodes(buckets[bucket] ?? [])
            groups.append(AIVirtualFolderGroupPlan(
                id: "det-" + bucket, title: bucket, reason: nil,
                candidateIDs: ranked.map(\.id),
                prominent: groups.isEmpty))   // 无模型时:默认只展开排第一(最相关)的那组,不全展开
        }
        if sortedBuckets.count > limit {
            let rest = sortedBuckets.dropFirst(limit - 1).flatMap { buckets[$0] ?? [] }
            let ranked = AIWorkspaceCandidateRanker.rankNodes(rest)
            groups.append(AIVirtualFolderGroupPlan(
                id: "det-other", title: "other", reason: nil, candidateIDs: ranked.map(\.id)))
        }
        return AIVirtualFolderPlan(workspaceTitle: nil, groups: groups)
    }

    /// 候选 → bucket token。文件 / 文件夹按首要 role;其余按 kind(动作 / 任务 / 报告各成一桶)。
    private static func bucketToken(for candidate: AIVirtualNodeCandidate) -> String {
        switch candidate.kind {
        case .file, .folder:
            return candidate.roleTags.first ?? "file"
        case .archive, .archiveEntry:
            return "archive"
        case .task:
            return "task"
        case .report:
            return "report"
        case .action, .automation:
            return "action"
        case .group, .note:
            return "note"
        }
    }

    /// 桶展示优先级(同候选数时:文件类内容靠前,动作 / 任务 / 报告靠后,`other` 最后)。
    private static func bucketPriority(_ token: String) -> Int {
        switch token {
        case "source": return 0
        case "document": return 1
        case "image", "media": return 2
        case "data": return 3
        case "archive": return 4
        case "checksum", "signature": return 5
        case "config": return 6
        case "report": return 7
        case "task": return 8
        case "action": return 9
        case "other": return 99
        default: return 50
        }
    }
}

// MARK: - 节点动作安全推导(模型不发明路径)

/// 按 kind + 候选集内 source ref **安全推导**节点主动作。模型从不输出路径 —— 路径 / 任务 id 一律由 App 侧
/// 回查后在这里生成(白皮书:「节点动作必须通过 `AISuggestionAction` 回到现有方法,不允许 view 自己拼路径」)。
nonisolated enum AIVirtualNodeActionDeriver {
    /// 推导一个候选的主动作。`pathsBySourceRef` 提供文件 / 归档 / 文件夹的真实路径(由 App 从 facts 回查)。
    /// `actionsByCandidateID` 给 `.action` 候选预置好动作(App 构造,因为动作负载来自模型 / 规则)。
    /// 取不到必要路径 / id 时返回 nil(节点仍展示,只是不可点)。
    static func primaryAction(
        for candidate: AIVirtualNodeCandidate,
        pathsBySourceRef: [AIContextSourceRef: String],
        actionsByCandidateID: [String: AISuggestionAction] = [:]
    ) -> AISuggestionAction? {
        switch candidate.kind {
        case .file:
            return candidate.sourceRefs.first.flatMap { pathsBySourceRef[$0] }.map { .revealFile(path: $0) }
        case .folder:
            return candidate.sourceRefs.first.flatMap { pathsBySourceRef[$0] }.map { .openFolder(path: $0) }
        case .archive:
            return candidate.sourceRefs.first.flatMap { pathsBySourceRef[$0] }
                .map { .openArchive(path: $0, revealEntry: nil) }
        case .archiveEntry:
            // 条目本身不在盘上;若能回查到所属归档路径则打开归档并定位条目,否则不可点(只展示)。
            if let entryRef = candidate.sourceRefs.first(where: { $0.kind == .archiveEntry }),
               let archiveRef = candidate.sourceRefs.first(where: { $0.kind == .archive }),
               let archivePath = pathsBySourceRef[archiveRef] {
                return .openArchive(path: archivePath, revealEntry: entryRef.id)
            }
            return nil
        case .task:
            return taskUUID(from: candidate).map { .openTask($0) }
        case .report:
            return taskUUID(from: candidate).map { .openReport(taskID: $0) }
        case .action, .automation:
            return actionsByCandidateID[candidate.id]
        case .group, .note:
            return nil
        }
    }

    /// 从候选的 task / report source ref 取 UUID(无 ref 或 id 串解析失败 → nil,不发明)。
    private static func taskUUID(from candidate: AIVirtualNodeCandidate) -> UUID? {
        guard let ref = candidate.sourceRefs.first(where: { $0.kind == .task || $0.kind == .report })
        else { return nil }
        return UUID(uuidString: ref.id)
    }

    // MARK: - AI 建议动作(模型挑 token,App 据 token + 候选路径安全合成 —— 模型不拼负载)

    /// 模型能给节点挑的 AI 建议词表(白皮书 `allowedActions`)。喂模型让它知道有哪些动作可建议,但**不让它拼路径**。
    /// 全部 `requiresConfirmation`(打开现有任务 / 表单流,绝不自动执行);**绝不含删除等破坏性动作**(节点建议永远
    /// 只读 / 只打开现有流程)。`userVisibleLabel` 是 prompt 里的英文释义,UI 标题由 App 本地化覆盖。
    static let allowedSuggestionDescriptors: [AISuggestionActionDescriptor] = [
        AISuggestionActionDescriptor(id: "hash", appliesToKinds: ["file", "archive"],
                                     requiresConfirmation: true, userVisibleLabel: "Calculate checksum"),
        AISuggestionActionDescriptor(id: "compress", appliesToKinds: ["file", "folder"],
                                     requiresConfirmation: true, userVisibleLabel: "Compress to an archive"),
        AISuggestionActionDescriptor(id: "test", appliesToKinds: ["archive"],
                                     requiresConfirmation: true, userVisibleLabel: "Test archive integrity"),
        AISuggestionActionDescriptor(id: "inspect", appliesToKinds: ["archive"],
                                     requiresConfirmation: true, userVisibleLabel: "Inspect as a release package"),
        AISuggestionActionDescriptor(id: "convert", appliesToKinds: ["archive"],
                                     requiresConfirmation: true, userVisibleLabel: "Convert to another format"),
    ]

    /// 一个动作 token 是否能用于某节点 kind(给 prompt 词表 + 防御性过滤)。
    static func suggestionApplies(token: String, to kind: AIVirtualNode.Kind) -> Bool {
        guard let d = allowedSuggestionDescriptors.first(where: { $0.id == token }) else { return false }
        return d.appliesToKinds.contains(kind.rawValue)
    }

    /// 把模型挑的动作 token + 目标候选,据回查到的路径**安全合成**成 `AISuggestionAction`。模型从不输出路径 ——
    /// 路径一律由 App 从 facts 回查。token 不适用该 kind / 取不到路径 → nil(该建议丢弃)。
    static func suggestionAction(token: String, candidate: AIVirtualNodeCandidate,
                                 pathsBySourceRef: [AIContextSourceRef: String]) -> AISuggestionAction? {
        guard suggestionApplies(token: token, to: candidate.kind),
              let path = candidate.sourceRefs.first.flatMap({ pathsBySourceRef[$0] }) else { return nil }
        switch token {
        case "hash":    return .calculateHash(paths: [path], algorithms: ["sha256"])
        case "compress": return .createArchive(paths: [path])
        case "test":    return .testArchive(path: path)
        case "inspect": return .inspectRelease(path: path)
        case "convert": return .convertArchive(path: path)
        default:        return nil
        }
    }
}

// MARK: - Builder:plan → sanitized 虚拟树

/// 把 plan + 候选合并成最终虚拟树:`.group` 节点 + `AIVirtualNodeCandidate.toNode()` 叶子(带安全推导的主动作),
/// 收集全部 source ref,最终 `AIVirtualFolderTree(...).sanitized()`。无效 candidateID 丢弃;空组丢弃;
/// 超出 `maxDepth` 的子组拍平到父级(不丢候选)。
nonisolated enum AIVirtualFolderTreeBuilder {
    /// 用确定性 plan 直接建树(模型不可用 / MVP 路径)。
    static func buildDeterministic(
        workspace: AIWorkspace,
        candidates: [AIVirtualNodeCandidate],
        pathsBySourceRef: [AIContextSourceRef: String] = [:],
        actionsByCandidateID: [String: AISuggestionAction] = [:],
        constraints: AIVirtualFolderPlanConstraints = .default,
        generatedAt: Date
    ) -> AIVirtualFolderTree {
        let plan = AIVirtualFolderPlanner.deterministicPlan(candidates: candidates, constraints: constraints)
        return build(workspace: workspace, plan: plan, candidates: candidates,
                     pathsBySourceRef: pathsBySourceRef, actionsByCandidateID: actionsByCandidateID,
                     mode: .deterministic, constraints: constraints, generatedAt: generatedAt)
    }

    /// 用一份 plan(模型或确定性)+ 候选建树。`suggestionLabels` 给 `.action` 建议节点的本地化标题(App 注入,
    /// token → 标题);确定性树不带建议(plan.suggestions 空)。
    static func build(
        workspace: AIWorkspace,
        plan: AIVirtualFolderPlan,
        candidates: [AIVirtualNodeCandidate],
        pathsBySourceRef: [AIContextSourceRef: String] = [:],
        actionsByCandidateID: [String: AISuggestionAction] = [:],
        suggestionLabels: [String: String] = [:],
        mode: AIVirtualTreeGenerationMode,
        constraints: AIVirtualFolderPlanConstraints = .default,
        generatedAt: Date
    ) -> AIVirtualFolderTree {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 折叠摘要 `pattern-…` id → 成员候选:模型引用折叠摘要时(它输入里看到的是摘要),展开回真实成员任务,
        // 不再因为 byID 查不到合成 id 就静默丢整组(BUG-P1)。与模型输入用同一聚类,id 一致。
        let patternMembers = AIVirtualFolderModelInputPreparer.patternSummaryMembers(from: candidates)
        let title = (plan.workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? workspace.title

        // 模型给各候选挑的 AI 建议(按目标候选分组;界外 candidateID 自然没有叶子会用到)。
        var suggestionsByCandidate: [String: [AINodeSuggestionPlan]] = [:]
        for s in plan.suggestions { suggestionsByCandidate[s.targetCandidateID, default: []].append(s) }

        let rawNodes = plan.groups.compactMap {
            groupNode($0, depth: 0, byID: byID, patternMembers: patternMembers,
                      pathsBySourceRef: pathsBySourceRef,
                      actionsByCandidateID: actionsByCandidateID,
                      suggestionsByCandidate: suggestionsByCandidate, suggestionLabels: suggestionLabels,
                      constraints: constraints)
        }
        // 同一文件 / 归档条目在一个工作区里只出现一次(用户:相同目录下相同文件不该在同一 AI 文件夹里重复)。
        // 按解析路径(归档条目按 path#entry 区分)/ 首个 source ref 去重,首次出现保留;去重后变空的组丢弃。
        // 无身份的节点(note / 无 ref 的 action)不去重。
        var seenLeafKeys = Set<String>()
        func dedup(_ ns: [AIVirtualNode]) -> [AIVirtualNode] {
            var out: [AIVirtualNode] = []
            for n in ns {
                let kids = dedup(n.children)
                if n.kind == .group {
                    if kids.isEmpty { continue }
                    out.append(n.replacingChildren(kids))
                } else if let key = leafDedupKey(n) {
                    if seenLeafKeys.insert(key).inserted { out.append(n.replacingChildren(kids)) }
                } else {
                    out.append(n.replacingChildren(kids))
                }
            }
            return out
        }
        let nodes = dedup(rawNodes)
        // 收集树里实际用到的全部 source ref —— sanitizer 的候选白名单。
        var refs: [AIContextSourceRef] = []
        var seen = Set<AIContextSourceRef>()
        func collect(_ ns: [AIVirtualNode]) {
            for n in ns {
                for r in n.sourceRefs where !seen.contains(r) { seen.insert(r); refs.append(r) }
                collect(n.children)
            }
        }
        collect(nodes)

        let tree = AIVirtualFolderTree(
            id: AIStableHash.deterministicUUID("tree:" + workspace.id.uuidString),
            workspaceID: workspace.id, title: title, prompt: workspace.prompt,
            generatedAt: generatedAt, generationMode: mode, nodes: nodes, sourceRefs: refs)
        return tree.sanitized()
    }

    /// 一个组 plan → `.group` 节点(递归)。子组超过 `maxDepth` 时把更深层的叶子拍平进当前组(不丢候选)。
    /// 叶子去重键:文件 / 文件夹按解析路径,归档条目按 `path#entry`,其余按首个 source ref;
    /// 无身份(note / 无 ref 的 action)→ nil(不参与去重)。
    private static func leafDedupKey(_ node: AIVirtualNode) -> String? {
        switch node.primaryAction {
        case .revealFile(let p), .openFolder(let p): return "p:" + p
        case .openArchive(let p, let entry): return "p:" + p + (entry.map { "#" + $0 } ?? "")
        default: return node.sourceRefs.first.map { "r:\($0.kind.rawValue):\($0.id)" }
        }
    }

    private static func groupNode(
        _ group: AIVirtualFolderGroupPlan, depth: Int,
        byID: [String: AIVirtualNodeCandidate],
        patternMembers: [String: [AIVirtualNodeCandidate]],
        pathsBySourceRef: [AIContextSourceRef: String],
        actionsByCandidateID: [String: AISuggestionAction],
        suggestionsByCandidate: [String: [AINodeSuggestionPlan]],
        suggestionLabels: [String: String],
        constraints: AIVirtualFolderPlanConstraints
    ) -> AIVirtualNode? {
        var children: [AIVirtualNode] = []
        // 把一个 candidateID 解析成叶子:命中真实候选 → 一个叶子;命中折叠摘要 `pattern-…` → 展开回全部成员任务
        // 叶子(折叠只为压模型输入,树里照常展示);都查不到则丢弃(界外 / 无效 id)。
        func appendLeaves(for cid: String) {
            if let candidate = byID[cid] {
                children.append(leafNode(candidate, pathsBySourceRef: pathsBySourceRef,
                                         actionsByCandidateID: actionsByCandidateID,
                                         suggestionsByCandidate: suggestionsByCandidate,
                                         suggestionLabels: suggestionLabels))
            } else if let members = patternMembers[cid] {
                for member in members {
                    children.append(leafNode(member, pathsBySourceRef: pathsBySourceRef,
                                             actionsByCandidateID: actionsByCandidateID,
                                             suggestionsByCandidate: suggestionsByCandidate,
                                             suggestionLabels: suggestionLabels))
                }
            }
        }
        // 本组直属候选 → 叶子节点。
        for cid in group.candidateIDs { appendLeaves(for: cid) }
        // 子组:未到深度上限则递归成子 group;到上限则拍平子组的叶子进本组。
        if depth + 1 < constraints.maxDepth {
            for child in group.children {
                if let childNode = groupNode(child, depth: depth + 1, byID: byID,
                                             patternMembers: patternMembers,
                                             pathsBySourceRef: pathsBySourceRef,
                                             actionsByCandidateID: actionsByCandidateID,
                                             suggestionsByCandidate: suggestionsByCandidate,
                                             suggestionLabels: suggestionLabels,
                                             constraints: constraints) {
                    children.append(childNode)
                }
            }
        } else {
            // 到深度上限:把更深子组的候选拍平进本组(不丢候选)。
            for child in group.children {
                for cid in flattenedCandidateIDs(child) { appendLeaves(for: cid) }
            }
        }
        guard !children.isEmpty else { return nil }   // 空组丢弃
        let title = clampTitle(group.title, max: constraints.maxTitleCharacters)
        return AIVirtualNode(
            id: AIStableHash.deterministicUUID("group:" + group.id),
            kind: .group, title: title, reason: group.reason,
            confidence: group.prominent ? 1.0 : 0.3,   // AI 注意力 → 默认是否展开(view 据 confidence 判定)
            children: children)
    }

    private static func leafNode(
        _ candidate: AIVirtualNodeCandidate,
        pathsBySourceRef: [AIContextSourceRef: String],
        actionsByCandidateID: [String: AISuggestionAction],
        suggestionsByCandidate: [String: [AINodeSuggestionPlan]],
        suggestionLabels: [String: String]
    ) -> AIVirtualNode {
        let action = AIVirtualNodeActionDeriver.primaryAction(
            for: candidate, pathsBySourceRef: pathsBySourceRef,
            actionsByCandidateID: actionsByCandidateID)
        let base = candidate.toNode().withPrimaryAction(action)
        // 模型给这个节点挑的 AI 建议 → `.action` 子节点(去重 token;**有建议才可展开**,无则没子节点没箭头)。
        // 路径回查不到 / token 不适用该 kind 的建议丢弃。建议是只读 / 打开现有流程,绝不破坏性。
        let suggestions = suggestionsByCandidate[candidate.id] ?? []
        guard !suggestions.isEmpty else { return base }
        var seenTokens = Set<String>()
        let actionChildren: [AIVirtualNode] = suggestions.compactMap { suggestion in
            guard seenTokens.insert(suggestion.actionToken).inserted,
                  let act = AIVirtualNodeActionDeriver.suggestionAction(
                    token: suggestion.actionToken, candidate: candidate, pathsBySourceRef: pathsBySourceRef)
            else { return nil }
            return AIVirtualNode(
                id: AIStableHash.deterministicUUID("sug:\(candidate.id):\(suggestion.actionToken)"),
                kind: .action,
                title: suggestionLabels[suggestion.actionToken] ?? suggestion.actionToken,
                reason: suggestion.reason, primaryAction: act, safety: act.safety)
        }
        return base.replacingChildren(actionChildren)
    }

    /// 收集一个组(含所有更深子组)里的全部 candidateID —— 到 maxDepth 后拍平用。
    private static func flattenedCandidateIDs(_ group: AIVirtualFolderGroupPlan) -> [String] {
        group.candidateIDs + group.children.flatMap { flattenedCandidateIDs($0) }
    }

    private static func clampTitle(_ raw: String, max: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max))
    }
}
