//
//  AIWorkspaceModelTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 工作区 / 虚拟树值模型 + 安全清洗(建议四 / 补充十一)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIWorkspaceModelTests {
    private let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let validRef = AIContextSourceRef(kind: .archive, id: "arch-1")
    private let invalidRef = AIContextSourceRef(kind: .archive, id: "ghost")

    @Test func safetyV1Gate() {
        #expect(AISuggestionSafety.safe.isAllowedInV1)
        #expect(!AISuggestionSafety(destructive: true).isAllowedInV1)
        #expect(!AISuggestionSafety(touchesEncryptedContent: true).isAllowedInV1)
    }

    @Test func actionsAreAllDirectlySafe() {
        let actions: [AISuggestionAction] = [
            .openTask(id1), .openFolder(path: "/x"), .revealFile(path: "/x/a"),
            .openArchive(path: "/x/a.zip", revealEntry: "README.md"),
            .applyArchiveSearch(archiveID: "arch-1", query: "readme"),
            .openReport(taskID: id1), .explainFailure(taskID: id1), .openActivityCenter,
            .pinRecommendedWorkspace(id1), .dismissRecommendedWorkspace(id1)
        ]
        let allSafe = actions.allSatisfy { $0.isDirectlySafe }
        #expect(allSafe)
    }

    @Test func nodeCodableRoundTripWithAction() throws {
        let node = AIVirtualNode(id: id1, kind: .archive, title: "a", sourceRefs: [validRef],
                                 primaryAction: .openArchive(path: "/x/a.zip", revealEntry: "README.md"))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(AIVirtualNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func sanitizerDropsInventedRefsAndDestructiveNodes() {
        let nodes = [
            AIVirtualNode(id: id1, kind: .archive, title: "ok", sourceRefs: [validRef]),
            AIVirtualNode(id: id2, kind: .archive, title: "invented", sourceRefs: [invalidRef]),
            AIVirtualNode(id: id3, kind: .archive, title: "danger", sourceRefs: [validRef],
                          safety: AISuggestionSafety(destructive: true))
        ]
        let clean = AIVirtualTreeSanitizer.sanitize(nodes, allowed: [validRef])
        #expect(clean.map(\.title) == ["ok"])
    }

    @Test func sanitizerCleansNestedGroupChildren() {
        let group = AIVirtualNode(id: id1, kind: .group, title: "Group", children: [
            AIVirtualNode(id: id2, kind: .archive, title: "child-ok", sourceRefs: [validRef]),
            AIVirtualNode(id: id3, kind: .archive, title: "child-bad", sourceRefs: [invalidRef])
        ])
        let clean = AIVirtualTreeSanitizer.sanitize([group], allowed: [validRef])
        #expect(clean.count == 1)
        #expect(clean.first?.children.map(\.title) == ["child-ok"])
    }

    @Test func sanitizerDropsEmptiedGroups() {
        let emptyGroup = AIVirtualNode(id: id1, kind: .group, title: "Empty", children: [
            AIVirtualNode(id: id2, kind: .archive, title: "bad", sourceRefs: [invalidRef])
        ])
        #expect(AIVirtualTreeSanitizer.sanitize([emptyGroup], allowed: [validRef]).isEmpty)
    }

    @Test func workspaceCodableRoundTrip() throws {
        let ws = AIWorkspace(id: id1, origin: .system, title: "Needs Attention",
                             queryPlan: AIWorkspaceQueryPlan(taskTags: ["checksum-mismatch"]),
                             iconSystemName: "exclamationmark.triangle",
                             generatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(AIWorkspace.self, from: data)
        #expect(decoded == ws)
    }

    // MARK: - AIWorkspaceCollection(建议四:AIWorkspaceStore 纯值底座)

    private func ws(_ key: String, _ origin: AIWorkspace.Origin, title: String = "W",
                    visibility: AIWorkspace.Visibility = .visible, pinned: Bool = false,
                    generatedAt: Double = 0, lastOpenedAt: Double? = nil) -> AIWorkspace {
        AIWorkspace(id: AIStableHash.deterministicUUID(key), origin: origin, title: title,
                    queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "folder",
                    visibility: visibility, pinned: pinned,
                    generatedAt: Date(timeIntervalSince1970: generatedAt),
                    lastOpenedAt: lastOpenedAt.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func visibleWorkspacesExcludesHiddenAndDismissed() {
        let c = AIWorkspaceCollection([
            ws("a", .system),
            ws("b", .system, visibility: .hidden),
            ws("c", .recommended, visibility: .dismissed),
        ])
        #expect(c.visibleWorkspaces.map(\.id) == [AIStableHash.deterministicUUID("a")])
    }

    @Test func visibleWorkspacesStableFallbackOrder() {
        // visibleWorkspaces 现在只给不依赖时间的稳定兜底序(固定优先 → 生成时间新→旧 → 标题)。
        let c = AIWorkspaceCollection([
            ws("old", .system, title: "old", generatedAt: 10),
            ws("recent", .system, title: "recent", generatedAt: 5, lastOpenedAt: 100),
            ws("pinned", .recommended, title: "pinned", pinned: true, generatedAt: 1),
        ])
        #expect(c.visibleWorkspaces.map(\.title) == ["pinned", "old", "recent"])
    }

    @Test func rankedFavorsStrongThemeOverSingleClick() {
        // 用户痛点修复:点一下弱主题**不应**盖过没打开的强主题(软 AI 加权,非僵硬置顶)。
        let now = Date(timeIntervalSince1970: 1_000_000)
        let strong = AIWorkspace(id: id1, origin: .recommended, title: "strong",
                                 queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                 generatedAt: now, relevanceScore: 1.0)
        let weakClicked = AIWorkspace(id: id2, origin: .recommended, title: "weak",
                                      queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                      generatedAt: now, lastOpenedAt: now, openCount: 1, relevanceScore: 0.0)
        let ranked = AIWorkspaceCollection([weakClicked, strong]).ranked(now: now)
        #expect(ranked.map(\.title) == ["strong", "weak"])
    }

    @Test func rankedRewardsFrequentUse() {
        // 但频繁使用的弱主题最终能升上来(频率信号)。
        let now = Date(timeIntervalSince1970: 1_000_000)
        let strong = AIWorkspace(id: id1, origin: .recommended, title: "strong",
                                 queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                 generatedAt: now, relevanceScore: 1.0)
        let weakFrequent = AIWorkspace(id: id2, origin: .recommended, title: "weak",
                                       queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                       generatedAt: now, lastOpenedAt: now, openCount: 20, relevanceScore: 0.0)
        let ranked = AIWorkspaceCollection([strong, weakFrequent]).ranked(now: now)
        #expect(ranked.first?.title == "weak")
    }

    @Test func dismissOnlyAffectsRecommended() {
        let rec = ws("r", .recommended)
        let sys = ws("s", .system)
        let c = AIWorkspaceCollection([rec, sys])
        let afterRec = c.dismissing(rec.id)
        #expect(afterRec.workspace(rec.id)?.visibility == .dismissed)
        #expect(afterRec.workspace(rec.id)?.negativeFeedbackCount == 1)
        // 系统工作区 dismiss 无效(应走 hide)。
        #expect(c.dismissing(sys.id).workspace(sys.id)?.visibility == .visible)
    }

    @Test func removeOnlyUserWorkspaces() {
        let user = ws("u", .userCreated)
        let sys = ws("s", .system)
        let c = AIWorkspaceCollection([user, sys])
        #expect(c.removingUserWorkspace(user.id).workspace(user.id) == nil)
        #expect(c.removingUserWorkspace(sys.id).workspace(sys.id) != nil)   // 系统不删
    }

    @Test func pinHideRenameMarkOpened() {
        let w = ws("w", .userCreated, title: "Old")
        var c = AIWorkspaceCollection([w])
        c = c.pinning(w.id, true).hiding(w.id).renaming(w.id, to: "  New  ")
            .markingOpened(w.id, at: Date(timeIntervalSince1970: 42))
        let got = c.workspace(w.id)
        #expect(got?.pinned == true)
        #expect(got?.visibility == .hidden)
        #expect(got?.title == "New")                                       // trim
        #expect(got?.lastOpenedAt == Date(timeIntervalSince1970: 42))
        // 空白重命名被忽略。
        #expect(c.renaming(w.id, to: "   ").workspace(w.id)?.title == "New")
    }

    @Test func replacingRecommendedDropsStaleNonPinned() {
        // 用户痛点修复:刷新整体替换推荐 → 陈旧非固定推荐不再累积成「一堆幽灵」。
        let user = ws("u", .userCreated)
        let pinnedRec = ws("p", .recommended, pinned: true)
        let staleRec = ws("s", .recommended)        // 非固定、本轮不再出现 → 应丢
        let fresh = ws("f", .recommended)            // 本轮新推荐
        let next = AIWorkspaceCollection([user, pinnedRec, staleRec]).replacingRecommended([fresh])
        let ids = Set(next.workspaces.map(\.id))
        #expect(ids.contains(user.id))               // 用户工作区保留
        #expect(ids.contains(pinnedRec.id))          // 固定推荐保留(即使本轮没出现)
        #expect(!ids.contains(staleRec.id))          // 陈旧非固定 → 丢
        #expect(ids.contains(fresh.id))              // 新推荐加入
    }

    @Test func replacingRecommendedMergesPinAndOpenCount() {
        let existing = AIWorkspace(id: id1, origin: .recommended, title: "old",
                                   queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                   pinned: true, generatedAt: Date(timeIntervalSince1970: 0),
                                   lastOpenedAt: Date(timeIntervalSince1970: 5), openCount: 7)
        let fresh = AIWorkspace(id: id1, origin: .recommended, title: "new",
                                queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: "x",
                                generatedAt: Date(timeIntervalSince1970: 10))
        let got = AIWorkspaceCollection([existing]).replacingRecommended([fresh]).workspace(id1)
        #expect(got?.pinned == true)                 // 合并旧 pin
        #expect(got?.openCount == 7)                 // 合并旧频率
        #expect(got?.title == "new")                 // 用新标题
    }

    @Test func upsertReplacesByID() {
        let w = ws("w", .userCreated, title: "A")
        let c = AIWorkspaceCollection([w]).upserting(ws("w", .userCreated, title: "B"))
        #expect(c.workspaces.count == 1)
        #expect(c.workspace(w.id)?.title == "B")
    }
}
