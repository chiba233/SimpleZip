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
    @State private var undoRedoFilter = ActivityTaskFilter.all
    @AppStorage(AppPreferences.Key.activityHistoryLimit) private var historyLimit = AppPreferences.activityHistoryLimit
    @AppStorage(AppPreferences.Key.heavyTaskConcurrencyLimit) private var concurrencyLimit = AppPreferences.heavyTaskConcurrencyLimit

    // 弃用 NavigationSplitView（详见 SettingsView 同款注释）：普通 HStack + 绝对定宽侧栏，
    // 物理上没有把手、没有折叠、没有持久化；毛玻璃用 SidebarBackdrop 补回。
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 12)
                ForEach(ActivityPane.allCases) { pane in
                    CenteredSidebarRow(
                        title: pane.title,
                        systemImage: pane.systemImage,
                        color: pane.iconColor,
                        badge: pane.category.map(taskCount(in:)) ?? 0,
                        isSelected: windowState.selectedPane == pane
                    ) {
                        windowState.selectedPane = pane
                    }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            // 自适应宽（用户拍板「不要定死」）：fixedSize 让侧栏取**最宽一行的内容宽度**，
            // 文字与计数永远完整；minWidth 只是极短文字时的下限。毛玻璃铺满到窗口顶（沉浸式标题栏）。
            .frame(minWidth: 220)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .background(SidebarBackdrop().ignoresSafeArea())

            Divider()
                .ignoresSafeArea()

            selectedPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 880, idealWidth: 1020, maxWidth: .infinity,
            minHeight: 560, idealHeight: 700, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("tasks.window.title"))
    }

    private func tasks(in category: OperationTask.Category) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.category == category }
    }

    private var selectedPaneView: some View {
        Group {
            if selectedPane == .help {
                // 0.4.2：活动中心的「帮助」与「设置 → 帮助」同一个视图（A1：不重画）。
                HelpPane()
            } else if selectedPane == .settings {
                // 设置页用系统设置同款 grouped Form —— 自带滚动与顶部安全区处理，
                // 修掉「点设置后内容往上错位」（之前是裸 VStack，不像 List/Form 那样吃标题栏 inset）。
                activitySettingsView
            } else if let category = selectedPane.category {
                VStack(spacing: 0) {
                    HStack {
                        Text(selectedPane.title)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        filterMenu(for: category)
                        if taskCenter.runningCount > 0 {
                            // 队列管理①:「完成后睡眠」—— 仅任务运行期间可见;最后一个任务收尾时整机睡眠。
                            Toggle(isOn: $taskCenter.sleepWhenAllTasksFinish) {
                                Label(L10n.text("tasks.sleepWhenDone"), systemImage: "moon.zzz")
                            }
                            .toggleStyle(.button)
                            .help(L10n.text("tasks.sleepWhenDone.help"))
                            Button {
                                taskCenter.cancelAll()
                            } label: {
                                Label(L10n.text("tasks.cancelAll"), systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                    taskList(in: category)
                }
            }
        }
    }

    /// 任务列表：每条任务一张圆角卡片（替代平铺行），空时给居中的大图标空状态。
    @ViewBuilder
    private func taskList(in category: OperationTask.Category) -> some View {
        let tasks = filteredTasks(in: category)
        if tasks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L10n.text("tasks.empty"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 用 ScrollView + LazyVStack 而不是 List：List 底下的 NSTableView 会缓存行高，
            // 任务行展开「详情」后行高不重算 → 内容撑不开卡片被截断（用户报的 bug）。
            // LazyVStack 行高随内容自然生长，展开多少撑多少。
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(tasks) { task in
                            ActivityTaskCard(task: task)
                                .id(task.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                }
                // 新任务插在最前；列表顶部条目变化（= 有新任务）时自动滚到最上，用户不会错过。
                .onChange(of: tasks.first?.id) { newTopID in
                    guard let newTopID else { return }
                    withAnimation { proxy.scrollTo(newTopID, anchor: .top) }
                }
            }
        }
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
        case .undoRedo:
            return undoRedoFilter
        }
    }

    private func setFilter(_ filter: ActivityTaskFilter, for category: OperationTask.Category) {
        switch category {
        case .archive:
            archiveFilter = filter
        case .fileOperation:
            fileFilter = filter
        case .undoRedo:
            undoRedoFilter = filter
        }
    }

    private func filterMenu(for category: OperationTask.Category) -> some View {
        // Menu 不当按钮用（设计准则）→ 原生 Picker 弹出菜单，选中态由系统打勾。
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { filter(for: category) },
                set: { setFilter($0, for: category) }
            )) {
                ForEach(ActivityTaskFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var activitySettingsView: some View {
        Form {
            Section(L10n.text("tasks.settings.history")) {
                SettingsControlRow(
                    title: L10n.text("tasks.settings.historyLimit"),
                    description: L10n.text("tasks.settings.historyLimit.description"),
                    systemImage: "clock",
                    iconTint: .purple
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

                // 队列管理②:重任务并发上限(0 = 不限)。超出上限的任务排队等待,状态行显示等待、可取消。
                SettingsControlRow(
                    title: L10n.text("settings.tasks.concurrencyLimit"),
                    description: L10n.text("settings.tasks.concurrencyLimit.description"),
                    systemImage: "square.stack.3d.up",
                    iconTint: .teal
                ) {
                    HStack(spacing: 8) {
                        Text(concurrencyLimit == 0
                            ? L10n.text("settings.tasks.concurrencyLimit.unlimited")
                            : "\(concurrencyLimit)")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        Stepper("", value: $concurrencyLimit, in: 0...16)
                            .labelsHidden()
                    }
                    .onChange(of: concurrencyLimit) { newValue in
                        AppPreferences.heavyTaskConcurrencyLimit = newValue
                    }
                }

                SettingsControlRow(
                    title: L10n.text("tasks.settings.openOnFailure"),
                    description: L10n.text("tasks.settings.openOnFailure.description"),
                    systemImage: "exclamationmark.bubble",
                    iconTint: .orange
                ) {
                    Toggle("", isOn: $openOnFailure)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: L10n.text("tasks.settings.playSound"),
                    description: L10n.text("tasks.settings.playSound.description"),
                    systemImage: "speaker.wave.2",
                    iconTint: .pink
                ) {
                    Toggle("", isOn: $playSound)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsControlRow(
                    title: L10n.text("tasks.settings.clearHistory"),
                    description: L10n.text("tasks.settings.clearHistory.description"),
                    systemImage: "trash",
                    iconTint: .red
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
            }

            // 0.4.3 #8:写回恢复区(用户可见入口 —— 开发者工具是隐藏区,不放那)。
            Section(L10n.text("tasks.recovery.section")) {
                SettingsControlRow(
                    title: L10n.text("tasks.recovery.show"),
                    description: L10n.text("tasks.recovery.show.description"),
                    systemImage: "externaldrive.badge.timemachine",
                    iconTint: .teal
                ) {
                    Button {
                        try? FileManager.default.createDirectory(at: ArchiveRecoveryArea.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([ArchiveRecoveryArea.directory])
                    } label: {
                        Label(L10n.text("tasks.recovery.show.button"), systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
                SettingsControlRow(
                    title: L10n.text("tasks.recovery.clear"),
                    description: L10n.text("tasks.recovery.clear.description"),
                    systemImage: "trash",
                    iconTint: .red
                ) {
                    Button(role: .destructive) {
                        try? ArchiveRecoveryArea.clear()
                        recoveryCount = ArchiveRecoveryArea.contents().count
                    } label: {
                        Label(L10n.format("tasks.recovery.clear.button", "\(recoveryCount)"), systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .disabled(recoveryCount == 0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { recoveryCount = ArchiveRecoveryArea.contents().count }
    }

    private var selectedPane: ActivityPane {
        windowState.selectedPane
    }

    // 0.4.2 活动中心设置开关 —— @AppStorage(自定义 Binding 在被长持有的活动中心视图树里
    // 会读到陈旧快照,用户报「重开窗口开关复位」;@AppStorage 响应式且与 UserDefaults 双向同步)。
    @AppStorage(AppPreferences.Key.tasksOpenOnFailure) private var openOnFailure = false
    @AppStorage(AppPreferences.Key.tasksPlaySoundOnFinish) private var playSound = false
    /// 0.4.3 #8:恢复区文件数(进设置页时刷新;清理后归零驱动按钮禁用)。
    @State private var recoveryCount = 0
}

enum ActivityPane: CaseIterable, Identifiable, Hashable {
    case archive
    case fileOperation
    case undoRedo
    case help
    case settings

    var id: Self { self }

    static func pane(for category: OperationTask.Category) -> ActivityPane {
        switch category {
        case .archive:
            return .archive
        case .fileOperation:
            return .fileOperation
        case .undoRedo:
            return .undoRedo
        }
    }

    var category: OperationTask.Category? {
        switch self {
        case .archive:
            return .archive
        case .fileOperation:
            return .fileOperation
        case .undoRedo:
            return .undoRedo
        case .help, .settings:
            return nil
        }
    }

    var title: String {
        switch self {
        case .archive:
            return L10n.text("tasks.archiveSection")
        case .fileOperation:
            return L10n.text("tasks.fileSection")
        case .undoRedo:
            return L10n.text("tasks.undoRedoSection")
        case .help:
            return L10n.text("settings.section.help")
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
        case .undoRedo:
            return "arrow.uturn.backward"
        case .help:
            return "lifepreserver"
        case .settings:
            return "gearshape"
        }
    }

    /// 侧栏彩色图标瓦片的底色（与设置窗口同一套 System Settings 风格）。
    var iconColor: Color {
        switch self {
        case .archive:
            return .blue
        case .fileOperation:
            return .orange
        case .undoRedo:
            return .purple
        case .help:
            return .cyan
        case .settings:
            return .gray
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

/// 单张任务卡片：圆角卡 + 软阴影；**运行中**外圈跑一道旋转的强调色渐变描边（微动画）。
/// 单独成 view 是为了 @ObservedObject 单独观察该任务 —— 状态翻转（跑完 / 取消）时
/// 只这张卡重渲染、描边动画即时停。
private struct ActivityTaskCard: View {
    @ObservedObject var task: OperationTask
    @State private var borderAngle = 0.0

    var body: some View {
        ActivityTaskRow(task: task)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            )
            .overlay {
                if task.status.isRunning {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color.accentColor.opacity(0.04),
                                    Color.accentColor.opacity(0.9),
                                    Color.accentColor.opacity(0.04)
                                ]),
                                center: .center,
                                angle: .degrees(borderAngle)
                            ),
                            lineWidth: 1.5
                        )
                        .allowsHitTesting(false)
                        .onAppear {
                            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                                borderAngle = 360
                            }
                        }
                }
            }
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
