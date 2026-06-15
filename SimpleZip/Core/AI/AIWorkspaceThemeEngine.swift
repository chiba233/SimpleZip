//
//  AIWorkspaceThemeEngine.swift
//  SimpleZip
//
//  0.4.5 #80 #89:推荐主题的**跨位置语义聚类器**(白皮书建议四 + 用户拍板的统一框架)。
//
//  ⚠️ 本质(我反复理解错、被连骂过):**一个虚拟目录 = 一个主题;跨物理位置,按语义把看起来八竿子打不着的
//  文件 / 归档内条目 / 任务 / 报告 / 动作聚到一起。** 同一主题的成员来自五湖四海(Desktop/Downloads/
//  Documents/不同项目/归档内部/任务历史),membership 靠**语义相关**(名字 token / 任务关联 / 归档血缘 /
//  内容关键词)**不靠共享路径**。位置**绝不进成员资格**,只在 ranking 当注意力 boost。
//
//  这取代了旧的「单文件夹角色分桶」实现(那是按位置切分,正好反)。引擎吃**全局候选池**(App 从 AIFileMemory /
//  归档索引 / 归档内非加密条目 / 活动任务 / 报告 / 版本关系 / 发布账本组装,跨所有位置),输出跨位置主题候选。
//
//  统一框架(同一引擎服务两条线):
//    全局 AI 数据层 → 语义聚类(这里)→ ranking(+注意力+衰减抑制)→ AI 文件夹(持久工作区+虚拟树) / AI Suggestion(即时卡)
//
//  纯值 + 确定性(连通分量的划分与输入序无关;`now` 由 App 传入),SwiftPM 可断言。
//

import Foundation

/// 主题指纹(白皮书 `AIWorkspaceThemeFingerprint`)。用于:① 用户点「不感兴趣」后,下一轮生成须避开同款主题;
/// ② 判断两次生成是不是「同一个主题刷新」而非新主题。确定性:各分量排序去重,与输入序无关。跨位置主题的
/// `locationKinds` 可含多个(成员来自多处)。
nonisolated struct AIWorkspaceThemeFingerprint: Codable, Equatable, Hashable, Sendable {
    let themeTokens: [String]
    let sourceRefHashes: [String]
    let dominantRoleTags: [String]
    let locationKinds: [String]

    init(themeTokens: [String], sourceRefHashes: [String], dominantRoleTags: [String], locationKinds: [String]) {
        self.themeTokens = themeTokens.map { $0.lowercased() }.sorted()
        self.sourceRefHashes = sourceRefHashes.sorted()
        self.dominantRoleTags = Array(Set(dominantRoleTags.map { $0.lowercased() })).sorted()
        self.locationKinds = Array(Set(locationKinds.map { $0.lowercased() })).sorted()
    }

    /// 从主题 token + source refs + 角色 + 位置确定性派生。`sourceRefHashes` 用稳定 64-bit id(非加密)。
    static func make(themeTokens: [String], sourceRefs: [AIContextSourceRef],
                     dominantRoleTags: [String], locationKinds: [String]) -> AIWorkspaceThemeFingerprint {
        AIWorkspaceThemeFingerprint(
            themeTokens: themeTokens,
            sourceRefHashes: sourceRefs.map { AIStableHash.stableID64($0.kind.rawValue + ":" + $0.id) },
            dominantRoleTags: dominantRoleTags,
            locationKinds: locationKinds)
    }
}

/// 当前注意力上下文(白皮书:当前 folder/archive/selection **只作权重,不作内容边界**)。
nonisolated struct AIAttentionContext: Codable, Equatable, Sendable {
    /// 当前选中 / 打开的对象 —— 含这些 ref 的主题获 currentFocus boost。
    let focusedSourceRefs: [AIContextSourceRef]
    /// 当前浏览位置类别(AILocationKind rawValue)。
    let focusedLocationKinds: [String]
    /// 习惯常用位置(locationAffinity,AIInterestSummary 派生)。
    let locationAffinityKinds: [String]

    init(focusedSourceRefs: [AIContextSourceRef] = [], focusedLocationKinds: [String] = [],
         locationAffinityKinds: [String] = []) {
        self.focusedSourceRefs = focusedSourceRefs
        self.focusedLocationKinds = focusedLocationKinds
        self.locationAffinityKinds = locationAffinityKinds
    }

    var isEmpty: Bool {
        focusedSourceRefs.isEmpty && focusedLocationKinds.isEmpty && locationAffinityKinds.isEmpty
    }
}

