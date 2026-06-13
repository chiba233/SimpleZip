//
//  ActivityView.swift
//  SimpleZip
//

import Combine
import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter
    @ObservedObject var windowState: ActivityWindowState
    /// 详情展开的任务 id 集合 —— 行内 @State 会被 LazyVStack 回收丢失(滚远自动收起 bug),外置到这里。
    @State private var expandedTaskIDs: Set<UUID> = []
    /// 0.4.4:重启后从历史落盘数据重开的报告(运行时任务走 openReport 闭包弹在浏览器窗口;
    /// 闭包没了才走这里 —— 报告 sheet 直接挂在活动中心窗口上)。
    @State private var restoredReport: TaskReportAttachment?
    /// 0.4.4(用户反馈):失败红点「看到一个消一个」—— 任务列表滚动视口的当前高度,
    /// 失败卡进入这个视口(任意一行可见)就标记已看。0 = 还没测到。
    @State private var taskListViewportHeight: CGFloat = 0
    /// 0.4.4 D:来源筛选(nil = 全部)。独立 Picker,与状态筛选正交组合,跨三个分类共用。
    @State private var sourceFilter: OperationTask.Source?
    /// 0.4.4 #15:临时工作区状态(进 pane 时后台刷一次)。
    @State private var workspaceArtifacts: [URL] = []
    @State private var workspaceBytes: Int64 = 0
    @State private var workspaceMountPoint: URL?
    @State private var showsClearTempConfirm = false
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
                    // #17:选中态 = 行色渐变 chrome(opt-in;设置窗的同款行不受影响)。
                    CenteredSidebarRow(
                        title: pane.title,
                        systemImage: pane.systemImage,
                        color: pane.iconColor,
                        badge: pane.category.map(taskCount(in:)) ?? 0,
                        failureBadge: pane.category.map(failureCount(in:)) ?? 0,
                        isSelected: windowState.selectedPane == pane,
                        chromeSelection: true
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
        // 0.4.4:重启后从落盘数据重开报告(运行时走 openReport 闭包,弹在浏览器窗口)。
        .sheet(isPresented: Binding(
            get: { restoredReport != nil },
            set: { if !$0 { restoredReport = nil } }
        )) {
            switch restoredReport {
            case .releaseInspection(let report):
                ReleaseInspectionView(report: report) {
                    restoredReport = nil
                }
            case .metadata(let report):
                ArchiveMetadataReportView(report: report) {
                    restoredReport = nil
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func tasks(in category: OperationTask.Category) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.category == category }
    }

    private var selectedPaneView: some View {
        Group {
            if selectedPane == .help {
                // 0.4.2：活动中心的「帮助」与「设置 → 帮助」同一个视图（A1：不重画）。
                HelpPane()
            } else if selectedPane == .workspace {
                // 0.4.4 #15:临时工作区(hero 头 + grouped Form,与设置 pane 同款骨架)。
                VStack(spacing: 0) {
                    HStack {
                        paneHero(selectedPane)
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    workspaceView
                }
            } else if selectedPane == .settings {
                // 设置页用系统设置同款 grouped Form —— 自带滚动与顶部安全区处理，
                // 修掉「点设置后内容往上错位」（之前是裸 VStack，不像 List/Form 那样吃标题栏 inset）。
                // #17:顶部加同款 hero 头(Form 本体维持设置区已验收的原生样式)。
                VStack(spacing: 0) {
                    HStack {
                        paneHero(selectedPane)
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    activitySettingsView
                }
            } else if let category = selectedPane.category {
                VStack(spacing: 0) {
                    HStack {
                        // hero 不许被右侧控件挤压换行(标题竖排过,用户截图打回)。
                        paneHero(selectedPane)
                            .fixedSize()
                            .layoutPriority(1)
                        Spacer()
                        filterMenu(for: category)
                        sourceFilterMenu
                        // F4:队列级暂停/恢复 —— 暂停态下即使任务跑完也保持可见(不然没法恢复闸门)。
                        // 运行态的三颗控制钮都用纯图标(.help 出全文)—— 带文字时把 hero 挤成竖排(用户截图)。
                        if taskCenter.runningCount > 0 || taskCenter.isQueuePaused {
                            Button {
                                taskCenter.setQueuePaused(!taskCenter.isQueuePaused)
                            } label: {
                                Label(
                                    L10n.text(taskCenter.isQueuePaused ? "tasks.queueResume" : "tasks.queuePause"),
                                    systemImage: taskCenter.isQueuePaused ? "play.circle" : "pause.circle"
                                )
                                .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .help(L10n.text(taskCenter.isQueuePaused ? "tasks.queueResume" : "tasks.queuePause"))
                        }
                        if taskCenter.runningCount > 0 {
                            // 队列管理①:「完成后睡眠」—— 仅任务运行期间可见;最后一个任务收尾时整机睡眠。
                            Toggle(isOn: $taskCenter.sleepWhenAllTasksFinish) {
                                Label(L10n.text("tasks.sleepWhenDone"), systemImage: "moon.zzz")
                                    .labelStyle(.iconOnly)
                            }
                            .toggleStyle(.button)
                            .help(L10n.text("tasks.sleepWhenDone.help"))
                            Button {
                                taskCenter.cancelAll()
                            } label: {
                                Label(L10n.text("tasks.cancelAll"), systemImage: "xmark.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .help(L10n.text("tasks.cancelAll"))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    // F4:暂停态说明 —— 如实写清「不可暂停的种类会继续跑完、新任务排队」,不假装全冻住。
                    if taskCenter.isQueuePaused {
                        Label(L10n.text("tasks.queuePaused.note"), systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 10)
                    }

                    taskList(in: category)
                }
            }
        }
    }

    /// #17:pane 顶部的小 hero 头 —— 渐变发光图标瓦片 + 标题 + 副标题(纯静态,无 hover)。
    private func paneHero(_ pane: ActivityPane) -> some View {
        HStack(spacing: 12) {
            // 用户拍板:hero 瓦片维持第一轮调浅后的深度(0.65/0.45,辉光 0.30)——
            // 第三轮「彩色瓦片再浅」只指内容区小瓦片,hero 不在内(改太浅被打回)。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [pane.iconColor.opacity(0.65), pane.iconColor.opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .frame(width: 38, height: 38)
                .shadow(color: pane.iconColor.opacity(0.30), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                if let subtitle = pane.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 任务列表：每条任务一张圆角卡片（替代平铺行），空时给居中的大图标空状态。
    @ViewBuilder
    private func taskList(in category: OperationTask.Category) -> some View {
        let tasks = filteredTasks(in: category)
        if tasks.isEmpty {
            // #17:空状态换手绘风 —— 分类色渐变发光瓦片(对齐欢迎助手完成页),纯静态。
            let tint = ActivityPane.pane(for: category).iconColor
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.62), tint.opacity(0.38)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "tray")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: tint.opacity(0.27), radius: 14, y: 6)
                Text(L10n.text("tasks.empty"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 用 ScrollView + LazyVStack 而不是 List：List 底下的 NSTableView 会缓存行高，
            // 任务行展开「详情」后行高不重算 → 内容撑不开卡片被截断（用户报的 bug）。
            // LazyVStack 行高随内容自然生长，展开多少撑多少。
            // 队列管理②跟进：等并发槽的任务单独一组放最上（带组头），不再混在运行中靠状态行区分。
            let waiting = tasks.filter { $0.status.isRunning && $0.isAwaitingSlot }
            let rest = tasks.filter { !($0.status.isRunning && $0.isAwaitingSlot) }
            ScrollViewReader { proxy in
                ScrollView {
                    // 0.4.4 bug 修复:LazyVStack 在卡片高度不一时边滚边重估行高 —— 滚动条抽搐、
                    // 底部卡片滚不进来(用户截图报告)。任务卡数量受历史上限(≤500)约束,普通 VStack
                    // 一次性布局完即稳;展开态已外置(expandedTaskIDs),不再依赖懒加载的视图复用。
                    VStack(spacing: 16) {
                        // 队列管理③:写锁可视化 —— 有归档被写锁占用时,在归档分类顶部点名
                        // 谁占着锁、谁在排队。锁释放即消失,平时零占位。
                        if category == .archive, !taskCenter.writeLockSnapshot.entries.isEmpty {
                            taskGroupHeader(L10n.text("tasks.writeLockSection"), systemImage: "lock.fill", tint: .orange)
                            ForEach(taskCenter.writeLockSnapshot.entries) { entry in
                                writeLockCard(entry)
                            }
                            Divider()
                                .padding(.vertical, 4)
                        }
                        if !waiting.isEmpty {
                            taskGroupHeader(
                                L10n.format("tasks.waitingSection", "\(waiting.count)"),
                                systemImage: "hourglass",
                                tint: .gray
                            )
                            ForEach(waiting) { task in
                                ActivityTaskCard(task: task, expandedTaskIDs: $expandedTaskIDs, onOpenAttachment: { restoredReport = $0 },
                                                 viewportHeight: taskListViewportHeight,
                                                 onBecameVisible: { taskCenter.markFailureSeen(task) })
                                    .id(task.id)
                            }
                            if !rest.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                        ForEach(rest) { task in
                            ActivityTaskCard(task: task, expandedTaskIDs: $expandedTaskIDs, onOpenAttachment: { restoredReport = $0 },
                                                 viewportHeight: taskListViewportHeight,
                                                 onBecameVisible: { taskCenter.markFailureSeen(task) })
                                .id(task.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 22)
                }
                // 失败卡可见性检测的坐标系锚在 ScrollView 视口(非内容)—— 卡片在此坐标系里
                // minY∈[0,视口高] 即「现在屏幕上看得到」。
                .coordinateSpace(name: Self.taskScrollSpace)
                // 视口高度探针:background 落在 ScrollView 自身 bounds(视口),不随内容滚动。
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { taskListViewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { taskListViewportHeight = $0 }
                    }
                )
                // 新任务插在最前；列表顶部条目变化（= 有新任务）时自动滚到最上，用户不会错过。
                .onChange(of: tasks.first?.id) { newTopID in
                    guard let newTopID else { return }
                    withAnimation { proxy.scrollTo(newTopID, anchor: .top) }
                }
            }
        }
    }

    /// 失败卡可见性检测用的滚动坐标系名(ScrollView 视口坐标)。
    static let taskScrollSpace = "activityTaskScroll"

    /// 任务卡片列表里的小组头(写锁区 / 等待组)。#17:换 chrome 小节卡 —— 彩色渐变小瓦片 +
    /// 标题,层叠渐变底;纯静态(无 hover / 无动画)。
    private func taskGroupHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HeroChromeCard(color: tint, cornerRadius: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.7))
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    /// 队列管理③:单个被占用归档的写锁卡片 —— 包名 + 持有任务 + 排队任务。
    /// operationID 映射回运行中任务的标题;映射不到(理论上极短的交接窗口)给通用文案。
    private func writeLockCard(_ entry: ArchiveWriteLockSnapshot.Entry) -> some View {
        let holderTitle = taskCenter.taskTitle(forOperationID: entry.holderOperationID)
            ?? L10n.text("tasks.writeLock.holder.unknown")
        let waiterTitles = entry.waiterOperationIDs.map {
            taskCenter.taskTitle(forOperationID: $0) ?? L10n.text("tasks.writeLock.holder.unknown")
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .background(Color.orange.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L10n.format("tasks.writeLock.holder", holderTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !waiterTitles.isEmpty {
                    Text(L10n.format("tasks.writeLock.waiters", "\(waiterTitles.count)", waiterTitles.joined(separator: " · ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        )
    }

    private func taskCount(in category: OperationTask.Category) -> Int {
        tasks(in: category).count
    }

    /// D:侧栏失败计数(普通计算属性,读历史聚合)。
    /// 0.4.4(用户反馈「红点常驻」):只数**没看过**的失败 —— 查看该分类即标记已看、红点灭,重启不复亮。
    private func failureCount(in category: OperationTask.Category) -> Int {
        unseenFailureIDs(in: category).count
    }

    /// 没看过的失败任务 id 集(Equatable,onChange 监听「查看期间新失败」用)。
    private func unseenFailureIDs(in category: OperationTask.Category) -> Set<UUID> {
        Set(tasks(in: category).compactMap { task in
            if case .failed = task.status, !task.failureSeen { return task.id }
            return nil
        })
    }

    private func filteredTasks(in category: OperationTask.Category) -> [OperationTask] {
        let filter = filter(for: category)
        return tasks(in: category).filter { task in
            filter.includes(task) && (sourceFilter == nil || task.source == sourceFilter)
        }
    }

    /// D:来源筛选 Picker(原生菜单,选中态系统打勾;nil = 全部)。
    private var sourceFilterMenu: some View {
        Picker("", selection: $sourceFilter) {
            Text(L10n.text("tasks.filter.allSources")).tag(OperationTask.Source?.none)
            ForEach(OperationTask.Source.allCases, id: \.self) { source in
                Text(L10n.text("tasks.source.\(source.rawValue)")).tag(Optional(source))
            }
        }
        .labelsHidden()
        .fixedSize()
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
        // 用户拍板:筛选小图标删掉(太丑)—— 只留下拉本体。
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
                    HStack(spacing: 8) {
                        // D:只清成功(含已跳过),失败/取消留着排查。
                        Button {
                            taskCenter.clearSucceededHistory()
                        } label: {
                            Label(L10n.text("tasks.settings.clearSucceeded.button"), systemImage: "checkmark.circle.badge.xmark")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .disabled(taskCenter.history.isEmpty)
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

    /// 0.4.4 #15:临时工作区 —— 加密临时卷状态 + SimpleZip 临时产物清单与清理。
    private var workspaceView: some View {
        Form {
            Section(L10n.text("workspace.volume.section")) {
                SettingsControlRow(
                    title: L10n.text("workspace.volume.title"),
                    description: L10n.text("workspace.volume.description"),
                    systemImage: "lock.shield", iconTint: .teal
                ) {
                    Text(workspaceMountPoint == nil
                         ? L10n.text("workspace.volume.notMounted")
                         : L10n.text("workspace.volume.mounted"))
                        .font(.callout)
                        .foregroundStyle(workspaceMountPoint == nil ? Color.secondary : Color.green)
                }
                if let mountPoint = workspaceMountPoint {
                    Text(mountPoint.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(L10n.text("workspace.volume.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.text("workspace.artifacts.section")) {
                SettingsControlRow(
                    title: L10n.text("workspace.artifacts.title"),
                    description: L10n.text("workspace.artifacts.description"),
                    systemImage: "internaldrive", iconTint: .orange
                ) {
                    HStack(spacing: 8) {
                        Text(L10n.format(
                            "workspace.artifacts.value",
                            "\(workspaceArtifacts.count)",
                            ByteCountFormatter.string(fromByteCount: workspaceBytes, countStyle: .file)
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.temporaryDirectory])
                        } label: {
                            Label(L10n.text("button.revealInFinder"), systemImage: "arrow.up.forward.app")
                        }
                        Button {
                            showsClearTempConfirm = true
                        } label: {
                            Label(L10n.text("workspace.artifacts.clear"), systemImage: "trash")
                        }
                        .disabled(workspaceArtifacts.isEmpty)
                        .confirmationDialog(L10n.text("workspace.artifacts.clear.confirm"), isPresented: $showsClearTempConfirm) {
                            Button(L10n.text("workspace.artifacts.clear"), role: .destructive) {
                                clearStaleWorkspaceArtifacts()
                            }
                            // macOS 不自动补取消 —— 破坏性操作必须给反悔出口。
                            Button(L10n.text("button.cancel"), role: .cancel) { }
                        }
                    }
                }
                ForEach(workspaceArtifacts.prefix(20), id: \.self) { url in
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if workspaceArtifacts.count > 20 {
                    Text(L10n.format("security.report.more", "\(workspaceArtifacts.count - 20)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.text("workspace.artifacts.timing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadWorkspaceState)
    }

    /// 进 pane 时后台刷一次(枚举 + 递归体积,不在主线程做)。
    private func reloadWorkspaceState() {
        workspaceMountPoint = SecureScratchVolume.shared.currentMountPoint
        Task.detached(priority: .utility) {
            let artifacts = TemporaryResourceManager.temporaryArtifactURLs()
            let bytes = TemporaryResourceManager.temporaryArtifactsByteSize(olderThan: Date())
            await MainActor.run {
                workspaceArtifacts = artifacts
                workspaceBytes = bytes
            }
        }
    }

    /// 「立即清理」只删**陈旧**条目(mtime 早于本次会话开始)—— 本次会话在用的 staging 绝不碰。
    private func clearStaleWorkspaceArtifacts() {
        Task.detached(priority: .utility) {
            TemporaryResourceManager.clearTemporaryArtifacts(olderThan: TemporaryResourceManager.sessionStart)
            await MainActor.run { reloadWorkspaceState() }
        }
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
    /// 0.4.4 #15:临时工作区(加密临时卷 + 临时产物)。
    case workspace
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
        case .workspace, .help, .settings:
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
        case .workspace:
            return L10n.text("tasks.workspaceSection")
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
        case .workspace:
            return "externaldrive.badge.timemachine"
        case .help:
            return "lifepreserver"
        case .settings:
            return "gearshape"
        }
    }

    /// #17 hero 头副标题(帮助页自带 chrome,不走 hero 头,无副标题)。
    var subtitle: String? {
        switch self {
        case .archive:
            return L10n.text("tasks.pane.archive.subtitle")
        case .fileOperation:
            return L10n.text("tasks.pane.fileOperation.subtitle")
        case .undoRedo:
            return L10n.text("tasks.pane.undoRedo.subtitle")
        case .workspace:
            return L10n.text("tasks.pane.workspace.subtitle")
        case .settings:
            return L10n.text("tasks.pane.settings.subtitle")
        case .help:
            return nil
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
        case .workspace:
            return .teal
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

/// 单张任务卡片。#17:外壳换分类色层叠渐变 chrome(归档蓝 / 文件橙 / 撤销紫);**性能阉割版** ——
/// 任务卡 progress 每秒多帧重渲染,chrome 必须纯静态:无 hover @State、渐变层无动画。
/// **运行中**外圈的旋转强调色渐变描边保留现状不动(唯一既有动画)。
/// 单独成 view 是为了 @ObservedObject 单独观察该任务 —— 状态翻转（跑完 / 取消）时
/// 只这张卡重渲染、描边动画即时停。
private struct ActivityTaskCard: View {
    @ObservedObject var task: OperationTask
    /// 详情展开真值(按任务 id 存在列表层,行被 LazyVStack 回收也不丢)。
    @Binding var expandedTaskIDs: Set<UUID>
    /// 0.4.4:重启后报告从落盘附件重开(openReport 闭包只活一个会话)。
    var onOpenAttachment: ((TaskReportAttachment) -> Void)?
    /// 0.4.4(用户反馈):失败红点「看到一个消一个」用的视口高度 + 进入视口回调。
    var viewportHeight: CGFloat = 0
    var onBecameVisible: (() -> Void)?
    @State private var borderAngle = 0.0

    private var tint: Color {
        switch task.category {
        case .archive: return .blue
        case .fileOperation: return .orange
        case .undoRedo: return .purple
        }
    }

    /// 这张卡是不是「还没被看过的失败」—— 只有它需要挂可见性探针。
    private var isUnseenFailure: Bool {
        if case .failed = task.status { return !task.failureSeen }
        return false
    }

    var body: some View {
        HeroChromeCard(color: tint, cornerRadius: 12) {
            ActivityTaskRow(task: task, isShowingDetails: Binding(
                get: { expandedTaskIDs.contains(task.id) },
                set: { expanded in
                    if expanded {
                        expandedTaskIDs.insert(task.id)
                    } else {
                        expandedTaskIDs.remove(task.id)
                    }
                }
            ), onOpenAttachment: onOpenAttachment)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if task.status.isRunning {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        // 失败红点「看到一个消一个」:只给未看过的失败卡挂可见性探针 —— 卡片任意一行进入
        // ScrollView 视口(minY < 视口高 且 maxY > 0)即标记已看;标记后 isUnseenFailure 翻 false、
        // 探针自动撤掉(自限制,不影响其余卡的滚动性能)。background 不参与布局。
        .background {
            if isUnseenFailure, viewportHeight > 0 {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { reportIfVisible(geo) }
                        .onChange(of: geo.frame(in: .named(ActivityView.taskScrollSpace)).minY) { _ in
                            reportIfVisible(geo)
                        }
                }
            }
        }
    }

    private func reportIfVisible(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .named(ActivityView.taskScrollSpace))
        // 卡片与视口 [0, 视口高] 有交集 = 屏幕上至少露出一部分。
        if frame.maxY > 0, frame.minY < viewportHeight {
            onBecameVisible?()
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
