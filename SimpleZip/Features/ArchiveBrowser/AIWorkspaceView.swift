//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四)。**可折叠的多层虚拟文件夹树** —— read-only 虚拟结果集,
//  不复用 FileTable、不伪造 FileItem。
//
//  交互(用户点名):① 分组可折叠(▸/▾)② 双击虚拟文件夹**进入更深视图**(面包屑导航)③ 每个节点可**右键**
//  ④ 文件可**展开调出 AI 建议**(AI 文件夹 × AI Suggestion 联动:文件视角 + 动作视角)。动作只回现有流程,
//  写盘 / 启动任务回原生确认流。
//

import AppKit
import SwiftUI

/// 一个文件 / 归档 / 文件夹节点的派生 AI 建议(确定性;模型增强后续接)。
struct AIWorkspaceNodeAction: Identifiable {
    let titleKey: String
    let systemImage: String
    let action: AISuggestionAction
    var id: String { titleKey }
}

enum AIWorkspaceNodeActions {
    static func suggestions(for node: AIVirtualNode) -> [AIWorkspaceNodeAction] {
        guard let path = resolvedPath(node) else { return [] }
        switch node.kind {
        case .file:
            return [AIWorkspaceNodeAction(titleKey: "aiWorkspace.node.reveal", systemImage: "magnifyingglass",
                                          action: .revealFile(path: path)),
                    AIWorkspaceNodeAction(titleKey: "aiWorkspace.node.hash", systemImage: "number",
                                          action: .calculateHash(paths: [path], algorithms: ["sha256"]))]
        case .archive:
            return [AIWorkspaceNodeAction(titleKey: "aiWorkspace.node.openArchive", systemImage: "doc.zipper",
                                          action: .openArchive(path: path, revealEntry: nil)),
                    AIWorkspaceNodeAction(titleKey: "aiWorkspace.node.test", systemImage: "checkmark.seal",
                                          action: .testArchive(path: path))]
        case .folder:
            return [AIWorkspaceNodeAction(titleKey: "aiWorkspace.node.openFolder", systemImage: "folder",
                                          action: .openFolder(path: path))]
        default:
            return []
        }
    }

    static func resolvedPath(_ node: AIVirtualNode) -> String? {
        switch node.primaryAction {
        case .revealFile(let p), .openFolder(let p): return p
        case .openArchive(let p, _): return p
        default: return nil
        }
    }
}

