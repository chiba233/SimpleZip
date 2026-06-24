//
//  ActivityAIWorkbenchView.swift
//  SimpleZip
//
//  0.4.5 #80: deterministic Activity Center AI workbench.
//  This is a read-only analysis pane: it can apply existing filters or locate
//  tasks, but never runs, retries, deletes, moves or edits anything.
//

import SwiftUI

/// 建议六 v2 模块②「下一步动作」:焦点失败任务上可点的安全后续动作。**App 安全枚举,AI 不发明动作**(红线)。
/// 每项映射到任务自身已有的闭包(打开报告 / 从失败步继续 / 重跑 / 改参重跑)或一个只读复制。
enum WorkbenchNextAction: String, CaseIterable, Identifiable, Equatable {
    case openReport
    case resumeFromFailure
    case rerun
    case rerunWithChanges
    case copyDiagnostics

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .openReport: return "button.openReport"
        case .resumeFromFailure: return "button.resumeFromFailure"
        case .rerun: return "button.rerunTask"
        case .rerunWithChanges: return "button.rerunWithChanges"
        case .copyDiagnostics: return "button.copyDiagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .openReport: return "doc.text.magnifyingglass"
        case .resumeFromFailure: return "arrow.uturn.forward"
        case .rerun: return "arrow.clockwise"
        case .rerunWithChanges: return "slider.horizontal.3"
        case .copyDiagnostics: return "doc.on.clipboard"
        }
    }
}

/// 建议六 v2 模块①「失败解释」的焦点数据。`deterministicSummary` 永远在(脱敏诊断文案,确定性 fallback);
/// `aiExplanation` 模型可用且生成成功时才有;`canOpenFull` 决定是否显示「打开完整 AI 解释」按钮。
/// taskTitle 只在侧栏显示(用户在卡片里本就看得到),**不喂给模型**。`nextActions` = 模块②可点的安全后续动作。
struct ActivityWorkbenchFailureFocus: Equatable {
    let taskTitle: String
    let deterministicSummary: String
    let aiExplanation: String?
    let canOpenFull: Bool
    let nextActions: [WorkbenchNextAction]
}

