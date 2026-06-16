//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四)。
//
//  顶部是**主题头**(渐变图标 + 主题名 + 可编辑的文件夹描述,后台空闲时端上模型可进一步润色,模型只写描述);
//  下面是内容 —— 直接复用主文件浏览的 NSOutlineView(`AIVirtualNodeOutline`),所以多选 / 框选 / 方向键 /
//  空格展开 / 回车改名 / 点空白取消选中 / 拖拽移动 全部与主视图一致。渲染 `AIVirtualNode`,不伪造 FileItem。
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

    /// 可编辑描述的草稿(聚焦失焦 / 回车提交回 store)。
    @State private var descriptionDraft: String = ""
    @FocusState private var descriptionFocused: Bool

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
                        AIVirtualNodeOutline(model: model, store: store, workspaceID: workspaceID,
                                             nodes: levelNodes, onDispatch: dispatch)
                    }
                }
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadDescriptionDraft() }
        .onChange(of: workspaceID) { _ in loadDescriptionDraft() }
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
            Button { store.refreshWorkspaceTree(workspaceID) } label: { Image(systemName: "arrow.clockwise") }
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
