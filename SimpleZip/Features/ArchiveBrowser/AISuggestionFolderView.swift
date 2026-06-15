//
//  AISuggestionFolderView.swift
//  SimpleZip
//
//  0.4.5 #80:AI 建议虚拟工作区(只读;白皮书建议四 / 工程补充一 MVP)。主窗口内容区在 `.aiWorkspace` 模式下
//  渲染本视图(代替 FileTable)。**系统工作区**(第一版只做确定性、不做用户 prompt 创建):
//    - 需要处理:最近失败的任务;
//    - 发布与校验:最近的检查 / 测试 / 哈希 / 对比类任务;
//    - 最近的归档:最近打开、已建非加密内容索引的归档。
//
//  分工:候选的「筛选 / 排序 / 封顶 / omissions」全在确定性 Core `AISystemWorkspaceFactsBuilder`(可单测、可导出);
//  本视图只把它产出的节点**解析回真实对象**来执行只读动作(任务→活动中心定位,归档→打开浏览),并渲染。
//
//  硬边界(白皮书验收标准):① 关 AI 模型也能显示(候选纯确定性,不依赖模型);② 不复用 FileTable、不伪造
//  `FileItem`;③ 动作只允许「打开 / 定位」,**绝不删 / 移 / 覆盖 / 解压 / 改权限**;④ AI 主开关关闭时整体不展示。
//

import SwiftUI
import AppKit

struct AISuggestionFolderView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let kind: AISystemWorkspaceKind
    @ObservedObject private var taskCenter = TaskCenter.shared
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiEnabled = true
    /// `recentArchives` 的候选源(读 UserDefaults JSON,放后台,onAppear 取一次)。任务类候选走 `taskCenter` 响应式。
    @State private var cachedArchives: [ArchiveListingCacheEntry] = []

    /// 一个可渲染的行 —— 由确定性 facts 快照的节点解析而来。`action` 只做打开 / 定位,绝不写。
    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let tint: Color
        let actionLabel: String
        let action: () -> Void
    }

    var body: some View {
        let rows = resolvedRows
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !aiEnabled || rows.isEmpty {
                emptyState
            } else {
                List(rows) { row($0) }
                    .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: loadCachedArchivesIfNeeded)
    }

    // MARK: - 候选派生(确定性 builder → 解析回真实对象,只读)

    /// 把确定性快照的节点解析成可渲染行:任务回查 `taskCenter` 拿分类(定位更准),归档直接用 sourceRef 里的路径。
    /// 解析不到对应真实对象的节点直接丢弃(绝不打开一个已不存在的引用)。
    private var resolvedRows: [Row] {
        let snapshot = AISystemWorkspaceFactsBuilder.snapshot(
            kind: kind,
            tasks: (taskCenter.active + taskCenter.history).map { $0.aiWorkspaceFact },
            archives: cachedArchives.map { $0.aiWorkspaceFact })
        let tasksByID = Dictionary(
            (taskCenter.active + taskCenter.history).map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { first, _ in first })
        let entriesByPath = Dictionary(
            cachedArchives.map { ($0.archivePath, $0) },
            uniquingKeysWith: { first, _ in first })

        return snapshot.nodes.compactMap { node in
            switch node.suggestedAction {
            case .openActivityTask:
                guard let task = tasksByID[node.sourceRef.id] else { return nil }
                return Row(
                    id: node.id, title: node.title,
                    subtitle: node.occurredAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: taskSymbol, tint: taskTint,
                    actionLabel: L10n.text("aiFolder.openInActivity"),
                    action: { ActivityWindowController.shared.show(category: task.category, locateTaskID: task.id) })
            case .openArchive:
                let url = URL(fileURLWithPath: node.sourceRef.id)
                let count = entriesByPath[node.sourceRef.id]?.totalEntryCount
                return Row(
                    id: node.id, title: node.title,
                    subtitle: count.map { L10n.format("aiFolder.archiveEntryCount", $0) },
                    systemImage: "doc.zipper", tint: .blue,
                    actionLabel: L10n.text("aiFolder.openArchive"),
                    action: { if FileManager.default.fileExists(atPath: url.path) { model.openArchive(url) } })
            }
        }
    }

    /// 任务行图标 / 配色按工作区区分(失败=橙色警示,校验=绿色印章)。
    private var taskSymbol: String { kind == .needsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill" }
    private var taskTint: Color { kind == .needsAttention ? .orange : .green }

    private func loadCachedArchivesIfNeeded() {
        guard kind == .recentArchives else { return }
        Task { @MainActor in
            cachedArchives = await Task.detached(priority: .utility) { ArchiveListingCacheStore().loadAll() }.value
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.purple.gradient)
                .overlay(
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceTitle).font(.headline)
                Text(workspaceSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var workspaceTitle: String {
        switch kind {
        case .needsAttention: return L10n.text("aiFolder.needsAttention")
        case .releaseAndVerify: return L10n.text("aiFolder.releaseAndVerify")
        case .recentArchives: return L10n.text("aiFolder.recentArchives")
        }
    }

    private var workspaceSubtitle: String {
        switch kind {
        case .needsAttention: return L10n.text("aiFolder.needsAttention.subtitle")
        case .releaseAndVerify: return L10n.text("aiFolder.releaseAndVerify.subtitle")
        case .recentArchives: return L10n.text("aiFolder.recentArchives.subtitle")
        }
    }

    // MARK: - 行(只读)

    private func row(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.systemImage).foregroundStyle(row.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(row.actionLabel, action: row.action)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L10n.text("aiFolder.noSuggestions"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
