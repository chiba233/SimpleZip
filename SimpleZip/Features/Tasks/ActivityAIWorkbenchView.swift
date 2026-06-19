//
//  ActivityAIWorkbenchView.swift
//  SimpleZip
//
//  0.4.5 #80: deterministic Activity Center AI workbench.
//  This is a read-only analysis pane: it can apply existing filters or locate
//  tasks, but never runs, retries, deletes, moves or edits anything.
//

import SwiftUI

struct ActivityAIWorkbenchView: View {
    let snapshot: ActivityAIWorkbenchSnapshot
    /// 自然语言筛选输入(从工具栏挪进侧栏)。回车 / 点按 → `onRunQuery`,由父级走 AI 抽条件并应用。
    @Binding var searchText: String
    let isRunningQuery: Bool
    let queryError: String?
    /// 当前生效的 AI 筛选摘要(nil = 没有生效);非 nil 时显示一行可一键清除的指示。
    let activeFilterSummary: String?
    /// 建议六 v2:端上模型对「需要处理」卡写的一段解读(现在最值得先处理什么 + 为什么)。nil = 模型不可用 / 没失败 /
    /// 还没生成 → 卡片退回确定性计数文案。
    let aiExplanation: String?
    let onRunQuery: () -> Void
    let onClearFilter: () -> Void
    let onApplyFilter: (ActivityAIWorkbenchFilterChip) -> Void
    let onOpenTask: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                searchSection
                currentSummary
                needsAttention
                suggestedFilters
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// NL 搜索区(原工具栏 AI 筛选按钮的功能,挪到侧栏):输入一句话 → AI 抽条件;生效时一行指示 + 一键清除。
    private var searchSection: some View {
        workbenchSection(title: L10n.text("tasks.aiFilter.title"), systemImage: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(L10n.text("tasks.aiFilter.prompt"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onRunQuery)
                    if isRunningQuery {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: onRunQuery) {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(L10n.text("tasks.aiFilter.apply"))
                    }
                }
                if let queryError {
                    Label(queryError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let activeFilterSummary {
                    HStack(spacing: 6) {
                        Label(activeFilterSummary, systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button(action: onClearFilter) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("tasks.aiFilter.clear"))
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("tasks.aiWorkbench.title"))
                    .font(.headline)
                Text(L10n.text("tasks.aiWorkbench.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("tasks.aiWorkbench.close"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var currentSummary: some View {
        workbenchSection(title: L10n.text("tasks.aiWorkbench.currentList"), systemImage: "chart.bar") {
            Text(L10n.format(
                "tasks.aiWorkbench.summary",
                "\(snapshot.summary.total)",
                "\(snapshot.summary.running)",
                "\(snapshot.summary.failedUnseen + snapshot.summary.failedSeen)"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var needsAttention: some View {
        if let card = snapshot.cards.first(where: { $0.kind == .needsAttention }) {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.needsAttention"), systemImage: "exclamationmark.triangle") {
                // 建议六 v2:有模型解读就显示它(✨ 标识),否则退回确定性计数文案(始终是 fallback)。
                if let aiExplanation, !aiExplanation.isEmpty {
                    Label(aiExplanation, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let count = factValue("failedUnseen", in: card.facts) ?? card.sourceRefs.count
                    Text(L10n.format("tasks.aiWorkbench.needsAttention.body", "\(count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let first = card.sourceRefs.first {
                    Button {
                        onOpenTask(first.id)
                    } label: {
                        Label(L10n.text("tasks.aiWorkbench.openFirst"), systemImage: "arrow.forward.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var suggestedFilters: some View {
        workbenchSection(title: L10n.text("tasks.aiWorkbench.suggestedFilters"), systemImage: "line.3.horizontal.decrease.circle") {
            if snapshot.filterChips.isEmpty {
                Text(L10n.text("tasks.aiWorkbench.noFilters"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.filterChips) { chip in
                        Button {
                            onApplyFilter(chip)
                        } label: {
                            HStack(spacing: 8) {
                                Text(chipTitle(chip.id))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let matches = factValue("matches", in: chip.facts) {
                                    Text("\(matches)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func workbenchSection<Content: View>(title: String, systemImage: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipTitle(_ id: String) -> String {
        L10n.text("tasks.aiWorkbench.chip.\(id)")
    }

    private func factValue(_ key: String, in facts: [String]) -> Int? {
        let prefix = "\(key)="
        guard let raw = facts.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else { return nil }
        return Int(raw)
    }
}
