//
//  AIWorkspaceView.swift
//  SimpleZip
//
//  0.4.5 #80 #89:AI 工作区主内容区(白皮书建议四「不伪造成真实 FileItem」)。
//
//  渲染一个工作区的**虚拟文件夹树**(`AIVirtualNode`)—— read-only 虚拟结果集,**不复用 FileTable、不伪造
//  FileItem**;行动作只打开 / 定位 / 解释,绝不改文件。替换被打回的 `AISuggestionFolderView`(那是失败任务 /
//  最近归档的扁平列表 = 活动中心换皮,不是 AI 工作区)。
//
//  虚拟树由 `AIWorkspaceStore` 提供(确定性 builder + 可选模型整理,后续接入);当前工作区还没有树时显示
//  空状态。系统级「失败任务 / 最近归档」这类纯活动中心镜像已删除,不再作为 AI 工作区。
//

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
                missingWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for workspace: AIWorkspace) -> some View {
        let tree = store.virtualTree(for: workspaceID)
        VStack(alignment: .leading, spacing: 0) {
            header(workspace)
            Divider()
            if let tree, !tree.isEmpty {
                List {
                    ForEach(tree.nodes) { node in
                        AIVirtualNodeRow(model: model, node: node, depth: 0)
                    }
                }
                .listStyle(.inset)
            } else {
                emptyState
            }
        }
    }

    private func header(_ workspace: AIWorkspace) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay(
                    Image(systemName: workspace.iconSystemName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.title).font(.headline).lineLimit(1)
                if let prompt = workspace.prompt, !prompt.isEmpty {
                    Text(prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.openAIWorkspace(workspaceID)   // 刷新 = 重开(虚拟树确定性重生成)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("sidebar.ai.refreshWorkspace"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
            Text(L10n.text("aiFolder.noSuggestions"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingWorkspace: some View {
        VStack { Text(L10n.text("aiFolder.noSuggestions")).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 虚拟树单行(read-only)。指针类节点显示标题 + 理由 + 主动作图标按钮;group 递归展开。
/// 安全:任何写文件动作只打开现有确认 / 任务流程,绝不在此直接执行(节点已过 `AIVirtualTreeSanitizer`)。
private struct AIVirtualNodeRow: View {
    @ObservedObject var model: ArchiveBrowserModel
    let node: AIVirtualNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: node.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).lineLimit(1).truncationMode(.middle)
                    if let subtitle = node.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(depth) * 16)
            ForEach(node.children) { child in
                AIVirtualNodeRow(model: model, node: child, depth: depth + 1)
            }
        }
    }
}

private extension AIVirtualNode.Kind {
    /// 节点类型的 SF Symbol(虚拟树展示用)。
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
}
