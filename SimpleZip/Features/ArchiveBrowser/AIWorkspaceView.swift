//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四「不伪造成真实 FileItem」)。
//
//  渲染一个工作区的**虚拟文件夹树**(`AIVirtualNode`)—— read-only 虚拟结果集,**不复用 FileTable、不伪造
//  FileItem**;行动作只打开 / 定位 / 解释,绝不改文件(节点已过 `AIVirtualTreeSanitizer`)。虚拟树由
//  `AIWorkspaceStore` 经 plan/builder 从后台发现的候选池建出;还没有树时显示空状态。
//
//  视觉:渐变 hero 头(图标瓦片 + 标题 + 主题副标题 + 刷新 / 不感兴趣)+ 分组卡片(角色配色瓦片)。
//

import AppKit
import SwiftUI

struct AIWorkspaceView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let workspaceID: UUID
    @ObservedObject private var store = AIWorkspaceStore.shared

    var body: some View {
        Group {
            if let workspace = store.workspace(workspaceID) {
                content(for: workspace)
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for workspace: AIWorkspace) -> some View {
        let tree = store.virtualTree(for: workspaceID)
        VStack(alignment: .leading, spacing: 0) {
            hero(workspace)
            Divider()
            if let tree, !tree.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(tree.nodes) { node in
                            AIVirtualNodeCard(node: node, depth: 0, onAction: dispatch)
                        }
                    }
                    .padding(16)
                }
            } else {
                emptyState(L10n.text("aiFolder.noSuggestions"))
            }
        }
    }

    // MARK: - Hero 头

    private func hero(_ workspace: AIWorkspace) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay(
                    Image(systemName: workspace.iconSystemName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white))
                .frame(width: 40, height: 40)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title).font(.title3.weight(.semibold)).lineLimit(1)
                if let subtitle = subtitle(for: workspace) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.openAIWorkspace(workspaceID)   // 刷新 = 重开(虚拟树重生成)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("sidebar.ai.refreshWorkspace"))
            if workspace.origin == .recommended {
                Button {
                    store.dismissRecommended(workspaceID)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("sidebar.ai.dismissRecommended"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom))
    }

    /// 副标题:用户 prompt 优先,否则主题 token。
    private func subtitle(for workspace: AIWorkspace) -> String? {
        if let prompt = workspace.prompt, !prompt.isEmpty { return prompt }
        let tokens = workspace.queryPlan.keywords.filter { !$0.isEmpty }
        return tokens.isEmpty ? nil : tokens.prefix(5).joined(separator: " · ")
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.accentColor.opacity(0.6))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 节点动作 → 现有 App 流程(只读 / 导航)

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
        case .revealSourceRefsInFinder, .applySelection, .openWithApplication, .applyArchiveSearch:
            break
        default:
            break   // 写盘 / 启动任务类:回原生确认流(接动作候选时扩),不在虚拟树里直接执行
        }
    }
}

/// 一个虚拟节点的卡片渲染。group → 分组卡(标题 + 递归子节点);指针节点 → 可点行(角色配色瓦片 + 主动作)。
private struct AIVirtualNodeCard: View {
    let node: AIVirtualNode
    let depth: Int
    let onAction: (AISuggestionAction) -> Void

    var body: some View {
        if node.kind == .group {
            VStack(alignment: .leading, spacing: 6) {
                Text(node.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children) { child in
                        AIVirtualNodeCard(node: child, depth: depth + 1, onAction: onAction)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.12)))
            }
        } else {
            leafRow
        }
    }

    private var leafRow: some View {
        let row = HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(node.kind.tint.gradient)
                .overlay(
                    Image(systemName: node.kind.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let reason = node.reason ?? node.subtitle, !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if node.primaryAction != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())

        return Group {
            if let action = node.primaryAction {
                Button { onAction(action) } label: { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
    }
}

private extension AIVirtualNode.Kind {
    /// 节点类型的 SF Symbol。
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

    /// 角色配色(瓦片底)。同类同色,呼应设计准则。
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
