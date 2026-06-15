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
                        AIVirtualNodeRow(node: node, depth: 0) { dispatch($0) }
                    }
                }
                .listStyle(.inset)
            } else {
                emptyState
            }
        }
    }

    /// 节点主动作 → 现有 App 流程(只读 / 导航)。当前虚拟树只产出这些安全动作;写盘 / 启动任务类动作
    /// (接动作候选后)必须回原生确认流,不在此直接执行。
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
            break   // 需路径 / 选择上下文,后续接动作候选时补
        default:
            break   // 写盘 / 启动任务类:回原生确认流(接动作候选时扩),不在虚拟树里直接执行
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

/// 虚拟树单行(read-only)。指针类节点带主动作 → 点击执行(只打开 / 定位,绝不写盘);group 递归展开。
/// 安全:写文件动作只回原生确认 / 任务流程,绝不在此直接执行(节点已过 `AIVirtualTreeSanitizer`)。
private struct AIVirtualNodeRow: View {
    let node: AIVirtualNode
    let depth: Int
    let onAction: (AISuggestionAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let action = node.primaryAction {
                Button { onAction(action) } label: { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
            ForEach(node.children) { child in
                AIVirtualNodeRow(node: child, depth: depth + 1, onAction: onAction)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.symbolName)
                .foregroundStyle(node.kind == .group ? .primary : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(node.kind == .group ? .callout.weight(.semibold) : .callout)
                    .lineLimit(1).truncationMode(.middle)
                if let reason = node.reason ?? node.subtitle, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if node.primaryAction != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(depth) * 16)
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
