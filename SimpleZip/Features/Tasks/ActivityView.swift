//
//  ActivityView.swift
//  SimpleZip
//

import Combine
import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter
    @ObservedObject var windowState: ActivityWindowState
    @State private var archiveFilter = ActivityTaskFilter.all
    @State private var fileFilter = ActivityTaskFilter.all
    @AppStorage(AppPreferences.Key.activityHistoryLimit) private var historyLimit = AppPreferences.activityHistoryLimit

    // 0.3.3 UI 现代化：手画的 HStack 侧栏重绘成原生 NavigationSplitView + List(selection:)，
    // 任务计数用原生 .badge —— 选中态 / 开关 / 材质全交给系统（跟设置窗口同一套做法）。
    var body: some View {
        // 侧栏**常驻**：columnVisibility 钉死 .all + 去掉系统的收起按钮（跟设置窗口同一决定）。
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: paneSelectionBinding) {
                ForEach(ActivityPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .badge(pane.category.map(taskCount(in:)) ?? 0)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 165, ideal: 190, max: 240)
            .hidingSidebarToggle()
        } detail: {
            selectedPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 620, idealWidth: 760, maxWidth: .infinity,
            minHeight: 420, idealHeight: 540, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("tasks.window.title"))
    }

    /// List 的 selection 是 Optional；窗口状态里的 selectedPane 不是 —— 清空选择时维持原 pane。
    private var paneSelectionBinding: Binding<ActivityPane?> {
        Binding(
            get: { windowState.selectedPane },
            set: { newValue in
                if let newValue {
                    windowState.selectedPane = newValue
                }
            }
        )
    }

    private func tasks(in category: OperationTask.Category) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.category == category }
    }

    private var selectedPaneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedPane.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                if let category = selectedPane.category {
                    filterMenu(for: category)
                }
                if selectedPane != .settings, taskCenter.runningCount > 0 {
                    Button(L10n.text("tasks.cancelAll")) {
                        taskCenter.cancelAll()
                    }
                }
            }

            if selectedPane == .settings {
                activitySettingsView
            } else if let category = selectedPane.category {
                ScrollViewReader { proxy in
                    List {
                        taskRows(tasks: filteredTasks(in: category))
                    }
                    .listStyle(.inset)
                    // 新任务插在最前；列表顶部条目变化（= 有新任务）时自动滚到最上，用户不会错过。
                    .onChange(of: filteredTasks(in: category).first?.id) { newTopID in
                        guard let newTopID else { return }
                        withAnimation { proxy.scrollTo(newTopID, anchor: .top) }
                    }
                }
            }
        }
        .padding(16)
    }

    private func taskCount(in category: OperationTask.Category) -> Int {
        tasks(in: category).count
    }

    private func filteredTasks(in category: OperationTask.Category) -> [OperationTask] {
        let filter = filter(for: category)
        return tasks(in: category).filter(filter.includes)
    }

    private func filter(for category: OperationTask.Category) -> ActivityTaskFilter {
        switch category {
        case .archive:
            return archiveFilter
        case .fileOperation:
            return fileFilter
        }
    }

    private func setFilter(_ filter: ActivityTaskFilter, for category: OperationTask.Category) {
        switch category {
        case .archive:
            archiveFilter = filter
        case .fileOperation:
            fileFilter = filter
        }
    }

    private func filterMenu(for category: OperationTask.Category) -> some View {
        Menu {
            ForEach(ActivityTaskFilter.allCases) { filter in
                Button {
                    setFilter(filter, for: category)
                } label: {
                    if self.filter(for: category) == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Text(filter.title)
                    }
                }
            }
        } label: {
            Label(filter(for: category).title, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var activitySettingsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("tasks.settings.history"))
                .font(.headline)
                .padding(.bottom, 8)

            SettingsControlRow(
                title: L10n.text("tasks.settings.historyLimit"),
                description: L10n.text("tasks.settings.historyLimit.description")
            ) {
                HStack(spacing: 8) {
                    Text(L10n.format("tasks.settings.historyLimit.value", historyLimit))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    Stepper("", value: $historyLimit, in: 1...500)
                        .labelsHidden()
                }
                .onChange(of: historyLimit) { newValue in
                    AppPreferences.activityHistoryLimit = newValue
                    taskCenter.applyHistoryLimitChange()
                }
            }

            Divider()

            SettingsControlRow(
                title: L10n.text("tasks.settings.clearHistory"),
                description: L10n.text("tasks.settings.clearHistory.description")
            ) {
                Button(role: .destructive) {
                    taskCenter.clearHistory()
                } label: {
                    Label(L10n.text("tasks.settings.clearHistory.button"), systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .disabled(taskCenter.history.isEmpty)
            }

            Spacer()
        }
        // 自适应窗口宽度：填满可用宽度（与任务列表一致），不再固定 640 左对齐留一大片空白。
        // 行内有 Spacer 把控件顶到右侧，宽窗口也不会有死区。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func taskRows(tasks: [OperationTask]) -> some View {
        if tasks.isEmpty {
            Text(L10n.text("tasks.empty"))
                .foregroundStyle(.secondary)
        } else {
            ForEach(tasks) { task in
                ActivityTaskRow(task: task)
            }
        }
    }

    private var selectedPane: ActivityPane {
        windowState.selectedPane
    }
}

enum ActivityPane: CaseIterable, Identifiable, Hashable {
    case archive
    case fileOperation
    case settings

    var id: Self { self }

    static func pane(for category: OperationTask.Category) -> ActivityPane {
        switch category {
        case .archive:
            return .archive
        case .fileOperation:
            return .fileOperation
        }
    }

    var category: OperationTask.Category? {
        switch self {
        case .archive:
            return .archive
        case .fileOperation:
            return .fileOperation
        case .settings:
            return nil
        }
    }

    var title: String {
        switch self {
        case .archive:
            return L10n.text("tasks.archiveSection")
        case .fileOperation:
            return L10n.text("tasks.fileSection")
        case .settings:
            return L10n.text("tasks.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .archive:
            return "archivebox"
        case .fileOperation:
            return "folder"
        case .settings:
            return "gearshape"
        }
    }
}

@MainActor
final class ActivityWindowState: ObservableObject {
    @Published var selectedPane = ActivityPane.archive

    func select(category: OperationTask.Category) {
        selectedPane = ActivityPane.pane(for: category)
    }
}

// ActivityPaneSidebarButton（自绘侧栏按钮）已删 —— 活动中心改用原生
// NavigationSplitView + List(selection:) + .badge，跟设置窗口同一套做法。

private enum ActivityTaskFilter: CaseIterable, Identifiable, Hashable {
    case all
    case running
    case succeeded
    case failed
    case cancelled

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return L10n.text("tasks.filter.all")
        case .running:
            return L10n.text("tasks.filter.running")
        case .succeeded:
            return L10n.text("tasks.filter.succeeded")
        case .failed:
            return L10n.text("tasks.filter.failed")
        case .cancelled:
            return L10n.text("tasks.filter.cancelled")
        }
    }

    func includes(_ task: OperationTask) -> Bool {
        switch self {
        case .all:
            return true
        case .running:
            return task.status.isRunning
        case .succeeded:
            // 「已完成」涵盖正常成功与「内容相同已跳过」——跳过在用户心智里也是已结束态，不该被这个筛选藏掉。
            switch task.status {
            case .succeeded, .skipped: return true
            default: return false
            }
        case .failed:
            if case .failed = task.status { return true }
            return false
        case .cancelled:
            if case .cancelled = task.status { return true }
            return false
        }
    }
}
