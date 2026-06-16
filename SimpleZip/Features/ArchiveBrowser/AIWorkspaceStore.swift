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
    /// 正在**模型重新生成**目录的工作区(点刷新触发)。UI 据此显示华丽的「AI 正在重新整理…」动效,而非干显示「自动整理」。
    /// 只在刷新点击 + 模型完成时变,不在 FSEvents reload 路径上,故 @Published 安全。
    @Published private(set) var regenerating: Set<UUID> = []

    /// 持久:不感兴趣的衰减抑制账本(工作区级)。
    private var suppression: AIThemeSuppressionLedger
    /// 持久:节点级「我很喜欢 / 我不喜欢」反馈(工作区 × 成员 ref)。不喜欢的成员从树里剔除。
    private var feedback: AINodeFeedbackLedger
    /// 持久:虚拟结构编辑(分组改名 + 成员移动)。派生树之上套用。
    private var structureEdits: AIWorkspaceStructureEdits
    /// 持久:每工作区的**用户种子**(标题 / 主题提示词 / 固定 / 排除 / 默认 App)。这是闭环的核心 —— 用户的修改
    /// (喜欢→pin、不喜欢→exclude、描述/改名→themePrompts、手动加入→pin)都落进种子,**下次召回 / 发现据此更懂你**。
    private var seeds: [UUID: AIWorkspaceUserSeed]
    /// 持久:泛化反馈学习层。like/dislike 摊到候选信号(角色 / token / 位置)上累积权重 → 召回 / 喂模型前软调:
    /// 强负同类少进来(非全局硬删),正权重更优先。
    private var learning: AIWorkspaceLearningStore
    /// 持久:**模型整理好的虚拟树快照**(按 workspace UUID)。重启直接展示上次的 AI 目录,**不退回「自动整理」**
    /// (用户:每次重启变自动整理太蠢)。只存 modelAssisted 树;含非加密的名字 / 路径(路径不是隐私风险,见隐私口径);
    /// 加密内容绝不入树故不落盘。只有点「刷新」才重排序;新文件下一轮追加进已有目录,不自动重排。
    private var treeSnapshots: [UUID: AIVirtualFolderTree]

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
    /// 正在单独生成 AI 建议的工作区(去重,一次只跑一个/工作区)。
    private var suggestionsInFlight: Set<UUID> = []

    // 模型门控的后台发现(用户:建文件夹是后台行为,模型复核「真能撑起一个主题」才出现,质量优先不保数量):
    private typealias PendingThemeCandidate = (
        ws: AIWorkspace,
        fed: [AIVirtualNodeCandidate],
        ruleRefs: Set<AIContextSourceRef>
    )
    /// 本轮规则候选主题(theme.id → 工作区壳 + 喂模型的候选集 + 规则簇成员 ref);未复核的逐个排队后台复核。
    private var pendingCandidates: [String: PendingThemeCandidate] = [:]
    /// 复核结论(theme.id → 是否值得出现 + 模型标题 + plan + 选定成员)。本会话缓存,不重复复核同一主题。
    private var themeVerdicts: [String: ReviewVerdict] = [:]
    private var reviewInFlight: Set<String> = []
    private var reviewAttemptsByTheme: [String: Int] = [:]
    private var reviewPumpTask: Task<Void, Never>?

    // 只读调试计数(诊断「为什么 0 通过」):发起的复核数 vs 各结局。发起 − (报错+判否+kept少+通过) = 仍在飞/卡住。
    private var reviewDispatched = 0
    private var reviewThrew = 0       // review() 返回 nil(模型生成失败 / 超时)
    private var reviewExpired = 0     // 复核成功,但本主题已被新一轮 discovery 刷掉(池 churn,白跑)
    private var reviewUnworthy = 0    // 模型判 worthSurfacing == false
    private var reviewThin = 0        // worthSurfacing 但选中成员 < 2
    private var reviewApproved = 0
    private var reviewLastGroups = 0  // 上次复核模型给的分组数
    private var reviewLastKept = 0    // 上次复核翻译回真实 id 后的成员数

    private struct ReviewVerdict {
        let approved: Bool
        let title: String?
        let plan: AIVirtualFolderPlan
        let memberRefs: Set<AIContextSourceRef>
        let members: [AIVirtualNodeCandidate]
    }

    private let defaults: UserDefaults
    private static let storageKey = "SimpleZip.ai.workspaces.v1"
    private static let suppressionKey = "SimpleZip.ai.themeSuppression.v1"
    private static let feedbackKey = "SimpleZip.ai.nodeFeedback.v1"
    private static let structureKey = "SimpleZip.ai.structureEdits.v1"
    private static let seedsKey = "SimpleZip.ai.workspaceSeeds.v1"
    private static let learningKey = "SimpleZip.ai.learning.v1"
    private static let treeSnapshotKey = "SimpleZip.ai.treeSnapshots.v1"

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
        self.learning = AIWorkspaceStore.decode(AIWorkspaceLearningStore.self, key: Self.learningKey, from: defaults)
            ?? AIWorkspaceLearningStore()
        self.treeSnapshots = AIWorkspaceStore.decode([UUID: AIVirtualFolderTree].self, key: Self.treeSnapshotKey, from: defaults) ?? [:]
        // 启动直接用上次的 AI 目录快照(重启不退回「自动整理」);refreshRecommendations 在后台静默续期。
        self.treeCache = self.treeSnapshots
        persist()
    }

    /// 侧边栏渲染的可见工作区。**AI 加权排序**(主题强度 + 打开频率 + 最近度衰减)—— 点一下只是软加权,
    /// 不僵硬置顶;随时间连续重排。
    var visibleWorkspaces: [AIWorkspace] { collection.ranked(now: Date()) }

    func workspace(_ id: UUID) -> AIWorkspace? { collection.workspace(id) }

    /// DevTools 只读调试计数:持久可见集合 + 本会话隐藏竞争池。隐藏候选不进 `collection`,否则会误当成
    /// 可见 AI 文件夹;但调试页需要看见它们是否正在生成 / 复核。
    nonisolated struct DebugCounts: Encodable, Equatable {
        let visible: Int
        let total: Int
        let recommended: Int
        let userCreated: Int
        let hiddenCandidates: Int
        let approvedReviews: Int
        let reviewsInFlight: Int
        let hidden: Int
        let dismissed: Int
        let pinned: Int
        let described: Int
        // 复核结果分布(诊断 0 通过)。
        let reviewDispatched: Int
        let reviewThrew: Int
        let reviewExpired: Int
        let reviewUnworthy: Int
        let reviewThin: Int
        let reviewApproved: Int
        let reviewLastGroups: Int
        let reviewLastKept: Int
    }

    var debugCounts: DebugCounts {
        let workspaces = collection.workspaces
        return DebugCounts(
            visible: workspaces.filter { $0.visibility == .visible }.count,
            total: workspaces.count,
            recommended: workspaces.filter { $0.origin == .recommended }.count,
            userCreated: workspaces.filter { $0.origin == .userCreated }.count,
            hiddenCandidates: pendingCandidates.count,
            approvedReviews: themeVerdicts.values.filter(\.approved).count,
            reviewsInFlight: reviewInFlight.count,
            hidden: workspaces.filter { $0.visibility == .hidden }.count,
            dismissed: workspaces.filter { $0.visibility == .dismissed }.count,
            pinned: workspaces.filter(\.pinned).count,
            described: workspaces.filter { $0.userDescription != nil }.count,
            reviewDispatched: reviewDispatched,
            reviewThrew: reviewThrew,
            reviewExpired: reviewExpired,
            reviewUnworthy: reviewUnworthy,
            reviewThin: reviewThin,
            reviewApproved: reviewApproved,
            reviewLastGroups: reviewLastGroups,
            reviewLastKept: reviewLastKept
        )
    }

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
            self.treeCache = self.treeSnapshots   // 保留 AI 整理快照(用户工作区重启仍显示上次目录)
            pendingCandidates = [:]
            themeVerdicts = [:]
            reviewAttemptsByTheme = [:]
            reviewPumpTask?.cancel()
            let next = collection.replacingRecommended([])
            if next != collection { collection = next }
            self.memberRefsByWorkspace = memberRefsByWorkspace.filter {
                collection.workspace($0.key)?.origin == .userCreated
            }
            persist()
            return
        }

        // 设置里的上限 = **可展示**数量;模型可用时后台多生成一批候选主题,让通过规则质量门控的候选先留在
        // 隐藏参赛池里竞争 / 复核。只有模型复核通过的胜者才进入可见区,避免半成品工作区先露出来。
        let displayLimit = AppPreferences.aiMaxRecommendedWorkspaces
        let reviewPolicy = AIWorkspaceReviewPumpPolicy(
            displayLimit: displayLimit, hiddenCandidateCount: 0,
            activityLevel: AppPreferences.aiBackgroundActivityLevel)
        let candidateLimit = AIReportAssistant.isReady ? reviewPolicy.candidateLimit : displayLimit
        let policy = AIRecommendationPolicy(maxThemes: candidateLimit)
        let suppression = self.suppression
        // **重活(跨位置语义聚类)挪出 MainActor** —— 开窗首帧不被 AI 发现拖住(用户实测卡;倒排索引已降复杂度,
        // 但聚类仍不该占主线程)。纯 Core(Sendable)→ Task.detached,回主线程原子安装。
        let sourceHadRecords = !files.isEmpty || !tasks.isEmpty
        Task.detached(priority: .utility) { [files, tasks, attention, suppression, policy, pool, pathsBySourceRef, sourceHadRecords, now] in
            let out = AIWorkspaceDiscovery.discover(
                files: files, tasks: tasks, attention: attention, suppression: suppression, now: now, policy: policy)
            await MainActor.run {
                self.applyDiscovery(generation: generation, pool: pool,
                                    paths: pathsBySourceRef, sourceHadRecords: sourceHadRecords,
                                    output: out, now: now)
            }
        }
    }

    /// off-main 聚类回主线程:只认最新一轮(过期结果丢弃),原子安装 pool + 成员引用 + 推荐工作区。
    private func applyDiscovery(generation: Int, pool: [AIVirtualNodeCandidate],
                               paths: [AIContextSourceRef: String],
                               sourceHadRecords: Bool,
                               output: AIWorkspaceDiscovery.Output, now: Date) {
        guard generation == refreshGeneration else { return }   // 期间又发起了新一轮 → 丢弃这次
        self.pool = pool
        self.pathsBySourceRef = paths
        self.treeCache = self.treeSnapshots   // 候选池变 → 失效非快照(确定性)树;保留 AI 整理快照(不退回自动整理)

        guard sourceHadRecords else {
            // 启动早期 / 历史或索引尚未加载时,不要把“暂无输入”误当作“没有推荐”而清掉上次已发布的 AI 文件夹。
            // 真正关掉推荐走上面的偏好门控;有输入但无合格主题时才允许下面的替换逻辑收敛可见列表。
            pendingCandidates = [:]
            reviewAttemptsByTheme = [:]
            reviewPumpTask?.cancel()
            return
        }

        guard AIReportAssistant.isReady else {
            // 模型不可用:规则门控 + 全发布(确定性树,UI 标「自动整理」)—— 没有模型就退回这条稳妥路径。
            let recs = output.themes.map { (ws: $0.toRecommendedWorkspace(generatedAt: now), refs: Set($0.sourceRefs)) }
            let next = collection.replacingRecommended(recs.map(\.ws))
            self.memberRefsByWorkspace = Dictionary(uniqueKeysWithValues: recs.map { ($0.ws.id, $0.refs) })
            if next != collection { collection = next }
            persist()
            return
        }

        // 模型就绪:**建文件夹是后台行为** —— 规则候选已过质量门控,但仍只进入隐藏参赛池;逐个让模型复核
        // 「真能撑起一个主题」。复核通过才发布名字 / 选成员 / 分组并缓存,复核判否则在隐藏池淘汰。
        var pending: [String: PendingThemeCandidate] = [:]
        for theme in output.themes {
            let ws = theme.toRecommendedWorkspace(generatedAt: now)
            let refSet = Set(theme.sourceRefs)
            let members = pool.filter { !$0.sourceRefs.isEmpty && $0.sourceRefs.allSatisfy { refSet.contains($0) } }
            guard members.count >= 2 else { continue }
            pending[theme.id] = (ws, members + themeRelevantExtra(ws: ws, members: members, cap: 80),
                                 Set(members.flatMap(\.sourceRefs)))
        }
        // **跨发现轮次保留**正在复核中 / 已复核通过的旧主题:本轮 discovery 没再聚出它,不代表它没用 —— 否则在飞的
        // 慢复核回来算「过期」白跑,已通过的可见文件夹也会被刷掉,永远攒不起可见数(用户实测 0 可见挂很久)。
        for themeID in reviewInFlight where pending[themeID] == nil {
            if let old = pendingCandidates[themeID] { pending[themeID] = old }
        }
        for (themeID, verdict) in themeVerdicts where verdict.approved && pending[themeID] == nil {
            if let old = pendingCandidates[themeID] { pending[themeID] = old }
        }
        pendingCandidates = pending
        themeVerdicts = themeVerdicts.filter { pending[$0.key] != nil }   // 不在本轮的旧结论清掉
        reviewAttemptsByTheme = reviewAttemptsByTheme.filter { pending[$0.key] != nil }
        pumpThemeReviews()
        republishReviewedThemes()
    }

    /// 后台复核泵:未复核候选不能进可见区,但隐藏池要持续形成已通过的竞争者。一次只喂一个主题给模型;
    /// 失败 / 暂时判否时,换更可能成功的主题或扩大上下文再试,直到达到目标或耗尽有限预算。
    private func pumpThemeReviews() {
        guard #available(macOS 26.0, *), AIReportAssistant.isReady else { return }
        guard !pendingCandidates.isEmpty else { return }
        let policy = AIWorkspaceReviewPumpPolicy(
            displayLimit: AppPreferences.aiMaxRecommendedWorkspaces,
            hiddenCandidateCount: pendingCandidates.count,
            activityLevel: AppPreferences.aiBackgroundActivityLevel)
        let approved = themeVerdicts.values.filter(\.approved).count
        // **竞争不停**(用户:小模型质量差,竞争状态不能停):达到 approvedTarget 后不早停,继续把剩下的主题都复核完
        // (为竞争持续找更好的候选),只靠 `nextThemeReviewCandidate` 返回 nil(全复核完 / 耗尽 attempts)自然收敛;
        // backoff 延时已随已通过数拉长,慢跑不抢资源。
        guard reviewInFlight.isEmpty else { return }
        guard let next = nextThemeReviewCandidate(now: Date(), policy: policy, approvedCount: approved) else { return }
        let attempt = reviewAttemptsByTheme[next.id, default: 0] + 1
        let fed = reviewFed(for: next.candidate, attempt: attempt)
        scheduleThemeReview(themeID: next.id, ws: next.candidate.ws, fed: fed,
                            attempt: attempt, approvedTarget: policy.approvedTarget)
    }

    private func nextThemeReviewCandidate(now: Date, policy: AIWorkspaceReviewPumpPolicy, approvedCount: Int)
        -> (id: String, candidate: PendingThemeCandidate)? {
        let scored: [(id: String, candidate: PendingThemeCandidate, score: Double)] = pendingCandidates.compactMap {
            id, candidate in
            if themeVerdicts[id]?.approved == true || reviewInFlight.contains(id) { return nil }
            let attempts = reviewAttemptsByTheme[id, default: 0]
            guard attempts < policy.maxAttemptsPerTheme else { return nil }
            let rejectedPenalty = themeVerdicts[id] == nil ? 0.0 : 3.0
            let score = competitionScore(candidate.ws, memberCount: candidate.ruleRefs.count, now: now)
                - Double(attempts) * policy.attemptPenalty(approvedCount: approvedCount)
                - rejectedPenalty
            return (id, candidate, score)
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }.first.map { ($0.id, $0.candidate) }
    }

    private func reviewFed(for candidate: PendingThemeCandidate, attempt: Int) -> [AIVirtualNodeCandidate] {
        let members = pool.filter {
            !$0.sourceRefs.isEmpty && $0.sourceRefs.allSatisfy { candidate.ruleRefs.contains($0) }
        }
        guard !members.isEmpty else { return candidate.fed }
        let cap = min(220, 80 + max(0, attempt - 1) * 60)
        return members + themeRelevantExtra(ws: candidate.ws, members: members, cap: cap)
    }

    /// 后台复核一个候选主题(模型判断值不值得出现 + 产出 plan)。串行闸保证不与其它生成重叠。
    private func scheduleThemeReview(themeID: String, ws: AIWorkspace, fed: [AIVirtualNodeCandidate],
                                     attempt: Int, approvedTarget: Int) {
        guard #available(macOS 26.0, *) else { return }
        reviewInFlight.insert(themeID)
        reviewAttemptsByTheme[themeID] = attempt
        reviewDispatched += 1
        let input = makeModelPlanInput(ws: ws, candidates: fed)
        Task { @MainActor in
            let review = try? await AIVirtualFolderModelPlanner.review(
                for: input, attempt: attempt, approvedTarget: approvedTarget)
            self.reviewInFlight.remove(themeID)
            guard let review else {
                self.reviewThrew += 1   // 模型生成失败 / 超时
                self.rescheduleReviewPump(minDelay: 1.5)
                return
            }
            guard self.pendingCandidates[themeID] != nil else {
                self.reviewExpired += 1   // 复核回来发现本主题已被新一轮 discovery 刷掉(池 churn,白跑)
                self.rescheduleReviewPump(minDelay: 1.5)
                return
            }
            var referenced = Set<String>()
            func collect(_ gs: [AIVirtualFolderGroupPlan]) { for g in gs { referenced.formUnion(g.candidateIDs); collect(g.children) } }
            collect(review.plan.groups)
            let kept = fed.filter { referenced.contains($0.id) }
            let approvedThis = review.worthSurfacing && kept.count >= 2
            self.reviewLastGroups = review.plan.groups.count
            self.reviewLastKept = kept.count
            if approvedThis { self.reviewApproved += 1 }
            else if !review.worthSurfacing { self.reviewUnworthy += 1 }
            else { self.reviewThin += 1 }   // 模型说值得,但翻译回的成员 < 2(序号没对上 / 选太少)
            self.themeVerdicts[themeID] = ReviewVerdict(
                approved: approvedThis,
                title: review.plan.workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                plan: review.plan, memberRefs: Set(kept.flatMap(\.sourceRefs)), members: kept)
            self.republishReviewedThemes()
            self.rescheduleReviewPump()
        }
    }

    /// 复核结束后排下一轮泵:延时按当前已通过数 / 活跃度退避;`minDelay` 给失败 / 过期路径一个最小间隔。
    private func rescheduleReviewPump(minDelay: TimeInterval = 0) {
        let approved = themeVerdicts.values.filter(\.approved).count
        let policy = AIWorkspaceReviewPumpPolicy(
            displayLimit: AppPreferences.aiMaxRecommendedWorkspaces,
            hiddenCandidateCount: pendingCandidates.count,
            activityLevel: AppPreferences.aiBackgroundActivityLevel)
        scheduleReviewPump(after: max(minDelay, policy.reviewDelaySeconds(approvedCount: approved)))
    }

    private func scheduleReviewPump(after seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        reviewPumpTask?.cancel()
        reviewPumpTask = Task { @MainActor in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.pumpThemeReviews()
        }
    }

    /// 把隐藏参赛池里**已复核通过**的候选发布成可见推荐工作区。未复核候选只在隐藏池里竞争 / 等待复核,
    /// 不能进入侧栏可见区;复核判否的移除。数量上限走设置。
    private func republishReviewedThemes() {
        let now = Date()
        var scored: [(ws: AIWorkspace, score: Double, refs: Set<AIContextSourceRef>)] = []
        var toCachePlan: [(UUID, ReviewVerdict)] = []
        for (id, c) in pendingCandidates {
            if let v = themeVerdicts[id] {
                guard v.approved, !v.members.isEmpty else { continue }   // 复核判否 → 不发布
                var ws = c.ws
                if let title = v.title, !title.isEmpty { ws.title = title }
                scored.append((ws, competitionScore(ws, memberCount: v.members.count, now: now), v.memberRefs))
                toCachePlan.append((ws.id, v))
            } else if let existing = collection.workspace(c.ws.id), existing.visibility == .visible {
                // 新候选未复核不上屏;但旧的可见推荐已经是上轮发布物,重启 / 重扫时 verdict 缓存为空也不能先消失。
                // 先用本轮规则成员保持它可打开,新复核回来后再按竞争分升级或淘汰。
                scored.append((existing, competitionScore(existing, memberCount: c.ruleRefs.count, now: now), c.ruleRefs))
            }
        }
        // **竞争**:按竞争分降序取前 N(=展示上限)。撑得起主题(成员多)+ 用得多/最近用的胜出,
        // 不思进取(单薄 / 从没打开过 / 负反馈多)的被挤出。
        let capped = Array(scored.sorted { $0.score > $1.score }.prefix(AppPreferences.aiMaxRecommendedWorkspaces))
        let workspaces = capped.map(\.ws)
        var memberRefs: [UUID: Set<AIContextSourceRef>] = [:]
        for item in capped { memberRefs[item.ws.id] = item.refs }
        let keptIDs = Set(capped.map(\.ws.id))
        let next = collection.replacingRecommended(workspaces)
        memberRefsByWorkspace = memberRefs
        if next != collection { collection = next }
        // 缓存复核产出的 plan → 打开不再重跑模型。**有持久快照的工作区不在此重排**:冻结上次 AI 目录,
        // 只有点「刷新」才重排(用户:每次重启 / 后台复核都重排太蠢)。新工作区(无快照)才缓存 plan + 建树存快照。
        for (wsID, v) in toCachePlan where keptIDs.contains(wsID) && treeSnapshots[wsID] == nil {
            let sig = v.members.map(\.id).sorted().joined(separator: ",")
            modelPlanSignatures[wsID] = sig
            modelPlans[wsID] = (sig, v.plan)
            modelFed[wsID] = v.members
            treeCache[wsID] = nil
        }
        persist()
    }

    /// 竞争分:撑得起主题(成员多)+ 用得多 / 最近用过的胜出;从没打开过 / 单薄 / 负反馈多的「不思进取」被降权。
    private func competitionScore(_ ws: AIWorkspace, memberCount: Int, now: Date) -> Double {
        var s = ws.relevanceScore * 5.0                          // 主题强度(复核 / 发现给的)
        s += min(Double(memberCount), 12) * 0.5                  // 实质:成员越多越撑得起(封顶防灌水)
        s += log2(Double(max(0, ws.openCount)) + 1) * 1.0        // 用得多
        if let last = ws.lastOpenedAt {                          // 最近用过(7 天半衰);从没打开 = 不加分
            s += pow(0.5, max(0, now.timeIntervalSince(last)) / 86_400 / 7.0) * 1.5
        }
        s -= Double(ws.negativeFeedbackCount) * 2.0              // 负反馈降权
        return s
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
        cacheModelTree(id, tree)   // modelAssisted → 落持久快照(重启直接展示)
        return tree
    }

    /// 一个工作区当前被排除的成员 ref(我不喜欢 + 种子排除)。
    private func excludedRefs(for ws: AIWorkspace) -> Set<AIContextSourceRef> {
        feedback.dislikedRefs(ws.id).union(seeds[ws.id]?.excludedSourceRefs ?? [])
    }

    /// 用户点「刷新」:**强制重跑模型**(清掉本工作区的模型 plan / 签名 / 树缓存 → 下次 `virtualTree` 重新让模型
    /// 选成员 + 分组 + 命名),并顺带 kick 一轮后台预索引(新文件 / 新活动有机会进来)。
    func refreshWorkspaceTree(_ id: UUID) {
        modelPlanSignatures[id] = nil
        modelPlans[id] = nil
        modelFed[id] = nil
        treeCache[id] = nil
        treeSnapshots[id] = nil; saveTreeSnapshots()   // 点刷新 = 丢弃旧快照,重排序(用户:只有刷新才重排)
        if AIReportAssistant.isReady {
            regenerating.insert(id)                    // 标记「正在重新生成」→ UI 显示华丽动效,不显示「自动整理」
            scheduleRegeneratingTimeout(id)            // 兜底:模型迟迟不出也别一直转(收起动效,显示当前结果)
        }
        objectWillChange.send()
        AIBackgroundIndexer.shared.runIfEnabled()   // 重扫白名单(门控未过则什么都不做)→ 完成后回调发现刷新
    }

    func isRegenerating(_ id: UUID) -> Bool { regenerating.contains(id) }

    /// 兜底超时:模型生成很慢(12 代),但若 90s 还没出树就收起动效(避免无限转);真出树时由 cacheModelTree 提前收起。
    private func scheduleRegeneratingTimeout(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            if self.regenerating.contains(id) { self.regenerating.remove(id) }
        }
    }

    /// plan(nil = 确定性)+ 成员 → 套用户结构编辑后的最终树。模型 plan 的 AI 建议 → `.action` 子节点(带本地化标题)。
    private func buildTree(ws: AIWorkspace, members: [AIVirtualNodeCandidate],
                           plan: AIVirtualFolderPlan?, mode: AIVirtualTreeGenerationMode) -> AIVirtualFolderTree {
        let base: AIVirtualFolderTree
        if let plan {
            base = AIVirtualFolderTreeBuilder.build(workspace: ws, plan: plan, candidates: members,
                                                    pathsBySourceRef: pathsBySourceRef,
                                                    suggestionLabels: Self.suggestionLabels,
                                                    mode: mode, generatedAt: Date())
        } else {
            base = AIVirtualFolderTreeBuilder.buildDeterministic(
                workspace: ws, candidates: members, pathsBySourceRef: pathsBySourceRef, generatedAt: Date())
        }
        // 用户结构编辑(分组改名 + 成员移动)永远盖在最后 —— 无论树是确定性还是模型生成的,用户整理不丢。
        return base.applyingStructureEdits(
            groupTitles: structureEdits.groupTitles(ws.id), assignments: structureEdits.assignments(ws.id))
    }

    /// AI 建议 token → 本地化标题(喂给 builder 给 `.action` 节点用;token 与 `allowedSuggestionDescriptors` 同源)。
    /// 每次读取按当前界面语言取(语言可中途切)。
    static var suggestionLabels: [String: String] {
        [
            "hash": L10n.text("aiWorkspace.suggest.hash"),
            "compress": L10n.text("aiWorkspace.suggest.compress"),
            "test": L10n.text("aiWorkspace.suggest.test"),
            "inspect": L10n.text("aiWorkspace.suggest.inspect"),
            "convert": L10n.text("aiWorkspace.suggest.convert"),
        ]
    }

    /// 模型就绪 + 本批成员还没让模型排过 → 异步让**本地模型生成虚拟目录树**(白皮书:AI 文件夹的树必须过模型,
    /// 不能只是确定性 bucket)。先确定性占位、模型回来再替换;失败 / 不可用就一直用确定性(不崩、UI 如实标注)。
    private func maybeScheduleModelPlan(id: UUID, ws: AIWorkspace, members: [AIVirtualNodeCandidate], sig: String) {
        guard #available(macOS 26.0, *), AIReportAssistant.isReady, members.count >= 2 else { return }
        guard modelPlanSignatures[id] != sig else { return }
        modelPlanSignatures[id] = sig   // 占位:失败不重试本批(免刷模型);成员变了 sig 变才重排
        // 喂模型 = 当前成员 + 主题相关的额外候选 → 模型**选**哪些最合适进主题(不只是重排已选)+ 分组 + 命名。
        let fed = members + themeRelevantExtra(ws: ws, members: members, cap: 80)
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
        let finalPlan = AIVirtualFolderPlan(workspaceTitle: plan.workspaceTitle, groups: groups,
                                            suggestions: plan.suggestions)
        let modelTree = buildTree(ws: ws, members: keptFed, plan: finalPlan, mode: .modelAssisted)
        guard !modelTree.isEmpty else { return }
        modelFed[id] = keptFed
        modelPlans[id] = (sig, finalPlan)
        cacheModelTree(id, modelTree)   // 模型整理完成 → 落持久快照
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
        let roleHints = Set(members.flatMap(\.roleTags))   // 成员的角色 → 同角色候选也算弱命中(灵敏度)
        let scored: [(AIVirtualNodeCandidate, Double)] = pool.compactMap { cand in
            guard !memberIDs.contains(cand.id),
                  !cand.sourceRefs.contains(where: { excluded.contains($0) }) else { return nil }
            let signals = learningSignals(for: cand)
            if learning.isStronglyDisliked(ws.id, signals: signals) { return nil }   // 同类被排斥 → 不喂模型
            // 灵敏度:精确 token 命中 + **子串 / CJK 命中**(主题 token 是候选某 token 子串或反之)+ 同角色命中
            // → 让 AI 真有东西可从索引里捞进主题(用户:动态加文件灵敏度太低,撑不起主题)。
            let candTokens = simpleTokens(cand.displayName)
            var overlap = Double(candTokens.intersection(themeTokens).count)
            if overlap == 0 {
                for t in themeTokens where t.count >= 2 {
                    if candTokens.contains(where: { $0.contains(t) || t.contains($0) }) { overlap = 0.5; break }
                }
            }
            if overlap == 0, !cand.roleTags.isEmpty, !Set(cand.roleTags).isDisjoint(with: roleHints) { overlap = 0.3 }
            guard overlap > 0 else { return nil }
            return (cand, overlap + learning.affinity(ws.id, signals: signals) * 0.5)   // 学习权重微调排序
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
        return AIVirtualFolderPlanInput(
            workspace: fact,
            candidates: candidates.map { AIVirtualNodePromptCandidate(candidate: $0) },
            learningHints: learningHints(for: ws, seed: seed))
    }

    /// 把用户对这个工作区的调教(种子固定 / 排除 + 分组命名)投影成 `AIWorkspaceLearningHints` 喂模型(架构债 #4:
    /// 喂进 prompt,不只 Swift 侧软过滤)。固定 = 喜欢 / 手动加入 / 移动(`likeNode`/`addMembers`/`moveNodes` 都写种子
    /// pin);排除 = 不喜欢 + 从工作区移除。带名字 + 来源目录 + 角色 —— **路径不是隐私红线**(SimpleZip 只护加密内容 /
    /// 口令 / 明文,见隐私口径),来源目录能帮模型看出「用户把哪类东西、放哪儿的留了下来」;空则 nil。
    private func learningHints(for ws: AIWorkspace, seed: AIWorkspaceUserSeed?) -> AIWorkspaceLearningHints? {
        let kept = resolveItemHints(Set(seed?.pinnedSourceRefs ?? []))
        let removed = resolveItemHints(excludedRefs(for: ws))
        let groupTitles = Array(structureEdits.groupTitles(ws.id).values)
        let hints = AIWorkspaceLearningHints(
            keptItemNames: kept.items, removedItemNames: removed.items,
            preferredRoleTags: kept.roles, rejectedRoleTags: removed.roles,
            userGroupTitles: groupTitles)
        return hints.isEmpty ? nil : hints
    }

    /// 把一组 source ref 用内存候选池回查成「展示名 — 来源目录」+ 角色标签,喂模型 hint 用。来源目录取自
    /// `pathsBySourceRef`(只含权限允许的;**路径可以给模型**),取不到就只给名字;池里查不到的 ref 静默跳过。
    private func resolveItemHints(_ refs: Set<AIContextSourceRef>) -> (items: [String], roles: [String]) {
        guard !refs.isEmpty else { return ([], []) }
        var items: [String] = []; var seen = Set<String>(); var roles = Set<String>()
        for cand in pool where cand.sourceRefs.contains(where: { refs.contains($0) }) {
            let dir = cand.sourceRefs.compactMap { pathsBySourceRef[$0] }.first
                .map { ($0 as NSString).deletingLastPathComponent }
                .flatMap { $0.isEmpty || $0 == "/" ? nil : Self.abbreviatingHome($0) }
            let desc = dir.map { "\(cand.displayName) — \($0)" } ?? cand.displayName
            if seen.insert(desc).inserted { items.append(desc) }
            roles.formUnion(cand.roleTags)
        }
        return (items, roles.sorted())
    }

    /// home 目录缩成 ~(喂模型 hint 的来源目录展示用,纯字符串美化)。
    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
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
        let excluded = excludedRefs(for: ws)
        let pinned = Set(seeds[ws.id]?.pinnedSourceRefs ?? [])
        return result.filter { cand in
            if cand.sourceRefs.contains(where: { excluded.contains($0) }) { return false }   // 硬排除(本工作区)
            if cand.sourceRefs.contains(where: { pinned.contains($0) }) { return true }       // 固定永远留
            // 泛化负反馈:同类(角色 / 类型 / 位置)被明显排斥 → 软剔除(非全局硬删,只在这个工作区)。
            return !learning.isStronglyDisliked(ws.id, signals: learningSignals(for: cand))
        }
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

    /// 「我很喜欢」:确认保留(去角标)+ **固定进种子** + **泛化正反馈**(同角色 / 类型 / 位置的更优先)。
    func likeNode(workspaceID: UUID, refs: [AIContextSourceRef]) {
        guard !refs.isEmpty else { return }
        feedback = feedback.liking(workspaceID, refs)
        saveFeedback()
        mutateSeed(workspaceID) { $0.pinning(refs, updatedAt: Date()) }
        reinforceLearning(workspaceID, refs: refs, by: 1)
        objectWillChange.send()
    }

    /// 「我不喜欢」:移出文件夹 + **写进种子排除集** + **泛化负反馈**(同类的下次少进来,按权重降而非全局硬删)。
    func dislikeNode(workspaceID: UUID, refs: [AIContextSourceRef]) {
        guard !refs.isEmpty else { return }
        feedback = feedback.disliking(workspaceID, refs)
        saveFeedback()
        mutateSeed(workspaceID) { $0.excluding(refs, updatedAt: Date()) }
        reinforceLearning(workspaceID, refs: refs, by: -1)
        objectWillChange.send()
    }

    /// 把一组 ref 对应候选的信号(角色 / 低敏 token / 位置)摊进学习层(喜欢 +、不喜欢 −)。
    private func reinforceLearning(_ workspace: UUID, refs: [AIContextSourceRef], by delta: Double) {
        let refSet = Set(refs)
        let signals = pool
            .filter { !$0.sourceRefs.isEmpty && $0.sourceRefs.contains(where: { refSet.contains($0) }) }
            .flatMap { learningSignals(for: $0) }
        guard !signals.isEmpty else { return }
        learning = learning.reinforcing(workspace, signals: Array(Set(signals)), by: delta)
        saveLearning()
    }

    /// 一个候选的泛化学习信号:角色标签 + 少量低敏语义 token + 位置类别(绝不含路径)。
    private func learningSignals(for candidate: AIVirtualNodeCandidate) -> [String] {
        var signals = candidate.roleTags
        signals += candidate.semanticTokens.prefix(4)
        if let loc = candidate.location?.kind.rawValue { signals.append("loc:" + loc) }
        return signals.filter { !$0.isEmpty }
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
        treeSnapshots[id] = nil; saveTreeSnapshots()
        feedback = feedback.clearingWorkspace(id); saveFeedback()   // 工作区没了 → 清它的节点反馈
        structureEdits = structureEdits.clearingWorkspace(id); saveStructureEdits()
        seeds[id] = nil; saveSeeds(); learning = learning.clearingWorkspace(id); saveLearning()
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
        treeSnapshots[id] = nil; saveTreeSnapshots()
        feedback = feedback.clearingWorkspace(id); saveFeedback()
        structureEdits = structureEdits.clearingWorkspace(id); saveStructureEdits()
        seeds[id] = nil; saveSeeds(); learning = learning.clearingWorkspace(id); saveLearning()
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

    private func saveLearning() {
        if let data = try? JSONEncoder().encode(learning) { defaults.set(data, forKey: Self.learningKey) }
    }

    private func saveTreeSnapshots() {
        if let data = try? JSONEncoder().encode(treeSnapshots) { defaults.set(data, forKey: Self.treeSnapshotKey) }
    }

    /// 缓存一棵树;若是**模型整理好的**(modelAssisted 且非空)就额外存为持久快照(重启直接展示,不退回自动整理)。
    /// 确定性占位树只进内存缓存,不落快照(免「锁死」自动整理态)。
    private func cacheModelTree(_ id: UUID, _ tree: AIVirtualFolderTree) {
        treeCache[id] = tree
        if tree.generationMode == .modelAssisted, !tree.isEmpty {
            treeSnapshots[id] = tree
            saveTreeSnapshots()
            if regenerating.contains(id) { regenerating.remove(id) }   // 模型整理完成 → 收起「正在重新生成」动效
            maybeScheduleSuggestions(id)   // 通过后**单独生成 AI 建议**(门控不背这个包袱)→ 回来挂 .action 子节点
        }
    }

    /// 文件夹整理好后,单独让模型给条目挑 AI 建议(扁平简单 schema,可靠)。回来把 suggestions 并进 plan、重建带
    /// `.action` 子节点的树、重存快照。只在 plan 还没有建议时跑一次(避免重建循环);失败 / 空则保持无建议。
    private func maybeScheduleSuggestions(_ id: UUID) {
        guard #available(macOS 26.0, *), AIReportAssistant.isReady else { return }
        guard let cached = modelPlans[id], cached.plan.suggestions.isEmpty,
              let fed = modelFed[id], !fed.isEmpty,
              !suggestionsInFlight.contains(id) else { return }
        suggestionsInFlight.insert(id)
        let items = fed.map { AIVirtualNodePromptCandidate(candidate: $0) }
        let sig = cached.sig
        Task { @MainActor in
            defer { self.suggestionsInFlight.remove(id) }
            guard let suggestions = try? await AIVirtualFolderModelPlanner.suggestions(forItems: items),
                  !suggestions.isEmpty,
                  self.modelPlans[id]?.sig == sig,                 // 期间没被刷新 / 重排
                  let ws = self.collection.workspace(id) else { return }
            let newPlan = AIVirtualFolderPlan(workspaceTitle: cached.plan.workspaceTitle,
                                              groups: cached.plan.groups, suggestions: suggestions)
            self.modelPlans[id] = (sig, newPlan)
            let tree = self.buildTree(ws: ws, members: fed, plan: newPlan, mode: .modelAssisted)
            self.cacheModelTree(id, tree)   // 重建带 .action 建议的树(此时 plan.suggestions 非空 → 不再调度)
            self.objectWillChange.send()
        }
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
