//
//  AISuggestionFolderView.swift
//  SimpleZip
//
//  0.4.5 #80:AI 建议虚拟工作区(只读;白皮书建议四 / 工程补充一 MVP)。主窗口内容区在 `.aiWorkspace` 模式下
//  渲染本视图(代替 FileTable)。第一版只做**确定性系统工作区**:`需要处理` = 最近失败的任务。
//
//  硬边界(白皮书验收标准):① 关 AI 模型也能显示(候选纯确定性,不依赖模型);② 不复用 FileTable、不伪造
//  `FileItem`;③ 动作只允许「在活动中心打开 / 定位」,**绝不删除 / 移动 / 覆盖 / 解压 / 改权限**;④ AI 主开关
//  关闭时整体不展示(侧栏入口已隐藏,此处再兜底)。用普通 SwiftUI `List` 表达,不碰归档浏览管线。
//

import SwiftUI
import AppKit

struct AISuggestionFolderView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let kind: AISystemWorkspaceKind
    @ObservedObject private var taskCenter = TaskCenter.shared
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiEnabled = true

    /// 当前工作区的确定性候选。`needsAttention` = 最近失败的任务(新→旧,上限 50)。
    private var candidates: [OperationTask] {
        switch kind {
        case .needsAttention:
            return (taskCenter.active + taskCenter.history)
                .filter { if case .failed = $0.status { return true } else { return false } }
                .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
                .prefix(50)
                .map { $0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // aiEnabled 兜底:gate 关闭时正常不会进本模式(侧栏入口隐藏),这里仍显示空态以防边角情况。
            if !aiEnabled || candidates.isEmpty {
                emptyState
            } else {
                List(candidates, id: \.id) { task in
                    taskRow(task)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.purple.gradient)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("aiFolder.needsAttention"))
                    .font(.headline)
                Text(L10n.text("aiFolder.needsAttention.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 行(只读)

    private func taskRow(_ task: OperationTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(task.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 唯一动作:在活动中心打开并定位该任务(只读;复用现有深链,不新增行为)。
            Button(L10n.text("aiFolder.openInActivity")) {
                ActivityWindowController.shared.show(category: task.category, locateTaskID: task.id)
            }
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