nonisolated enum AIWorkspaceThemeEngine {
    /// 从**全局候选池**跨位置语义聚类出主题候选。聚类边(任一成立即连通,**与位置无关**):
    /// ① 名字 token 重叠(Jaccard ≥ 阈值,或 CJK 子串如「论文」⊂「论文修订意见」);② 共享 relatedTaskID
    /// (同一任务处理过);③ 共享 relatedArchiveID(归档 ↔ 其内部条目 / 同归档产物)。连通分量 ≥ `minClusterSize`
    /// 成主题。位置只在 ranking 当注意力 boost。返回已排序(信号多者优先)的候选,每个带跨位置指纹。
    static func discoverThemes(
        from pool: [AIVirtualNodeCandidate],
        attention: AIAttentionContext = AIAttentionContext(),
        now: Date,
        minClusterSize: Int = 2,
        tokenOverlapThreshold: Double = 0.34
    ) -> [AIWorkspaceThemeCandidate] {
        guard pool.count >= minClusterSize else { return [] }
        let items = pool.map { Indexed(candidate: $0, tokens: linkTokens(for: $0)) }

        // 并查集:按语义边连通(与遍历序无关 → 划分确定性)。
        var uf = UnionFind(items.count)
        for i in 0..<items.count {
            for j in (i + 1)..<items.count where linked(items[i], items[j], threshold: tokenOverlapThreshold) {
                uf.union(i, j)
            }
        }

        // 收集连通分量(成员保持原序 → 确定性)。
        var clusters: [Int: [Indexed]] = [:]
        var order: [Int] = []
        for i in 0..<items.count {
            let root = uf.find(i)
            if clusters[root] == nil { order.append(root) }
            clusters[root, default: []].append(items[i])
        }

        let themes = order.compactMap { root -> AIWorkspaceThemeCandidate? in
            let members = clusters[root] ?? []
            guard members.count >= minClusterSize else { return nil }   // 单件不成主题
            return makeTheme(members: members, attention: attention)
        }
        return AIWorkspaceCandidateRanker.rankThemes(themes)
    }

    // MARK: - 聚类边

    private struct Indexed {
        let candidate: AIVirtualNodeCandidate
        let tokens: Set<String>
    }

    /// 两候选是否语义连通(位置不参与)。
    private static func linked(_ a: Indexed, _ b: Indexed, threshold: Double) -> Bool {
        // ② / ③ 任务 / 归档血缘(空集不算)。
        if sharesNonEmpty(a.candidate.relatedTaskIDs, b.candidate.relatedTaskIDs) { return true }
        if sharesNonEmpty(a.candidate.relatedArchiveIDs, b.candidate.relatedArchiveIDs) { return true }
        // ① 名字 token:精确 Jaccard 或 CJK 子串。
        if jaccard(a.tokens, b.tokens) >= threshold { return true }
        if cjkSubstringLinked(a.tokens, b.tokens) { return true }
        return false
    }

    private static func sharesNonEmpty(_ a: [String], _ b: [String]) -> Bool {
        let sa = Set(a.filter { !$0.isEmpty })
        return !sa.isEmpty && !sa.isDisjoint(with: Set(b.filter { !$0.isEmpty }))
    }

    /// CJK 子串连通:一边某 CJK token(len ≥ 2)是另一边某 token 的子串(中文复合词无分隔符,精确 token 配不上)。
    private static func cjkSubstringLinked(_ a: Set<String>, _ b: Set<String>) -> Bool {
        func anyContained(_ small: Set<String>, in big: Set<String>) -> Bool {
            for s in small where s.count >= 2 && containsCJK(s) {
                if big.contains(where: { $0 != s && $0.contains(s) }) { return true }
            }
            return false
        }
        return anyContained(a, in: b) || anyContained(b, in: a)
    }

    // MARK: - 簇 → 主题

    private static func makeTheme(members: [Indexed], attention: AIAttentionContext)
        -> AIWorkspaceThemeCandidate {
        let ranked = AIWorkspaceCandidateRanker.rankNodes(members.map(\.candidate))
        var refs: [AIContextSourceRef] = []
        var seenRef = Set<AIContextSourceRef>()
        for c in ranked { for r in c.sourceRefs where !seenRef.contains(r) { seenRef.insert(r); refs.append(r) } }

        // 跨位置:成员的不同位置类别数(≥2 = 真跨位置)。
        let locationKinds = dedup(members.compactMap { $0.candidate.location?.kind.rawValue })
        // 共享名字 token(出现在 ≥2 成员里,频次降序)→ 主题标题种子 + token。
        let shared = sharedTokensByFrequency(members)
        let roles = dedup(members.flatMap { $0.candidate.roleTags })

        var signals: [String] = ["cluster-size=\(members.count)"]
        if locationKinds.count >= 2 { signals.append("cross-location=\(locationKinds.count)") }
        if let top = shared.first { signals.append("shared-token:\(top)") }
        if members.contains(where: { $0.candidate.kind == .task }) { signals.append("has-task") }
        if members.contains(where: { $0.candidate.kind == .archive || $0.candidate.kind == .archiveEntry }) {
            signals.append("has-archive")
        }
        if members.contains(where: { $0.candidate.kind == .report }) { signals.append("has-report") }
        // 注意力 boost(当前焦点 / 习惯位置)—— 只影响排序,不影响成员。
        let focusedRefs = Set(attention.focusedSourceRefs)
        if !focusedRefs.isEmpty, members.contains(where: { !focusedRefs.isDisjoint(with: Set($0.candidate.sourceRefs)) }) {
            signals.append("attention:current-focus")
        }
        let focusedLocs = Set(attention.focusedLocationKinds)
        if !focusedLocs.isEmpty, !focusedLocs.isDisjoint(with: Set(locationKinds)) {
            signals.append("attention:focus-location")
        }
        let habitLocs = Set(attention.locationAffinityKinds)
        if !habitLocs.isEmpty, !habitLocs.isDisjoint(with: Set(locationKinds)) {
            signals.append("attention:habit-location")
        }

        let themeTokens = dedup(Array(shared.prefix(5)) + roles).prefix(8).map { $0 }
        let titleSeed = shared.first ?? roles.first ?? ranked.first?.displayName ?? "related items"
        let fingerprint = AIWorkspaceThemeFingerprint.make(
            themeTokens: themeTokens, sourceRefs: refs, dominantRoleTags: roles, locationKinds: locationKinds)

        return AIWorkspaceThemeCandidate(
            // id 基于成员身份(排序后的 ref 集合),**不含 location** → 同一批文件无论在哪都是同一主题。
            id: "theme-" + AIStableHash.stableID64(refs.map { $0.kind.rawValue + ":" + $0.id }.sorted().joined(separator: "|")),
            titleSeed: titleSeed,
            themeTokens: themeTokens,
            sourceRefs: refs,
            scoreSignals: signals,
            evidence: [AIEvidenceFact(label: "semantic cluster across locations", facts: signals)],
            fingerprint: fingerprint)
    }

    /// 出现在 ≥2 成员里的名字 token,按频次降序、同频按字典序(确定性)。
    private static func sharedTokensByFrequency(_ members: [Indexed]) -> [String] {
        var counts: [String: Int] = [:]
        for m in members { for t in m.tokens { counts[t, default: 0] += 1 } }
        return counts.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    // MARK: - 工具

    /// 一个候选用于连通的 token 集 = displayName 拆出的 token ∪ 候选自带的 `semanticTokens`(已脱敏的关联
    /// 文件名 / 内容关键词 / marker;同样过停用词 / 长度过滤)。
    private static func linkTokens(for candidate: AIVirtualNodeCandidate) -> Set<String> {
        var tokens = nameTokens(candidate.displayName)
        for raw in candidate.semanticTokens {
            let t = raw.lowercased()
            guard t.count >= 2, !stopwords.contains(t), t.contains(where: { !$0.isNumber }) else { continue }
            tokens.insert(t)
        }
        return tokens
    }

    /// 把展示名拆成低敏语义 token(去扩展名、小写、按非字母数字切、丢纯数字 / 停用词 / <2 字符;CJK 复合词整体保留)。
    private static func nameTokens(_ displayName: String) -> Set<String> {
        let base = ((displayName as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        var tokens = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 2, !stopwords.contains(current),
                  current.contains(where: { !$0.isNumber }) else { return }   // 丢纯数字
            tokens.insert(current)
        }
        for ch in base {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return tokens
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { sc in
            (0x4E00...0x9FFF).contains(sc.value) ||   // CJK 统一汉字
            (0x3040...0x30FF).contains(sc.value) ||   // 平假名 / 片假名
            (0xAC00...0xD7A3).contains(sc.value)      // 谚文
        }
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !x.isEmpty && !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }

    /// 通用停用词(避免「report/copy/final」这类把无关文件错连)。保留 release/test 等有意义词。
    private static let stopwords: Set<String> = [
        "copy", "new", "untitled", "final", "draft", "temp", "tmp", "the", "and",
        "for", "with", "version", "document", "file", "output", "export"
    ]

    /// 轻量并查集(路径压缩 + 按秩合并)。
    private struct UnionFind {
        private var parent: [Int]
        private var rank: [Int]
        init(_ n: Int) { parent = Array(0..<n); rank = Array(repeating: 0, count: n) }
        mutating func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }
    }
}

extension AIWorkspaceThemeCandidate {
    /// 落成一个推荐工作区(`origin == .recommended`)。确定性 UUID(基于成员身份,可复现);`title` 暂用
    /// `titleSeed`,模型整理时可改名。`generatedAt` 由 App 传入。query plan 带上主题 token 便于后续召回 / 解释。
    func toRecommendedWorkspace(generatedAt: Date, iconSystemName: String = "sparkles") -> AIWorkspace {
        AIWorkspace(
            id: AIStableHash.deterministicUUID("workspace:" + id),
            origin: .recommended,
            title: titleSeed,
            queryPlan: AIWorkspaceQueryPlan(taskTags: [], keywords: themeTokens),
            iconSystemName: iconSystemName,
            generatedAt: generatedAt,
            fingerprint: fingerprint)
    }
}
