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
//  硬边界(白皮书验收标准):① 关 AI 模型也能显示(候选纯确定性,不依赖模型);② 不复用 FileTable、不伪造
//  `FileItem`;③ 动作只允许「打开 / 定位」(任务→活动中心定位,归档→打开浏览),**绝不删 / 移 / 覆盖 / 解压 /
//  改权限**;④ AI 主开关关闭时整体不展示。用普通 SwiftUI `List` 表达,不碰归档浏览管线。
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

    /// 一个只读节点的视图模型。`action` 只做打开 / 定位,绝不写。
    private struct Node: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let tint: Color
        let actionLabel: String
        let action: () -> Void
    }

    private var nodes: [Node] {
        let tasks = allRecentTasks
        let tasksByID = Dictionary(tasks.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let archivesByPath = Dictionary(cachedArchives.map { ($0.archivePath, $0) }, uniquingKeysWith: { first, _ in first })
        return factsSnapshot.nodes.compactMap { fact in
            switch fact.kind {
            case .task:
                guard let task = tasksByID[fact.sourceRef.id] else { return nil }
                return Node(id: fact.id, title: fact.title,
                            subtitle: task.startedAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: taskSystemImage, tint: taskTint,
                            actionLabel: L10n.text("aiFolder.openInActivity"),
                            action: { ActivityWindowController.shared.show(category: task.category, locateTaskID: task.id) })
            case .archive:
                guard let entry = archivesByPath[fact.sourceRef.id] else { return nil }
                let url = URL(fileURLWithPath: entry.archivePath)
                return Node(id: fact.id, title: fact.title,
                            subtitle: L10n.format("aiFolder.archiveEntryCount", entry.totalEntryCount),
                            systemImage: "doc.zipper", tint: .blue,
                            actionLabel: L10n.text("aiFolder.openArchive"),
                            action: { if FileManager.default.fileExists(atPath: url.path) { model.openArchive(url) } })
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !aiEnabled || nodes.isEmpty {
                emptyState
            } else {
                List(nodes) { node in
                    row(node)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: loadCachedArchivesIfNeeded)
    }

    // MARK: - 候选派生(确定性,只读)

    private var factsSnapshot: AISystemWorkspaceFactsSnapshot {
        AISystemWorkspaceFactsBuilder.snapshot(
            kind: kind,
            tasks: allRecentTasks.map(\.aiWorkspaceFact),
            archives: cachedArchives.map(\.aiWorkspaceFact))
    }

    private var allRecentTasks: [OperationTask] {
        taskCenter.active + taskCenter.history
    }

    private var taskSystemImage: String {
        kind == .needsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var taskTint: Color {
        kind == .needsAttention ? .orange : .green
    }

    private func loadCachedArchivesIfNeeded() {
        guard kind == .recentArchives else { return }
        Task { @MainActor in
            let entries = await Task.detached(priority: .utility) { ArchiveListingCacheStore().loadAll() }.value
            cachedArchives = entries
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

    private func row(_ node: Node) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.systemImage).foregroundStyle(node.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(node.actionLabel, action: node.action)
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

extension OperationTask {
    var aiWorkspaceFact: AISystemWorkspaceTaskFact {
        AISystemWorkspaceTaskFact(
            id: id.uuidString,
            category: category.rawValue,
            kind: kind.rawValue,
            source: source.rawValue,
            title: title,
            status: aiWorkspaceStatus,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }

    var aiWorkspaceStatus: AISystemWorkspaceTaskFact.Status {
        switch status {
        case .running:
            return .running
        case .succeeded:
            return .succeeded
        case .skipped:
            return .skipped
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }
}

extension ArchiveListingCacheEntry {
    nonisolated var aiWorkspaceFact: AISystemWorkspaceArchiveFact {
        AISystemWorkspaceArchiveFact(
            archivePath: archivePath,
            archiveName: archiveName,
            recordedAt: recordedAt,
            totalEntryCount: totalEntryCount,
            fileEntryCount: fileEntryCount,
            encryptedEntryCount: encryptedEntryCount,
            truncated: truncated)
    }
}
