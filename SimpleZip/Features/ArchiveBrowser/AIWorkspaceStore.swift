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

    /// 持久:不感兴趣的衰减抑制账本。
    private var suppression: AIThemeSuppressionLedger

    // 内存(每会话由 refreshRecommendations 重建,不落盘 —— 隐私):
    private var pool: [AIVirtualNodeCandidate] = []
    private var memberRefsByWorkspace: [UUID: Set<AIContextSourceRef>] = [:]
    private var pathsBySourceRef: [AIContextSourceRef: String] = [:]
    private var treeCache: [UUID: AIVirtualFolderTree] = [:]

    private let defaults: UserDefaults
    private static let storageKey = "SimpleZip.ai.workspaces.v1"
    private static let suppressionKey = "SimpleZip.ai.themeSuppression.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = AIWorkspaceStore.load(from: defaults)
        // #89:删掉被打回的固定系统工作区(失败任务 / 校验 / 最近归档 = 活动中心换皮)残留。
        loaded.workspaces.removeAll { $0.origin == .system }
        self.collection = loaded
        self.suppression = AIWorkspaceStore.loadSuppression(from: defaults)
        persist()
    }

    /// 侧边栏渲染的可见工作区(确定性排序,排除 hidden / dismissed)。
    var visibleWorkspaces: [AIWorkspace] { collection.visibleWorkspaces }

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
        self.pool = AIWorkspaceDiscovery.assemblePool(files: files, tasks: tasks)
        self.pathsBySourceRef = pathsBySourceRef
        self.treeCache = [:]   // 候选池变 → 树缓存失效

        guard AppPreferences.aiAssistantEnabled, AppPreferences.aiSidebarShowRecommended else {
            persist(); return
        }

        let out = AIWorkspaceDiscovery.discover(
            files: files, tasks: tasks, attention: attention, suppression: suppression, now: now)
        var next = collection
        var memberRefs: [UUID: Set<AIContextSourceRef>] = [:]
        for theme in out.themes {
            let fresh = theme.toRecommendedWorkspace(generatedAt: now)
            var merged = fresh
            // 保留用户对该推荐的覆盖(固定 / 最近打开);visibility 回 .visible(衰减后重新浮现 = 正确)。
            if let existing = next.workspace(fresh.id) {
                merged.pinned = existing.pinned
                merged.lastOpenedAt = existing.lastOpenedAt
            }
            next = next.upserting(merged)
            memberRefs[fresh.id] = Set(theme.sourceRefs)
        }
        self.memberRefsByWorkspace = memberRefs
        if next != collection { collection = next }
        persist()
    }

    // MARK: - 虚拟树(plan/builder,不再 nil)

    /// 工作区的虚拟文件夹树。从内存候选池召回该工作区成员 → 确定性 plan → sanitized 树 → 缓存。
    /// 候选池尚未由 `refreshRecommendations` 填充(刚启动)时返回 nil → 内容区显示空状态。
    func virtualTree(for id: UUID) -> AIVirtualFolderTree? {
        if let cached = treeCache[id] { return cached }
        guard let ws = collection.workspace(id) else { return nil }
        let members = memberCandidates(for: ws)
        guard !members.isEmpty else { return nil }
        let tree = AIVirtualFolderTreeBuilder.buildDeterministic(
            workspace: ws, candidates: members, pathsBySourceRef: pathsBySourceRef, generatedAt: Date())
        treeCache[id] = tree
        return tree
    }

    /// 召回某工作区的成员候选。推荐工作区按发现时记下的成员 ref(候选的 source refs ⊆ 主题成员集)。
    private func memberCandidates(for ws: AIWorkspace) -> [AIVirtualNodeCandidate] {
        guard let refs = memberRefsByWorkspace[ws.id] else { return [] }
        return pool.filter { !$0.sourceRefs.isEmpty && $0.sourceRefs.allSatisfy { refs.contains($0) } }
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
        return id
    }

    /// 「不感兴趣」:推荐工作区 → 写衰减抑制账本(按主题指纹,永久降权随时间衰减)+ 集合 dismiss。
    func dismissRecommended(_ id: UUID, now: Date = Date()) {
        if let ws = collection.workspace(id), let fp = ws.fingerprint {
            suppression = suppression.recordingDismissal(fp, at: now)
            saveSuppression()
        }
        treeCache[id] = nil
        apply { $0.dismissing(id) }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) { apply { $0.pinning(id, pinned) } }
    func hide(_ id: UUID) { apply { $0.hiding(id) } }
    func removeUserWorkspace(_ id: UUID) { treeCache[id] = nil; apply { $0.removingUserWorkspace(id) } }
    func rename(_ id: UUID, to title: String) { apply { $0.renaming(id, to: title) } }
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