struct AIWorkspaceView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let workspaceID: UUID
    @ObservedObject private var store = AIWorkspaceStore.shared

    /// 「双击进入」的下钻链(面包屑);空 = 根。
    @State private var drillStack: [AIVirtualNode] = []
    /// 内联展开的节点(分组展开子级 / 文件展开 AI 建议)。
    @State private var expanded: Set<UUID> = []

    var body: some View {
        Group {
            if let workspace = store.workspace(workspaceID) {
                content(for: workspace)
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: workspaceID) { _ in drillStack = []; expanded = [] }
    }

    @ViewBuilder
    private func content(for workspace: AIWorkspace) -> some View {
        let tree = store.virtualTree(for: workspaceID)
        VStack(alignment: .leading, spacing: 0) {
            hero(workspace)
            Divider()
            if let tree, !tree.isEmpty {
                if !drillStack.isEmpty { breadcrumb(workspace); Divider() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(displayedNodes(of: tree)) { node in
                            AIVirtualNodeRowView(node: node, depth: 0, expanded: $expanded,
                                                 onDrill: drillInto, onDispatch: dispatch)
                        }
                    }
                    .padding(14)
                }
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
    }

    private func displayedNodes(of tree: AIVirtualFolderTree) -> [AIVirtualNode] {
        drillStack.last?.children ?? tree.nodes
    }

    // MARK: - Hero 头 + 面包屑

    private func hero(_ workspace: AIWorkspace) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay(Image(systemName: workspace.iconSystemName)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 40, height: 40)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title).font(.title3.weight(.semibold)).lineLimit(1)
                if let subtitle = subtitle(for: workspace) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { model.openAIWorkspace(workspaceID) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L10n.text("sidebar.ai.refreshWorkspace"))
            if workspace.origin == .recommended {
                Button { store.dismissRecommended(workspaceID) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help(L10n.text("sidebar.ai.dismissRecommended"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private func breadcrumb(_ workspace: AIWorkspace) -> some View {
        HStack(spacing: 4) {
            crumb(workspace.title) { drillStack = [] }
            ForEach(Array(drillStack.enumerated()), id: \.element.id) { idx, node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb(node.title) { drillStack = Array(drillStack.prefix(idx + 1)) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func crumb(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption).lineLimit(1) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
    }

    private func drillInto(_ node: AIVirtualNode) {
        if node.kind == .group, !node.children.isEmpty { drillStack.append(node) }
    }

    private func subtitle(for workspace: AIWorkspace) -> String? {
        if let prompt = workspace.prompt, !prompt.isEmpty { return prompt }
        let tokens = workspace.queryPlan.keywords.filter { !$0.isEmpty }
        return tokens.isEmpty ? nil : tokens.prefix(5).joined(separator: " · ")
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Color.accentColor.opacity(0.6))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 节点动作 → 现有 App 流程(只读 / 导航 / 启动现有任务流程)

    private func dispatch(_ action: AISuggestionAction) {
        switch action {
        case .openTask(let id), .openReport(taskID: let id), .explainFailure(taskID: let id):
            ActivityWindowController.shared.show(locateTaskID: id)
        case .openActivityCenter:
            ActivityWindowController.shared.show()
        case .openFolder(let path):
            model.openFolder(URL(fileURLWithPath: path))
        case .revealFile(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .openArchive(let path, let revealEntry):
            let url = URL(fileURLWithPath: path)
            if let entry = revealEntry, !entry.isEmpty { model.openArchive(url, revealEntryPath: entry) }
            else { model.openArchive(url) }
        case .calculateHash(let paths, _):
            model.calculateHash(forFinderURLs: paths.map { URL(fileURLWithPath: $0) })
        case .testArchive(let path):
            model.testArchives(at: [URL(fileURLWithPath: path)])
        case .createArchive(let paths), .createArchiveFromSuggestion(let paths, _, _):
            model.createArchive(fromFinderURLs: paths.map { URL(fileURLWithPath: $0) })
        default:
            break   // 其余(转换 / 发布检查 / evidence-ref 类)后续接 —— 写盘动作回原生确认流
        }
    }
}

/// 递归虚拟节点行(独立 struct,避免「opaque 返回类型自引用」)。group 可折叠 / 双击进入;file/archive 可
/// 展开调出 AI 建议;每个节点可右键。
private struct AIVirtualNodeRowView: View {
    let node: AIVirtualNode
    let depth: Int
    @Binding var expanded: Set<UUID>
    let onDrill: (AIVirtualNode) -> Void
    let onDispatch: (AISuggestionAction) -> Void

    var body: some View {
        let suggestions = AIWorkspaceNodeActions.suggestions(for: node)
        let isExpandable = node.kind == .group ? !node.children.isEmpty : !suggestions.isEmpty
        let isOpen = expanded.contains(node.id)
        VStack(alignment: .leading, spacing: 2) {
            rowContent(isExpandable: isExpandable, isOpen: isOpen, suggestions: suggestions)
            if isOpen {
                if node.kind == .group {
                    ForEach(node.children) { child in
                        AIVirtualNodeRowView(node: child, depth: depth + 1, expanded: $expanded,
                                             onDrill: onDrill, onDispatch: onDispatch)
                    }
                } else {
                    ForEach(suggestions) { s in suggestionRow(s) }
                }
            }
        }
    }

    private func rowContent(isExpandable: Bool, isOpen: Bool, suggestions: [AIWorkspaceNodeAction]) -> some View {
        HStack(spacing: 8) {
            if isExpandable {
                Button { toggle() } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(node.kind.tint.gradient)
                .overlay(Image(systemName: node.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let reason = node.reason ?? node.subtitle, !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if node.kind == .group { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate() }
        .contextMenu { contextMenu(suggestions: suggestions) }
    }

    private func suggestionRow(_ s: AIWorkspaceNodeAction) -> some View {
        Button { onDispatch(s.action) } label: {
            HStack(spacing: 8) {
                Image(systemName: s.systemImage).font(.caption).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(L10n.text(s.titleKey)).font(.caption)
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(depth + 1) * 16 + 22)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contextMenu(suggestions: [AIWorkspaceNodeAction]) -> some View {
        if node.kind == .group {
            Button(L10n.text("aiWorkspace.node.open")) { onDrill(node) }
            Button(L10n.text(expanded.contains(node.id) ? "aiWorkspace.node.collapse" : "aiWorkspace.node.expand")) {
                toggle()
            }
        } else {
            if let primary = node.primaryAction {
                Button(L10n.text("aiWorkspace.node.open")) { onDispatch(primary) }
            }
            ForEach(suggestions) { s in
                Button(L10n.text(s.titleKey)) { onDispatch(s.action) }
            }
        }
    }

    private func toggle() { if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) } }
    private func activate() {
        if node.kind == .group { onDrill(node) }
        else if let primary = node.primaryAction { onDispatch(primary) }
    }
}

private extension AIVirtualNode.Kind {
    var symbolName: String {
        switch self {
        case .group: return "folder"
        case .file: return "doc"
        case .folder: return "folder"
        case .archive: return "doc.zipper"
        case .archiveEntry: return "doc.text"
        case .task: return "checklist"
        case .report: return "doc.richtext"
        case .action: return "bolt"
        case .automation: return "wand.and.stars"
        case .note: return "text.bubble"
        }
    }

    var tint: Color {
        switch self {
        case .group: return .accentColor
        case .file: return .gray
        case .folder: return .blue
        case .archive: return .indigo
        case .archiveEntry: return .teal
        case .task: return .orange
        case .report: return .purple
        case .action: return .green
        case .automation: return .mint
        case .note: return .gray
        }
    }
}
