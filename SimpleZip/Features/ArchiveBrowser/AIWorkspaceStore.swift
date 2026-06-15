//
//  AIWorkspaceStore.swift
//  SimpleZip
//
//  0.4.5 #80 #89:动态 AI 工作区的 App 层 store(白皮书建议四「AIWorkspaceStore.visibleWorkspaces」)。
//
//  侧边栏 AI section 渲染 `visibleWorkspaces`(系统 / 用户创建 / 推荐三类),不再是写死的
//  `AISystemWorkspaceKind.allCases`。纯值逻辑(可见性过滤 / dismiss / pin / hide / rename)在 Core 的
//  `AIWorkspaceCollection`(已单测);这里只负责 `@Published` 状态、UserDefaults 持久化、系统工作区播种,
//  以及把 App 层时间(`Date()`)喂进 Core 变换。
//
//  系统工作区每次启动确定性重新播种(稳定 UUID = `deterministicUUID("system-workspace:"+kind)`),只保留用户
//  对它们的可见性 / 固定覆盖;用户创建 / 推荐工作区随集合持久化。
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AIWorkspaceStore: ObservableObject {
    static let shared = AIWorkspaceStore()

    @Published private(set) var collection: AIWorkspaceCollection

    private let defaults: UserDefaults
    private static let storageKey = "SimpleZip.ai.workspaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.collection = AIWorkspaceStore.load(from: defaults)
        seedSystemWorkspaces()
    }

    /// 侧边栏渲染的可见工作区(确定性排序,排除 hidden / dismissed)。
    var visibleWorkspaces: [AIWorkspace] { collection.visibleWorkspaces }

    func workspace(_ id: UUID) -> AIWorkspace? { collection.workspace(id) }

    /// 把系统工作区的 UUID 解析回 `AISystemWorkspaceKind`(供内容区用现有 `AISuggestionFolderView` 渲染)。
    func systemKind(for id: UUID) -> AISystemWorkspaceKind? {
        guard collection.workspace(id)?.origin == .system else { return nil }
        return AISystemWorkspaceKind.allCases.first { Self.systemID($0) == id }
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

    func dismissRecommended(_ id: UUID) { apply { $0.dismissing(id) } }
    func setPinned(_ id: UUID, _ pinned: Bool) { apply { $0.pinning(id, pinned) } }
    func hide(_ id: UUID) { apply { $0.hiding(id) } }
    func removeUserWorkspace(_ id: UUID) { apply { $0.removingUserWorkspace(id) } }
    func rename(_ id: UUID, to title: String) { apply { $0.renaming(id, to: title) } }
    func markOpened(_ id: UUID) { apply { $0.markingOpened(id, at: Date()) } }

    private func apply(_ transform: (AIWorkspaceCollection) -> AIWorkspaceCollection) {
        let next = transform(collection)
        guard next != collection else { return }   // 不变则不刷新(避免无谓 publish)
        collection = next
        persist()
    }

    // MARK: - 系统工作区播种

    private func seedSystemWorkspaces() {
        var next = collection
        for kind in AISystemWorkspaceKind.allCases {
            let id = Self.systemID(kind)
            if let existing = next.workspace(id) {
                // 保留可见性 / 固定覆盖,刷新标题(语言可能变了)。
                var refreshed = existing
                refreshed.title = Self.systemTitle(kind)
                next = next.upserting(refreshed)
            } else {
                next = next.upserting(AIWorkspace(
                    id: id, origin: .system, title: Self.systemTitle(kind),
                    queryPlan: AIWorkspaceQueryPlan(taskTags: []), iconSystemName: kind.systemImage,
                    generatedAt: Date()))
            }
        }
        if next != collection { collection = next; persist() }
    }

    static func systemID(_ kind: AISystemWorkspaceKind) -> UUID {
        AIStableHash.deterministicUUID("system-workspace:" + kind.rawValue)
    }

    private static func systemTitle(_ kind: AISystemWorkspaceKind) -> String {
        switch kind {
        case .needsAttention: return L10n.text("aiFolder.needsAttention")
        case .releaseAndVerify: return L10n.text("aiFolder.releaseAndVerify")
        case .recentArchives: return L10n.text("aiFolder.recentArchives")
        }
    }

    // MARK: - 持久化(UserDefaults JSON)

    private func persist() {
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> AIWorkspaceCollection {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AIWorkspaceCollection.self, from: data)
        else { return AIWorkspaceCollection() }
        return decoded
    }
}
