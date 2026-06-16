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
                  prompt: workspace.prompt, queryTokens: Array(tokens.prefix(12)))
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

    init(workspaceTitle: String? = nil, groups: [AIVirtualFolderGroupPlan]) {
        self.schema = Self.schemaID
        self.workspaceTitle = workspaceTitle
        self.groups = groups
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

    /// 用一份 plan(模型或确定性)+ 候选建树。
    static func build(
        workspace: AIWorkspace,
        plan: AIVirtualFolderPlan,
        candidates: [AIVirtualNodeCandidate],
        pathsBySourceRef: [AIContextSourceRef: String] = [:],
        actionsByCandidateID: [String: AISuggestionAction] = [:],
        mode: AIVirtualTreeGenerationMode,
        constraints: AIVirtualFolderPlanConstraints = .default,
        generatedAt: Date
    ) -> AIVirtualFolderTree {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let title = (plan.workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? workspace.title

        let nodes = plan.groups.compactMap {
            groupNode($0, depth: 0, byID: byID, pathsBySourceRef: pathsBySourceRef,
                      actionsByCandidateID: actionsByCandidateID, constraints: constraints)
        }
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
    private static func groupNode(
        _ group: AIVirtualFolderGroupPlan, depth: Int,
        byID: [String: AIVirtualNodeCandidate],
        pathsBySourceRef: [AIContextSourceRef: String],
        actionsByCandidateID: [String: AISuggestionAction],
        constraints: AIVirtualFolderPlanConstraints
    ) -> AIVirtualNode? {
        var children: [AIVirtualNode] = []
        // 本组直属候选 → 叶子节点(无效 id 丢弃)。
        for cid in group.candidateIDs {
            guard let candidate = byID[cid] else { continue }
            children.append(leafNode(candidate, pathsBySourceRef: pathsBySourceRef,
                                     actionsByCandidateID: actionsByCandidateID))
        }
        // 子组:未到深度上限则递归成子 group;到上限则拍平子组的叶子进本组。
        if depth + 1 < constraints.maxDepth {
            for child in group.children {
                if let childNode = groupNode(child, depth: depth + 1, byID: byID,
                                             pathsBySourceRef: pathsBySourceRef,
                                             actionsByCandidateID: actionsByCandidateID,
                                             constraints: constraints) {
                    children.append(childNode)
                }
            }
        } else {
            // 到深度上限:把更深子组的候选拍平进本组(不丢候选)。
            for child in group.children {
                for cid in flattenedCandidateIDs(child) {
                    guard let candidate = byID[cid] else { continue }
                    children.append(leafNode(candidate, pathsBySourceRef: pathsBySourceRef,
                                             actionsByCandidateID: actionsByCandidateID))
                }
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
        actionsByCandidateID: [String: AISuggestionAction]
    ) -> AIVirtualNode {
        let action = AIVirtualNodeActionDeriver.primaryAction(
            for: candidate, pathsBySourceRef: pathsBySourceRef,
            actionsByCandidateID: actionsByCandidateID)
        return candidate.toNode().withPrimaryAction(action)
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