struct ActivityAIWorkbenchView: View {
    let snapshot: ActivityAIWorkbenchSnapshot
    /// 建议六 v2「学习到的习惯」:近期常用来源 / 格式 / 位置摘要(确定性,只摘要不含完整路径)。
    let habits: ActivityWorkbenchHabits
    /// 建议六 v2「自动化建议」:某手动操作稳定重复达阈值时的提示(nil = 没有稳定重复 → 不显示)。
    let automationHint: ActivityWorkbenchAutomationHint?
    /// 建议六 v2「AI 推荐时间维度」:今天 / 本周 / 本月三带(确定性),标出值得关注的那带。空 = 不显示该区。
    /// 与建议筛选 chip **双重叠加**(各自独立、可同时生效)。
    let timeBands: [ActivityWorkbenchTimeBand]
    /// 当前生效的时间维度窗(秒;0 = 没选时间带)。用于高亮选中的时间带 + 「生效中的筛选」里显示可清除的时间 pill。
    let activeTimeWindowSeconds: Int
    /// 当前生效的**建议 chip** 摘要(nil = 没有生效的 chip);非 nil 时在「生效中的筛选」里显示一行可一键清除的指示。
    let activeFilterSummary: String?
    /// 建议六 v2:端上模型对「需要处理」卡写的一段解读(现在最值得先处理什么 + 为什么)。nil = 模型不可用 / 没失败 /
    /// 还没生成 → 卡片退回确定性计数文案。
    let aiExplanation: String?
    /// 建议六 v2 模块①:用户展开某个失败任务时的「失败解释」焦点。nil = 没有展开的失败任务 → 不显示该区。
    let failureFocus: ActivityWorkbenchFailureFocus?
    /// 点某条时间带:切换独立的时间维度窗(再点同一带 = 取消)。父级与建议 chip 双重叠加,互不覆盖。
    let onApplyTimeBand: (ActivityWorkbenchTimeBand) -> Void
    /// 清除当前生效的**建议 chip**(只清 chip 维度,不动时间维度)。
    let onClearFilter: () -> Void
    let onApplyFilter: (ActivityAIWorkbenchFilterChip) -> Void
    let onOpenTask: (String) -> Void
    /// 模块①:「打开完整 AI 解释」→ 父级用焦点失败任务弹现成的 per-task `AIAssistSheet`(完整解释)。
    let onOpenFullFailureExplanation: () -> Void
    /// 模块②:点某个「下一步动作」→ 父级路由到焦点失败任务自身的闭包(打开报告 / 续跑 / 重跑…)或只读复制。
    let onNextAction: (WorkbenchNextAction) -> Void
    /// 自动化建议:「打开快捷指令」→ 父级打开系统快捷指令 app(用户自行创建工作流;SimpleZip 不代建)。
    let onOpenAutomation: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            // 内容可滚动:section 多会超出侧栏高度,
            // 不滚动则下方 box 被截断、点不到。header 固定,内容区滚动。
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    activeFiltersBanner
                    currentSummary
                    needsAttention
                    failureExplanation
                    nextActions
                    timeDimension
                    suggestedFilters
                    learnedHabits
                    automationSuggestion
                }
                .padding(.leading, 14)
                .padding(.trailing, 24)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 当前生效中的两个独立筛选维度(建议 chip + 时间维度),各显示一个可一键清除的 pill。**一定保留它们可清除**——
    /// 否则用户一旦启用筛选就关不掉。两维度独立:清 chip 不动时间,清时间不动 chip。都没生效 → 整区不渲染。
    @ViewBuilder
    private var activeFiltersBanner: some View {
        let activeBand = timeBands.first { $0.seconds == activeTimeWindowSeconds }
        if activeFilterSummary != nil || activeBand != nil {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.activeFilters"),
                             systemImage: "line.3.horizontal.decrease.circle.fill") {
                VStack(alignment: .leading, spacing: 6) {
                    if let activeFilterSummary {
                        activeFilterPill(text: activeFilterSummary, systemImage: "sparkles", onClear: onClearFilter)
                    }
                    if let activeBand {
                        // 已选时间带:再点同一带 = 取消,所以清除 = 重新 apply 它。
                        activeFilterPill(text: timeBandTitle(activeBand.id), systemImage: "calendar") {
                            onApplyTimeBand(activeBand)
                        }
                    }
                }
            }
        }
    }

    private func activeFilterPill(text: String, systemImage: String,
                                  onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Label(text, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.purple)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("tasks.aiFilter.clear"))
        }
    }

    /// 建议六 v2「AI 推荐时间维度」:今天 / 本周 / 本月可切换时间带(✨ 标值得关注的那带)。点选 = 切换独立的时间窗,
    /// **与建议筛选 chip 双重叠加**(各自独立、可同时生效)。无时间带数据 → 整区不渲染。
    @ViewBuilder
    private var timeDimension: some View {
        if !timeBands.isEmpty {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.timeDimension"), systemImage: "calendar") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(timeBands) { band in
                        let selected = band.seconds == activeTimeWindowSeconds
                        Button {
                            onApplyTimeBand(band)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "calendar")
                                    .font(.caption2)
                                    .foregroundStyle(selected ? Color.purple : Color.secondary)
                                Text(timeBandTitle(band.id))
                                    .lineLimit(1)
                                if band.recommended {
                                    Label(L10n.text("tasks.aiWorkbench.timeDimension.recommended"), systemImage: "sparkles")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                                Spacer(minLength: 8)
                                Text("\(band.taskCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
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

    private func timeBandTitle(_ id: String) -> String {
        L10n.text("tasks.aiWorkbench.timeBand.\(id)")
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

    /// 建议六 v2 模块①「失败解释」:用户展开某个失败任务时,侧栏给一段短解释(模型可用→✨ 解读,否则脱敏诊断兜底)
    /// + 「打开完整 AI 解释」按钮(复用现成 per-task `AIAssistSheet`)。没有焦点失败任务时整区不渲染。
    @ViewBuilder
    private var failureExplanation: some View {
        if let focus = failureFocus {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.failureExplanation"), systemImage: "stethoscope") {
                Text(focus.taskTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                if let ai = focus.aiExplanation, !ai.isEmpty {
                    Label(ai, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(focus.deterministicSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if focus.canOpenFull {
                    Button(action: onOpenFullFailureExplanation) {
                        Label(L10n.text("tasks.aiWorkbench.openFullExplanation"), systemImage: "sparkles")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// 建议六 v2 模块②「下一步动作」:焦点失败任务上可点的安全后续动作(带文字标签,比卡片纯图标按钮更易发现)。
    /// **App 安全枚举,AI 不发明动作**;每项路由回任务自身的闭包或只读复制。没有焦点失败任务 / 无可用动作 → 整区不渲染。
    @ViewBuilder
    private var nextActions: some View {
        if let focus = failureFocus, !focus.nextActions.isEmpty {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.nextActions"), systemImage: "arrow.forward.square") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(focus.nextActions) { action in
                        Button {
                            onNextAction(action)
                        } label: {
                            Label(L10n.text(action.titleKey), systemImage: action.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
                                // 真建议:AI 命名的聚集 chip(displayName)标 ✨ 并直接显示模型起的名字;
                                // 写死 chip 仍走 L10n。
                                if chip.displayName != nil {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                                Text(chip.displayName ?? chipTitle(chip.id))
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

    /// 建议六 v2「学习到的习惯」:近期常用来源 / 格式 / 位置摘要(确定性,**只摘要、不含完整路径**)。无数据则整区不渲染。
    @ViewBuilder
    private var learnedHabits: some View {
        if !habits.isEmpty {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.learnedHabits"), systemImage: "brain") {
                VStack(alignment: .leading, spacing: 5) {
                    if !habits.topSources.isEmpty {
                        habitRow(L10n.text("tasks.aiWorkbench.habits.sources"),
                                 habits.topSources.map { L10n.text("tasks.source.\($0)") })
                    }
                    if !habits.topFormats.isEmpty {
                        habitRow(L10n.text("tasks.aiWorkbench.habits.formats"),
                                 habits.topFormats.map { ".\($0)" })
                    }
                    if !habits.topLocations.isEmpty {
                        habitRow(L10n.text("tasks.aiWorkbench.habits.locations"),
                                 habits.topLocations.map { L10n.text("location.\($0)") })
                    }
                }
            }
        }
    }

    /// 建议六 v2「自动化建议」:某手动操作稳定重复时,提示用快捷指令自动化 + 打开快捷指令 app。无重复 → 整区不渲染。
    /// **只提示、不代建**(SimpleZip 不替用户创建 Shortcut,用户在快捷指令 app 自己搭)。
    @ViewBuilder
    private var automationSuggestion: some View {
        if let hint = automationHint {
            workbenchSection(title: L10n.text("tasks.aiWorkbench.automation"), systemImage: "wand.and.stars") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.format("tasks.aiWorkbench.automation.body",
                                     L10n.text("tasks.source.\(hint.source)"), "\(hint.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onOpenAutomation) {
                        Label(L10n.text("tasks.aiWorkbench.automation.open"), systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func habitRow(_ label: String, _ values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(values.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
