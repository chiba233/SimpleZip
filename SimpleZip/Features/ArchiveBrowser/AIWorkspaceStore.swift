//
//  AIWorkspaceStore.swift
//  SimpleZip
//
//  0.4.5 #80 #89:动态 AI 工作区的 App 层 store(白皮书建议四 + 用户拍板的统一框架)。
//
//  ⚠️ AI 文件夹 = 跨物理位置按语义聚成的虚拟主题目录,**和当前文件夹 0 关系**(那是 AI Suggestion 的事)。
//  内容来自后台发现的全局数据层:`refreshRecommendations` 吃派生记录(持久文件索引 / 活动任务 / 归档…,由后台
//  编排者汇总后传入)→ 跨位置语义聚类(`AIWorkspaceDiscovery`)→ 衰减抑制 → upsert `.recommended` 工作区。
//  `virtualTree(for:)` 经 plan/builder 从候选池建树(不再返回 nil —— 这曾是「有入口没价值」的核心缺口)。
//
//  持久:工作区集合(元数据,含主题指纹)+ 衰减抑制账本。**绝对路径绝不落盘**(隐私)—— 候选池 / 路径解析 /
//  树缓存都在内存,每会话由 `refreshRecommendations` 重建。
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AIWorkspaceStore: ObservableObject {
    static let shared = AIWorkspaceStore()

    @Published private(set) var collection: AIWorkspaceCollection

    /// 持久:不感兴趣的衰减抑制账本(工作区级)。
    private var suppression: AIThemeSuppressionLedger
    /// 持久:节点级「我很喜欢 / 我不喜欢」反馈(工作区 × 成员 ref)。不喜欢的成员从树里剔除。
    private var feedback: AINodeFeedbackLedger
    /// 持久:虚拟结构编辑(分组改名 + 成员移动)。派生树之上套用。
    private var structureEdits: AIWorkspaceStructureEdits
    /// 持久:每工作区的**用户种子**(标题 / 主题提示词 / 固定 / 排除 / 默认 App)。这是闭环的核心 —— 用户的修改
    /// (喜欢→pin、不喜欢→exclude、描述/改名→themePrompts、手动加入→pin)都落进种子,**下次召回 / 发现据此更懂你**。
    private var seeds: [UUID: AIWorkspaceUserSeed]

    // 内存(每会话由 refreshRecommendations 重建,不落盘 —— 隐私):
    private var pool: [AIVirtualNodeCandidate] = []
    private var memberRefsByWorkspace: [UUID: Set<AIContextSourceRef>] = [:]
    private var pathsBySourceRef: [AIContextSourceRef: String] = [:]
    private var treeCache: [UUID: AIVirtualFolderTree] = [:]
    /// 每轮发现自增;off-main 聚类回来时只认最新一轮(丢弃过期结果)。
    private var refreshGeneration = 0
    /// 每工作区上次让模型排过的成员签名 —— 同一批成员不重复刷模型;成员变了才重排(失败也不重试本批)。
    private var modelPlanSignatures: [UUID: String] = [:]
    /// 缓存模型生成的 plan(按成员签名)。结构编辑(改名 / 移动)只清树缓存、留 plan → 在模型 plan 上重套覆盖层,
    /// **不重刷模型**;成员变了 sig 不匹配才重排。
    private var modelPlans: [UUID: (sig: String, plan: AIVirtualFolderPlan)] = [:]
    /// 喂给模型的候选集(= 当前成员 + 主题相关额外候选)—— 模型可把额外里最合适的「选进」主题。建模型树时用它
    /// (plan 的 candidateID 可能引用额外候选),不是只用规则簇成员。
    private var modelFed: [UUID: [AIVirtualNodeCandidate]] = [:]

    private let defaults: UserDefaults
    private static let storageKey = "SimpleZip.ai.workspaces.v1"
    private static let suppressionKey = "SimpleZip.ai.themeSuppression.v1"
    private static let feedbackKey = "SimpleZip.ai.nodeFeedback.v1"
    private static let structureKey = "SimpleZip.ai.structureEdits.v1"
    private static let seedsKey = "SimpleZip.ai.workspaceSeeds.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = AIWorkspaceStore.load(from: defaults)
        // #89:删掉被打回的固定系统工作区(失败任务 / 校验 / 最近归档 = 活动中心换皮)残留。
        loaded.workspaces.removeAll { $0.origin == .system }
        self.collection = loaded
        self.suppression = AIWorkspaceStore.loadSuppression(from: defaults)
        self.feedback = AIWorkspaceStore.decode(AINodeFeedbackLedger.self, key: Self.feedbackKey, from: defaults)
            ?? AINodeFeedbackLedger()
        self.structureEdits = AIWorkspaceStore.decode(AIWorkspaceStructureEdits.self, key: Self.structureKey, from: defaults)
            ?? AIWorkspaceStructureEdits()
        self.seeds = AIWorkspaceStore.decode([UUID: AIWorkspaceUserSeed].self, key: Self.seedsKey, from: defaults) ?? [:]
        persist()
    }

    /// 侧边栏渲染的可见工作区。**AI 加权排序**(主题强度 + 打开频率 + 最近度衰减)—— 点一下只是软加权,
    /// 不僵硬置顶;随时间连续重排。
    var visibleWorkspaces: [AIWorkspace] { collection.ranked(now: Date()) }

    func workspace(_ id: UUID) -> AIWorkspace? { collection.workspace(id) }

    // MARK: - 后台发现 → 推荐工作区(与当前文件夹无关)

    /// 用全局数据层的派生记录跑一轮发现,把跨位置主题 upsert 成 `.recommended` 工作区。records 由后台编排者从
    /// 持久索引 / 任务 / 归档汇总后传入;`attention` 只当排序权重(不改成员)。gated on AI 主开关 + 「显示推荐」。
    /// `pathsBySourceRef` 给节点动作回查路径(仅权限允许的);取不到路径的节点动作降级为不可点。
    func refreshRecommendations(
        files: [AIFileMemoryRecord] = [],
        tasks: [AITaskRecord] = [],
        attention: AIAttentionContext = AIAttentionContext(),
        pathsBySourceRef: [AIContextSourceRef: String] = [:],
        now: Date = Date()
    ) {
        refreshGeneration += 1
        let generation = refreshGeneration
        // 候选池在主线程组装(O(n) 廉价);随结果一起原子安装,保证 pool / memberRefs / themes 三者一致。
        let pool = AIWorkspaceDiscovery.assemblePool(files: files, tasks: tasks)

        guard AppPreferences.aiAssistantEnabled, AppPreferences.aiSidebarShowRecommended else {
            // 关推荐:就地清掉 recommended + 缓存,留住用户工作区(不必跑发现)。
            self.pool = pool
            self.pathsBySourceRef = pathsBySourceRef
            self.treeCache = [:]
            let next = collection.replacingRecommended([])
            if next != collection { collection = next }
            self.memberRefsByWorkspace = memberRefsByWorkspace.filter {
                collection.workspace($0.key)?.origin == .userCreated
            }
            persist()
            return
        }

        let policy = AIRecommendationPolicy(maxThemes: AppPreferences.aiMaxRecommendedWorkspaces)
        let suppression = self.suppression
        // **重活(跨位置语义聚类)挪出 MainActor** —— 开窗首帧不被 AI 发现拖住(用户实测卡;倒排索引已降复杂度,
        // 但聚类仍不该占主线程)。纯 Core(Sendable)→ Task.detached,回主线程原子安装。
        Task.detached(priority: .utility) { [files, tasks, attention, suppression, policy, pool, pathsBySourceRef, now] in
            let out = AIWorkspaceDiscovery.discover(
                files: files, tasks: tasks, attention: attention, suppression: suppression, now: now, policy: policy)
            await MainActor.run {
                self.applyDiscovery(generation: generation, pool: pool,
                                    paths: pathsBySourceRef, output: out, now: now)
            }
        }
    }

    /// off-main 聚类回主线程:只认最新一轮(过期结果丢弃),原子安装 pool + 成员引用 + 推荐工作区。
    private func applyDiscovery(generation: Int, pool: [AIVirtualNodeCandidate],
                               paths: [AIContextSourceRef: String],
                               output: AIWorkspaceDiscovery.Output, now: Date) {
        guard generation == refreshGeneration else { return }   // 期间又发起了新一轮 → 丢弃这次
        self.pool = pool
        self.pathsBySourceRef = paths
        self.treeCache = [:]   // 候选池变 → 树缓存失效
        let recs = output.themes.map { (ws: $0.toRecommendedWorkspace(generatedAt: now), refs: Set($0.sourceRefs)) }
        // **整体替换**旧推荐(非累积)→ 消除幽灵空工作区;memberRefs 只留本轮的。
        let next = collection.replacingRecommended(recs.map(\.ws))
        self.memberRefsByWorkspace = Dictionary(uniqueKeysWithValues: recs.map { ($0.ws.id, $0.refs) })
        if next != collection { collection = next }
        persist()
    }

    // MARK: - 虚拟树(plan/builder,不再 nil)

    /// 工作区的虚拟文件夹树。从内存候选池召回该工作区成员 → 确定性 plan → sanitized 树 → 缓存。
    /// 候选池尚未由 `refreshRecommendations` 填充(刚启动)时返回 nil → 内容区显示空状态。
    func virtualTree(for id: UUID) -> AIVirtualFolderTree? {
        if let cached = treeCache[id] { return cached }   // 命中:模型树或确定性树
        guard let ws = collection.workspace(id) else { return nil }
        let members = memberCandidates(for: ws)
        guard !members.isEmpty else { return nil }
        let sig = members.map(\.id).sorted().joined(separator: ",")
        let tree: AIVirtualFolderTree
        if let cachedPlan = modelPlans[id], cachedPlan.sig == sig, let fed = modelFed[id] {
            // 已有本批成员的模型 plan → 用模型选定的候选集(成员 + 模型加进来的额外文件)建树,在其上套用户覆盖层。
            // 仍按排除集过滤(对额外文件的「我不喜欢」也生效)。不重刷模型。
            let excluded = excludedRefs(for: ws)
            let visible = excluded.isEmpty ? fed
                : fed.filter { cand in !cand.sourceRefs.contains(where: { excluded.contains($0) }) }
            tree = buildTree(ws: ws, members: visible, plan: cachedPlan.plan, mode: .modelAssisted)
        } else {
            // 先出**确定性树**占位(UI 标「自动整理」),不阻塞;模型就绪则异步**选主题成员 + 分组 + 命名**后替换。
            tree = buildTree(ws: ws, members: members, plan: nil, mode: .deterministic)
            maybeScheduleModelPlan(id: id, ws: ws, members: members, sig: sig)
        }
        treeCache[id] = tree
        return tree
    }

    /// 一个工作区当前被排除的成员 ref(我不喜欢 + 种子排除)。
    private func excludedRefs(for ws: AIWorkspace) -> Set<AIContextSourceRef> {
        feedback.dislikedRefs(ws.id).union(seeds[ws.id]?.excludedSourceRefs ?? [])
    }

    /// plan(nil = 确定性)+ 成员 → 套用户结构编辑后的最终树。
    private func buildTree(ws: AIWorkspace, members: [AIVirtualNodeCandidate],
                           plan: AIVirtualFolderPlan?, mode: AIVirtualTreeGenerationMode) -> AIVirtualFolderTree {
        let base: AIVirtualFolderTree
        if let plan {
            base = AIVirtualFolderTreeBuilder.build(workspace: ws, plan: plan, candidates: members,
                                                    pathsBySourceRef: pathsBySourceRef, mode: mode, generatedAt: Date())
        } else {
            base = AIVirtualFolderTreeBuilder.buildDeterministic(
                workspace: ws, candidates: members, pathsBySourceRef: pathsBySourceRef, generatedAt: Date())
        }
        // 用户结构编辑(分组改名 + 成员移动)永远盖在最后 —— 无论树是确定性还是模型生成的,用户整理不丢。
        return base.applyingStructureEdits(
            groupTitles: structureEdits.groupTitles(ws.id), assignments: structureEdits.assignments(ws.id))
    }

    /// 模型就绪 + 本批成员还没让模型排过 → 异步让**本地模型生成虚拟目录树**(白皮书:AI 文件夹的树必须过模型,
    /// 不能只是确定性 bucket)。先确定性占位、模型回来再替换;失败 / 不可用就一直用确定性(不崩、UI 如实标注)。
    private func maybeScheduleModelPlan(id: UUID, ws: AIWorkspace, members: [AIVirtualNodeCandidate], sig: String) {
        guard #available(macOS 26.0, *), AIReportAssistant.isReady, members.count >= 2 else { return }
        guard modelPlanSignatures[id] != sig else { return }
        modelPlanSignatures[id] = sig   // 占位:失败不重试本批(免刷模型);成员变了 sig 变才重排
        // 喂模型 = 当前成员 + 主题相关的额外候选 → 模型**选**哪些最合适进主题(不只是重排已选)+ 分组 + 命名。
        let fed = members + themeRelevantExtra(ws: ws, members: members, cap: 30)
        let coreIDs = Set(members.map(\.id))
        let input = makeModelPlanInput(ws: ws, candidates: fed)
        Task { @MainActor in
            guard let plan = try? await AIVirtualFolderModelPlanner.plan(for: input),
                  self.modelPlanSignatures[id] == sig else { return }   // 期间成员又变 → 丢弃
            self.applyModelPlan(id: id, ws: ws, sig: sig, fed: fed, coreIDs: coreIDs, plan: plan)
        }
    }

    /// 落地模型 plan:**核心成员(规则簇)永不被模型丢**(模型漏放的补进「更多」组);额外候选只留模型选进的;
    /// 缓存 fed + plan(按本批成员 sig);**侧栏主题名换成模型生成的**(除非用户改过名)。
    private func applyModelPlan(id: UUID, ws: AIWorkspace, sig: String, fed: [AIVirtualNodeCandidate],
                               coreIDs: Set<String>, plan: AIVirtualFolderPlan) {
        var referenced = Set<String>()
        func collect(_ groups: [AIVirtualFolderGroupPlan]) {
            for g in groups { referenced.formUnion(g.candidateIDs); collect(g.children) }
        }
        collect(plan.groups)
        let fedIDs = Set(fed.map(\.id))
        let keepIDs = coreIDs.union(referenced.filter { fedIDs.contains($0) })   // 核心 ∪ 模型选进的额外
        let keptFed = fed.filter { keepIDs.contains($0.id) }
        guard !keptFed.isEmpty else { return }
        // 模型漏放的保留成员补进「更多」组(不丢)。
        let unplaced = keptFed.map(\.id).filter { !referenced.contains($0) }
        var groups = plan.groups
        if !unplaced.isEmpty {
            groups.append(AIVirtualFolderGroupPlan(id: "more", title: L10n.text("aiWorkspace.group.more"),
                                                   candidateIDs: unplaced))
        }
        let finalPlan = AIVirtualFolderPlan(workspaceTitle: plan.workspaceTitle, groups: groups)
        let modelTree = buildTree(ws: ws, members: keptFed, plan: finalPlan, mode: .modelAssisted)
        guard !modelTree.isEmpty else { return }
        modelFed[id] = keptFed
        modelPlans[id] = (sig, finalPlan)
        treeCache[id] = modelTree
        // 侧栏主题名:模型生成的(白皮书:主题名该是 AI 生成的;用户改过名则不覆盖)。
        if let aiTitle = finalPlan.workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !aiTitle.isEmpty,
           seeds[id]?.userTitle == nil, collection.workspace(id)?.title != aiTitle {
            collection = collection.renaming(id, to: aiTitle); persist()
        }
        objectWillChange.send()   // 换上模型生成的树(modelAssisted → 去掉「自动整理」标)
    }

    /// 主题相关的额外候选:池里非成员、未排除、名字命中主题 token 的,按命中数取前 cap —— 让模型能把规则簇没召回到、
    /// 但确实属于这个主题的文件**选进来**。主题 token = 工作区关键词 + 种子提示词 + 成员名字 token。
    private func themeRelevantExtra(ws: AIWorkspace, members: [AIVirtualNodeCandidate], cap: Int)
        -> [AIVirtualNodeCandidate] {
        var themeTokens = Set<String>()
        for t in ws.queryPlan.keywords + (seeds[ws.id]?.themePrompts ?? []) { themeTokens.formUnion(simpleTokens(t)) }
        for m in members { themeTokens.formUnion(simpleTokens(m.displayName)) }
        guard !themeTokens.isEmpty else { return [] }
        let memberIDs = Set(members.map(\.id))
        let excluded = excludedRefs(for: ws)
        let scored: [(AIVirtualNodeCandidate, Int)] = pool.compactMap { cand in
            guard !memberIDs.contains(cand.id),
                  !cand.sourceRefs.contains(where: { excluded.contains($0) }) else { return nil }
            let overlap = simpleTokens(cand.displayName).intersection(themeTokens).count
            return overlap > 0 ? (cand, overlap) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }.prefix(cap).map(\.0)
    }

    /// 简易分词(去扩展名 / 小写 / 按非字母数字切 / 丢 <2 字符);CJK 复合词整体保留。
    private func simpleTokens(_ s: String) -> Set<String> {
        var tokens = Set<String>(); var cur = ""
        func flush() { defer { cur = "" }; if cur.count >= 2 { tokens.insert(cur) } }
        for ch in ((s as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) } else { flush() }
        }
        flush(); return tokens
    }

    /// 组装喂给模型的 prompt-safe 输入(候选投影 + 用户描述 / 种子主题提示词当主题意图;绝不含路径)。
    private func makeModelPlanInput(ws: AIWorkspace, candidates: [AIVirtualNodeCandidate]) -> AIVirtualFolderPlanInput {
        let seed = seeds[ws.id]
        var tokens: [String] = []
        for t in ws.queryPlan.keywords + (seed?.themePrompts ?? []) where !t.isEmpty && !tokens.contains(t) {
            tokens.append(t)
        }
        let fact = AIWorkspacePromptFact(
            id: ws.id, title: ws.title, origin: ws.origin.rawValue,
            prompt: ws.userDescription ?? seed?.themePrompts.first ?? ws.prompt,
            queryTokens: Array(tokens.prefix(12)))
        return AIVirtualFolderPlanInput(workspace: fact,
                                        candidates: candidates.map { AIVirtualNodePromptCandidate(candidate: $0) })
    }

    /// 虚拟分组改名(用户编辑覆盖层)+ **把新分组名拆成主题提示词喂进种子**(用户把某组叫「源代码」=
    /// 这个工作区关心「源代码」,下次召回 / 模型分组据此更懂)。
    func renameGroup(workspaceID: UUID, groupID: UUID, to title: String?) {
        structureEdits = structureEdits.renamingGroup(workspaceID, groupID, to: title)
        saveStructureEdits()
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutateSeed(workspaceID) { $0.addingThemePrompt(title, updatedAt: Date()) }
        }
        treeCache[workspaceID] = nil; objectWillChange.send()
    }

    /// 把成员移进目标虚拟分组(用户编辑覆盖层)+ **固定进种子**(用户明确说「这个文件属于这个语义组」=
    /// 强偏好,比自动聚类权重高 —— pin 住,下次发现不会把它刷掉)。
    func moveNodes(workspaceID: UUID, refs: [AIContextSourceRef], toGroup groupID: UUID) {
        guard !refs.isEmpty else { return }
        structureEdits = structureEdits.assigning(workspaceID, refs, toGroup: groupID)
        saveStructureEdits()
        mutateSeed(workspaceID) { $0.pinning(refs, updatedAt: Date()) }
        treeCache[workspaceID] = nil; objectWillChange.send()
    }

    /// 手动把一组成员加入某 AI 工作区(右键文件 / 拖入 → 写种子固定集,不只是临时视图变化)。
    func addMembers(workspaceID: UUID, refs: [AIContextSourceRef]) {
        guard !refs.isEmpty else { return }
        mutateSeed(workspaceID) { $0.pinning(refs, updatedAt: Date()) }
        objectWillChange.send()
    }

    /// 召回某工作区的成员候选。**两条来源并集**(闭环关键):
    ///  ① 推荐工作区:后台发现时记下的成员 ref(候选 refs ⊆ 主题成员集);
    ///  ② 种子召回:用户固定(喜欢 / 手动加入 / 移动)+ 主题提示词(描述 / 改名)语义命中 —— 让用户工作区不再是空壳、
    ///     让用户的修改真的改变下次召回到的成员(`AIWorkspaceSeedRecall`)。
    /// 最后剔除被「我不喜欢 / 从工作区移除」排除的成员(节点反馈 + 种子排除集)。
    private func memberCandidates(for ws: AIWorkspace) -> [AIVirtualNodeCandidate] {
        var result: [AIVirtualNodeCandidate] = []
        if ws.origin == .recommended, let refs = memberRefsByWorkspace[ws.id] {
            result = pool.filter { !$0.sourceRefs.isEmpty && $0.sourceRefs.allSatisfy { refs.contains($0) } }
        }
        if let seed = seeds[ws.id] {
            let recalled = AIWorkspaceSeedRecall.members(in: pool, seed: seed)
            let existing = Set(result.map(\.id))
            result.append(contentsOf: recalled.filter { !existing.contains($0.id) })
        }
        let excluded = feedback.dislikedRefs(ws.id).union(seeds[ws.id]?.excludedSourceRefs ?? [])
        guard !excluded.isEmpty else { return result }
        return result.filter { cand in !cand.sourceRefs.contains(where: { excluded.contains($0) }) }
    }

    // MARK: - 用户种子(闭环:每个修改都喂回种子)

    /// 取或建工作区种子。
    private func seed(for id: UUID) -> AIWorkspaceUserSeed {
        seeds[id] ?? AIWorkspaceUserSeed(workspaceID: id, createdAt: Date(), updatedAt: Date())
    }

    /// 变换种子并持久化 + 失效树缓存(下次召回用新种子)。
    private func mutateSeed(_ id: UUID, _ transform: (AIWorkspaceUserSeed) -> AIWorkspaceUserSeed) {
        let next = transform(seed(for: id))
        guard next != seeds[id] else { return }
        seeds[id] = next
        saveSeeds()
        treeCache[id] = nil
    }

    // MARK: - 节点级反馈(我很喜欢 / 我不喜欢)+ 可编辑描述

    /// 节点是否仍是「待确认的 AI 建议」(没被 like)—— UI 据此打 AI 角标。
    func nodeIsAISuggested(workspaceID: UUID, refs: [AIContextSourceRef]) -> Bool {
        !refs.isEmpty && !feedback.nodeIsLiked(workspaceID, refs: refs)
    }

    /// 「我很喜欢」:确认保留(去角标)+ **固定进种子**(正反馈,下次召回更可能留它 / 拉相似的进来)。
    func likeNode(workspaceID: UUID, refs: [AIContextSourceRef]) {
        guard !refs.isEmpty else { return }
        feedback = feedback.liking(workspaceID, refs)
        saveFeedback()
        mutateSeed(workspaceID) { $0.pinning(refs, updatedAt: Date()) }
        objectWillChange.send()
    }

    /// 「我不喜欢」:移出文件夹 + **写进种子排除集**(负反馈,下次发现不再自动加入)。
    func dislikeNode(workspaceID: UUID, refs: [AIContextSourceRef]) {
        guard !refs.isEmpty else { return }
        feedback = feedback.disliking(workspaceID, refs)
        saveFeedback()
        mutateSeed(workspaceID) { $0.excluding(refs, updatedAt: Date()) }
        objectWillChange.send()
    }

    /// 设置用户可编辑的文件夹描述:存展示用 + **拆成主题提示词喂进种子**(「论文实验数据图」→ 召回 token,
    /// 让描述真的改变这个工作区召回到什么)。
    func setDescription(_ id: UUID, _ text: String?) {
        apply { $0.settingDescription(id, text) }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutateSeed(id) { $0.addingThemePrompt(text, updatedAt: Date()) }
            objectWillChange.send()
        }
    }

    // MARK: - 变换(走 Core 纯逻辑 + 持久化 + 发布)

    func createUserWorkspace(prompt: String) -> UUID {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let title = trimmed.isEmpty ? L10n.text("aiFolder.title") : trimmed
        let ws = AIWorkspace(id: id, origin: .userCreated, title: title,
                             prompt: trimmed.isEmpty ? nil : trimmed,
                             queryPlan: AIWorkspaceQueryPlan(taskTags: []),
                             iconSystemName: "folder.badge.gearshape", generatedAt: Date())
        apply { $0.upserting(ws) }
        // prompt → 种子主题提示词,这样新工作区一打开就能召回相关成员(不是空壳)。
        if !trimmed.isEmpty {
            let now = Date()
            seeds[id] = AIWorkspaceUserSeed(workspaceID: id, themePrompts: [trimmed], createdAt: now, updatedAt: now)
            saveSeeds()
        }
        return id
    }

    /// 「不感兴趣」:推荐工作区 → 写衰减抑制账本(按主题指纹,永久降权随时间衰减)+ 集合 dismiss。
    func dismissRecommended(_ id: UUID, now: Date = Date()) {
        if let ws = collection.workspace(id), let fp = ws.fingerprint {
            suppression = suppression.recordingDismissal(fp, at: now)
            saveSuppression()
        }
        treeCache[id] = nil; modelPlans[id] = nil; modelFed[id] = nil; modelPlanSignatures[id] = nil
        feedback = feedback.clearingWorkspace(id); saveFeedback()   // 工作区没了 → 清它的节点反馈
        structureEdits = structureEdits.clearingWorkspace(id); saveStructureEdits()
        seeds[id] = nil; saveSeeds()
        apply { $0.dismissing(id) }
    }

    /// 「标记为长期 AI 文件夹」:推荐 → 用户工作区。**把本会话发现的成员固定进种子** —— 否则升成用户工作区后
    /// 重启就只剩壳(用户工作区不靠后台发现的 memberRefs 召回,靠种子)。
    func promoteToUser(_ id: UUID) {
        if let refs = memberRefsByWorkspace[id], !refs.isEmpty {
            mutateSeed(id) { $0.pinning(Array(refs), updatedAt: Date()) }
        }
        apply { $0.promotingToUser(id) }
    }
    func setPinned(_ id: UUID, _ pinned: Bool) { apply { $0.pinning(id, pinned) } }
    func hide(_ id: UUID) { apply { $0.hiding(id) } }
    func removeUserWorkspace(_ id: UUID) {
        treeCache[id] = nil; modelPlans[id] = nil; modelFed[id] = nil; modelPlanSignatures[id] = nil
        feedback = feedback.clearingWorkspace(id); saveFeedback()
        structureEdits = structureEdits.clearingWorkspace(id); saveStructureEdits()
        seeds[id] = nil; saveSeeds()
        apply { $0.removingUserWorkspace(id) }
    }
    func rename(_ id: UUID, to title: String) {
        apply { $0.renaming(id, to: title) }
        mutateSeed(id) { $0.settingTitle(title, updatedAt: Date()) }   // 标题也进种子(模型再生成时沿用)
    }
    func markOpened(_ id: UUID) { apply { $0.markingOpened(id, at: Date()) } }

    private func apply(_ transform: (AIWorkspaceCollection) -> AIWorkspaceCollection) {
        let next = transform(collection)
        guard next != collection else { return }
        collection = next
        persist()
    }

    // MARK: - 持久化(UserDefaults JSON;只存元数据 + 抑制账本,绝不存绝对路径)

    private func persist() {
        if let data = try? JSONEncoder().encode(collection) { defaults.set(data, forKey: Self.storageKey) }
    }

    private func saveSuppression() {
        if let data = try? JSONEncoder().encode(suppression) { defaults.set(data, forKey: Self.suppressionKey) }
    }

    private func saveFeedback() {
        if let data = try? JSONEncoder().encode(feedback) { defaults.set(data, forKey: Self.feedbackKey) }
    }

    private func saveStructureEdits() {
        if let data = try? JSONEncoder().encode(structureEdits) { defaults.set(data, forKey: Self.structureKey) }
    }

    private func saveSeeds() {
        if let data = try? JSONEncoder().encode(seeds) { defaults.set(data, forKey: Self.seedsKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func load(from defaults: UserDefaults) -> AIWorkspaceCollection {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AIWorkspaceCollection.self, from: data)
        else { return AIWorkspaceCollection() }
        return decoded
    }

    private static func loadSuppression(from defaults: UserDefaults) -> AIThemeSuppressionLedger {
        guard let data = defaults.data(forKey: suppressionKey),
              let decoded = try? JSONDecoder().decode(AIThemeSuppressionLedger.self, from: data)
        else { return AIThemeSuppressionLedger() }
        return decoded
    }
}
