//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四)。**可折叠的多层虚拟文件夹树** —— read-only 虚拟结果集,
//  不复用 FileTable、不伪造 FileItem。
//
//  组成(用户点名):
//   ① 顶部**主题头**:渐变图标 + 主题名 + **可编辑的文件夹描述**(后台空闲时端上模型可进一步润色,模型只写描述)。
//   ② 内容是原生 `List`(选中有焦点高亮、键盘上下可选、展开有动画)—— 找回「灵魂」。
//   ③ 文件夹动态加入 AI 觉得可能需要的成员,**打 AI 角标**;右键可「我很喜欢 / 我不喜欢」(不喜欢即移出 + 不再加入)。
//   ④ 分组可折叠(▸/▾)/ 双击进入更深视图(走模型导航:返回/前进/上一级 + 地址栏面包屑)。
//   ⑤ 文件可展开调出 AI 建议(AI 文件夹 × AI Suggestion 联动)。动作只回现有流程,写盘 / 启动任务回原生确认流。
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

    /// 内联展开的节点(分组展开子级 / 文件展开 AI 建议)。下钻进分组走模型导航(返回/前进/上一级/地址栏)。
    @State private var expanded: Set<UUID> = []
    /// List 选中行(键盘上下 + 焦点高亮 = 原生 List 提供)。
    @State private var selection: String?
    /// 可编辑描述的草稿(聚焦失焦 / 回车提交回 store)。
    @State private var descriptionDraft: String = ""
    @FocusState private var descriptionFocused: Bool

    // MARK: - 扁平行模型(让原生 List 接管焦点 / 键盘 / 选中)

    private enum RowKind {
        case node(AIVirtualNode)
        case suggestion(parent: AIVirtualNode, action: AIWorkspaceNodeAction)
    }
    private struct FlatRow: Identifiable {
        let id: String
        let depth: Int
        let kind: RowKind
    }

    var body: some View {
        Group {
            if let ws = store.workspace(workspaceID), let tree = store.virtualTree(for: workspaceID), !tree.isEmpty {
                let levelNodes = model.aiWorkspacePath.last?.children ?? tree.nodes
                VStack(spacing: 0) {
                    header(ws, generationMode: tree.generationMode)
                    Divider()
                    if levelNodes.isEmpty {
                        emptyState(L10n.text("aiFolder.noSuggestions"))
                    } else {
                        outline(rows: flatten(levelNodes))
                    }
                }
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadDescriptionDraft() }
        .onChange(of: workspaceID) { _ in
            expanded = []; selection = nil; loadDescriptionDraft()
        }
    }

    // MARK: - 主题头(图标 + 主题名 + 可编辑描述)

    private func header(_ ws: AIWorkspace, generationMode: AIVirtualTreeGenerationMode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay(Image(systemName: ws.iconSystemName)
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 42, height: 42)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ws.title).font(.title3.weight(.semibold)).lineLimit(1)
                    // 整理方式如实标注(确定性整理 ≠ 模型生成,白皮书硬要求)。
                    if generationMode == .deterministic {
                        Text(L10n.text("aiWorkspace.mode.deterministic"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                TextField(descriptionPlaceholder(ws), text: $descriptionDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)
                    .focused($descriptionFocused)
                    .onSubmit { commitDescription() }
                    .onChange(of: descriptionFocused) { focused in if !focused { commitDescription() } }
            }
            Spacer(minLength: 8)
            Button { model.openAIWorkspace(workspaceID) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L10n.text("sidebar.ai.refreshWorkspace"))
            if ws.origin == .recommended {
                Button { store.dismissRecommended(workspaceID) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help(L10n.text("sidebar.ai.dismissRecommended"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom))
    }

    /// 描述为空时的占位:确定性主题种子(后台空闲时模型可把它落成真正的 userDescription)。
    private func descriptionPlaceholder(_ ws: AIWorkspace) -> String {
        let tokens = ws.queryPlan.keywords.filter { !$0.isEmpty }.prefix(5)
        guard !tokens.isEmpty else { return L10n.text("aiWorkspace.description.placeholder") }
        return L10n.text("aiWorkspace.description.seed") + tokens.joined(separator: " · ")
    }

    private func loadDescriptionDraft() { descriptionDraft = store.workspace(workspaceID)?.userDescription ?? "" }
    private func commitDescription() { store.setDescription(workspaceID, descriptionDraft) }

    // MARK: - 内容 List(焦点 / 键盘 / 选中 = 原生)

    private func outline(rows: [FlatRow]) -> some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                rowView(row).tag(row.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rowView(_ row: FlatRow) -> some View {
        switch row.kind {
        case .node(let node): nodeRow(node, depth: row.depth)
        case .suggestion(let parent, let action): suggestionRow(parent: parent, action: action, depth: row.depth)
        }
    }

    private func nodeRow(_ node: AIVirtualNode, depth: Int) -> some View {
        let suggestions = AIWorkspaceNodeActions.suggestions(for: node)
        let isExpandable = node.kind == .group ? !node.children.isEmpty : !suggestions.isEmpty
        let isOpen = expanded.contains(node.id)
        let isSuggested = !node.sourceRefs.isEmpty
            && store.nodeIsAISuggested(workspaceID: workspaceID, refs: node.sourceRefs)
        return HStack(spacing: 8) {
            if isExpandable {
                Button { toggle(node.id) } label: {
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
            if isSuggested {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                    .help(L10n.text("aiWorkspace.node.aiSuggested"))
            }
            if node.kind == .group {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(node) }
        .contextMenu { nodeMenu(node, suggestions: suggestions, isSuggested: isSuggested) }
    }

    private func suggestionRow(parent: AIVirtualNode, action s: AIWorkspaceNodeAction, depth: Int) -> some View {
        Button { dispatch(s.action) } label: {
            HStack(spacing: 8) {
                Image(systemName: s.systemImage).font(.caption).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(L10n.text(s.titleKey)).font(.caption)
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(depth) * 16 + 22)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nodeMenu(_ node: AIVirtualNode, suggestions: [AIWorkspaceNodeAction], isSuggested: Bool) -> some View {
        if node.kind == .group {
            Button(L10n.text("aiWorkspace.node.open")) { model.drillIntoAIWorkspaceGroup(node) }
            Button(L10n.text(expanded.contains(node.id) ? "aiWorkspace.node.collapse" : "aiWorkspace.node.expand")) {
                toggle(node.id)
            }
        } else {
            if let primary = node.primaryAction {
                Button(L10n.text("aiWorkspace.node.open")) { dispatch(primary) }
            }
            ForEach(suggestions) { s in Button(L10n.text(s.titleKey)) { dispatch(s.action) } }
            // 节点级训练:我很喜欢(确认保留)/ 我不喜欢(移出 + 不再加入)。只对带 ref 的成员开放。
            if !node.sourceRefs.isEmpty {
                Divider()
                if isSuggested {
                    Button(L10n.text("aiWorkspace.node.like")) {
                        store.likeNode(workspaceID: workspaceID, refs: node.sourceRefs)
                    }
                }
                Button(L10n.text("aiWorkspace.node.dislike"), role: .destructive) {
                    store.dislikeNode(workspaceID: workspaceID, refs: node.sourceRefs)
                }
            }
        }
    }

    // MARK: - 扁平化(尊重 expanded;文件展开 → AI 建议行)

    private func flatten(_ nodes: [AIVirtualNode]) -> [FlatRow] {
        var rows: [FlatRow] = []
        func walk(_ ns: [AIVirtualNode], depth: Int) {
            for node in ns {
                rows.append(FlatRow(id: "n-\(node.id)", depth: depth, kind: .node(node)))
                guard expanded.contains(node.id) else { continue }
                if node.kind == .group {
                    walk(node.children, depth: depth + 1)
                } else {
                    for s in AIWorkspaceNodeActions.suggestions(for: node) {
                        rows.append(FlatRow(id: "s-\(node.id)-\(s.id)", depth: depth + 1,
                                            kind: .suggestion(parent: node, action: s)))
                    }
                }
            }
        }
        walk(nodes, depth: 0)
        return rows
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func activate(_ node: AIVirtualNode) {
        if node.kind == .group { model.drillIntoAIWorkspaceGroup(node) }
        else if let primary = node.primaryAction { dispatch(primary) }
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
