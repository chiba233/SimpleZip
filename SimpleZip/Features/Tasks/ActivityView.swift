//
//  ActivityView.swift
//  SimpleZip
//

import AppKit
import Combine
import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter
    @ObservedObject var windowState: ActivityWindowState
    /// 建议六 v2 模块⑤:后台预烘焙的「建议筛选」chip 排序缓存写入时(`applyWorkbenchChipRanking` 发 objectWillChange)
    /// 让工作台重读缓存、套用 AI 顺序。活动中心非 FSEvents 热路径,偶发重渲染可接受。
    @ObservedObject private var aiIndexStore = AIBackgroundIndexStore.shared
    /// 详情展开的任务 id 集合 —— 行内 @State 会被 LazyVStack 回收丢失(滚远自动收起 bug),外置到这里。
    @State private var expandedTaskIDs: Set<UUID> = []
    /// #29:当前被深链 / Spotlight 跳转高亮的任务 id(滚到它后闪一圈,2.5 秒后消)。
    @State private var highlightedTaskID: UUID?
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
    // #60(macOS 26 AI):自然语言筛选 —— 输入一句话 → AI 映射成 {状态, 来源, 关键词, 时间窗} → 确定性地应用。
    // AI 只产规格、不执行;筛选纯属只读展示。仅 AIReportAssistant.isReady 时露出按钮。
    // 关键词(匹配任务名/归档名)+ 时间窗是「临时分类」的灵魂 —— 不止在现成状态/来源里挑。
    @State private var aiFilterText = ""
    @State private var aiFilterRunning = false
    /// AI 抽出的精确过滤条件 —— App 在代码里**确定性匹配**(模型只负责把短语抽成这四个字段,
    /// 不让它扫列表选行,那不可靠)。
    @State private var aiKeyword = ""
    /// 时间窗换算成**秒**(0 = 不限)—— AI 只给「数值 + 单位」,换算在 App 里做(避免模型算错单位,
    /// 如「3600 秒」被当成分钟)。`aiTimeBefore` = 早于(外)还是晚于(内)该时刻。
    @State private var aiWithinSeconds: TimeInterval = 0
    @State private var aiTimeBefore = false
    @State private var aiStatus = ActivityTaskFilter.all
    @State private var aiSource: OperationTask.Source?
    /// 任务类型范围(nil = 不限)。
    @State private var aiKinds: Set<OperationTask.Kind> = []
    /// 格式 / 扩展名范围(空 = 不限),匹配任务名里的「.<格式>」。
    @State private var aiFormat = ""
    /// 诊断标签范围(空 = 不限),来自 `ActivityTaskAIIndex` 的确定性失败分类。
    @State private var aiDiagnosticTags: Set<String> = []
    /// 当前 AI 筛选的原话(高亮按钮 tooltip 显示)。
    @State private var aiFilterQuery = ""
    /// 抽取**抛错** / 没抽到任何条件时的提示(气泡内);失败**绝不点亮按钮**(用户点名)。
    @State private var aiFilterError: String?

    /// 有任一非默认条件 = 生效(高亮 + 点按清空)。任意维度可同时叠加。
    private var aiFilterActive: Bool {
        !aiKeyword.isEmpty || aiWithinSeconds > 0 || aiStatus != .all || aiSource != nil
            || !aiKinds.isEmpty || !aiFormat.isEmpty || !aiDiagnosticTags.isEmpty
    }
    @AppStorage(AppPreferences.Key.activityHistoryLimit) private var historyLimit = AppPreferences.activityHistoryLimit
    @AppStorage(AppPreferences.Key.heavyTaskConcurrencyLimit) private var concurrencyLimit = AppPreferences.heavyTaskConcurrencyLimit
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiAssistantEnabled = true
    @State private var showsActivityAIWorkbench = true
    /// AI 工作台侧栏宽度(可拖拽调整,@AppStorage 跨会话记住)。范围 `aiWorkbenchWidthRange`。
    @AppStorage("SimpleZip.activity.aiWorkbenchWidth") private var aiWorkbenchWidth: Double = 240
    /// 拖拽起始宽度(松手清空)—— 避免用累计 translation 时反复叠加。
    @State private var aiWorkbenchDragStartWidth: Double?
    private let aiWorkbenchWidthRange: ClosedRange<Double> = 200...560
    /// 模块①:「打开完整 AI 解释」弹现成 per-task `AIAssistSheet`(完整解释)。
    @State private var showsWorkbenchFailureSheet = false
    /// 性能:任务列表只构建首屏 N 张卡(普通 VStack 一次性布局 ≤500 张会卡切 pane ~0.5s)。其余**不构建**
    /// (补全量那帧仍卡,还有 locate 时序风险 → 不补),底部「显示全部」按钮按需一次性展开。切 pane 重置回 N。
    @State private var taskRowLimit = 60
    private let initialTaskRowLimit = 60

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
        // ⚠️ render 热路径:本函数在一次 render 里被 taskCount / filteredTasks / 工作台多处反复调,
        // 活动中心 running 进度每秒多帧。**绝不能在这里做 AI 排序**(每次都 map aiTaskRecord 脱敏+正则、
        // 还要 parse 时间)——会严重卡顿。主列表保持轻量时间序(active 越新越上 + history)。
        // 主列表 AI 排序若要做,必须 per-task 烘焙一次缓存(任务终态不变),不在 render 路径重算。
        (taskCenter.active + taskCenter.history).filter { $0.category == category }
    }

    private var selectedPaneView: some View {
        Group {
            if selectedPane == .help {
                // 0.4.2：活动中心的「帮助」与「设置 → 帮助」同一个视图（A1：不重画）。
                HelpPane()
            } else if selectedPane == .workspace {
                // 0.4.4 #15:临时工作区(hero 头 + grouped Form,与设置 pane 同款骨架)。
                // #79:hero 与 Form 同装进一条钉宽 720 的列、整列居中 —— 宽窗/全屏下 Form 不再自己跑去居中、
                // 把 hero 甩在左上(用户报「活动中心工作区/设置也有同样错位」)。两者同宽同列,横向对齐。
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
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedPane == .settings {
                // 设置页用系统设置同款 grouped Form —— 自带滚动与顶部安全区处理，
                // 修掉「点设置后内容往上错位」（之前是裸 VStack，不像 List/Form 那样吃标题栏 inset）。
                // #17:顶部加同款 hero 头(Form 本体维持设置区已验收的原生样式)。
                // #79:同工作区 —— hero + Form 装进钉宽 720 的居中列,宽窗/全屏下两者一起居中、横向对齐。
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
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        // AI 入口统一收进右侧「AI 工作台」侧栏(NL 搜索 + 建议筛选都在那)。工具栏只留一个
                        // 「打开工作台」开关(关着时才出现);旧的工具栏 AI 搜索按钮已删,改挪进侧栏。
                        if aiAssistantEnabled && !showsActivityAIWorkbench {
                            Button {
                                showsActivityAIWorkbench = true
                            } label: {
                                Label(L10n.text("tasks.aiWorkbench.title"), systemImage: "sparkles")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .help(L10n.text("tasks.aiWorkbench.title"))
                        }
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

                    HStack(spacing: 0) {
                        taskList(in: category)
                        if aiAssistantEnabled && showsActivityAIWorkbench {
                            workbenchResizeHandle
                            ActivityAIWorkbenchView(
                                snapshot: activityAIWorkbenchSnapshot(for: category),
                                habits: workbenchHabits(for: category),
                                automationHint: workbenchAutomationHint(for: category),
                                searchText: $aiFilterText,
                                isRunningQuery: aiFilterRunning,
                                queryError: aiFilterError,
                                activeFilterSummary: aiFilterActive ? activeFilterSummary : nil,
                                aiExplanation: workbenchNeedsAttentionExplanation(in: category),
                                failureFocus: workbenchFailureFocus(in: category),
                                onRunQuery: { Task { await runAIFilter() } },
                                onClearFilter: clearAIFilter,
                                onApplyFilter: applyAIWorkbenchFilter,
                                onOpenTask: openWorkbenchTask,
                                onOpenFullFailureExplanation: { showsWorkbenchFailureSheet = true },
                                onNextAction: { performWorkbenchNextAction($0, in: category) },
                                onOpenAutomation: openShortcutsApp,
                                onClose: { showsActivityAIWorkbench = false }
                            )
                            .frame(width: CGFloat(aiWorkbenchWidth))
                            // 模块①:「打开完整 AI 解释」→ 复用现成 per-task AIAssistSheet + failureExplanationPrompt(完整解释,只读)。
                            .sheet(isPresented: $showsWorkbenchFailureSheet) {
                                workbenchFailureSheet(for: category)
                            }
                        }
                    }
                }
            }
        }
    }

    /// AI 工作台侧栏的可拖拽调宽手柄:细分隔线 + 8pt 命中区。手柄在侧栏左缘,向左拖 = 加宽(改 `aiWorkbenchWidth`)。
    private var workbenchResizeHandle: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = aiWorkbenchDragStartWidth ?? aiWorkbenchWidth
                                if aiWorkbenchDragStartWidth == nil { aiWorkbenchDragStartWidth = start }
                                aiWorkbenchWidth = min(
                                    max(start - Double(value.translation.width), aiWorkbenchWidthRange.lowerBound),
                                    aiWorkbenchWidthRange.upperBound)
                            }
                            .onEnded { _ in aiWorkbenchDragStartWidth = nil }
                    )
            )
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
            // 只构建首屏 N 张卡(避免 ≤500 张普通 VStack 一次性布局卡切 pane);其余不构建,底部按钮按需展开。
            let restLimit = min(rest.count, taskRowLimit)
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
                                                 onBecameVisible: { taskCenter.markFailureSeen(task) },
                                                 isHighlighted: highlightedTaskID == task.id)
                                    .id(task.id)
                            }
                            if !rest.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }
                        ForEach(Array(rest.prefix(restLimit))) { task in
                            ActivityTaskCard(task: task, expandedTaskIDs: $expandedTaskIDs, onOpenAttachment: { restoredReport = $0 },
                                                 viewportHeight: taskListViewportHeight,
                                                 onBecameVisible: { taskCenter.markFailureSeen(task) },
                                                 isHighlighted: highlightedTaskID == task.id)
                                .id(task.id)
                        }
                        // 其余任务不构建(切 pane 永远只布局首屏 N 张);按需一键展开全部。
                        if rest.count > restLimit {
                            Button {
                                taskRowLimit = rest.count
                            } label: {
                                Label(L10n.format("tasks.showAll", "\(rest.count)"), systemImage: "chevron.down")
                                    .font(.callout)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
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
                // #29:深链 / Spotlight 跳转请求定位到某条任务 —— 切到本分类后由 onAppear 兜,
                // 已在本分类时由 onChange 兜。两条都把请求消费掉再滚 + 高亮。
                .onChange(of: windowState.locateTaskID) { id in
                    locateTask(id, proxy: proxy)
                }
                .onAppear {
                    locateTask(windowState.locateTaskID, proxy: proxy)
                }
                // 切 pane 重置首屏上限(每个分类独立从 N 张起,不继承上个分类「显示全部」的状态)。
                .onChange(of: selectedPane) { _ in taskRowLimit = initialTaskRowLimit }
            }
        }
    }

    /// #29:消费 `windowState.locateTaskID`,把对应任务滚到中间并高亮一会儿。请求一来就清掉,避免重复触发;
    /// 列表里没这条(被筛掉 / 别的分类)→ scrollTo no-op,只是不高亮。延一拍等(可能刚切过来的)列表布局完。
    private func locateTask(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, windowState.locateTaskID == id else { return }
        windowState.locateTaskID = nil
        // 定位的任务可能在首屏 N 张之外(还没渲染)→ 先展开到全部,scrollTo 才找得到目标卡。
        taskRowLimit = .max
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            highlightedTaskID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if highlightedTaskID == id {
                    withAnimation(.easeInOut(duration: 0.4)) { highlightedTaskID = nil }
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
        let all = tasks(in: category)
        // #60:AI 筛选生效时,用 AI 抽出的条件**在代码里精确匹配**(手动状态/来源筛选此时让位;清空即恢复)。
        if aiFilterActive {
            let keyword = aiKeyword
            let cutoff = aiWithinSeconds > 0 ? Date().addingTimeInterval(-aiWithinSeconds) : nil
            let before = aiTimeBefore
            let formatNeedle = aiFormat.isEmpty ? nil : "." + aiFormat.lowercased()
            return all.filter { task in
                guard aiStatus.includes(task) else { return false }
                if let aiSource, task.source != aiSource { return false }
                if !aiKinds.isEmpty, !aiKinds.contains(task.kind) { return false }
                if let formatNeedle, !task.title.lowercased().contains(formatNeedle) { return false }
                if !aiDiagnosticTags.isEmpty {
                    let tags = Set(task.aiTaskRecord.diagnostics.tags)
                    if tags.isDisjoint(with: aiDiagnosticTags) { return false }
                }
                if !keyword.isEmpty {
                    let inTitle = task.title.localizedCaseInsensitiveContains(keyword)
                    let inDetail = task.detail?.localizedCaseInsensitiveContains(keyword) ?? false
                    if !inTitle && !inDetail { return false }
                }
                if let cutoff {
                    // within = 晚于 cutoff(更近);before = 早于 cutoff(更老)。
                    if before ? (task.startedAt >= cutoff) : (task.startedAt < cutoff) { return false }
                }
                return true
            }
        }
        let filter = filter(for: category)
        return all.filter { filter.includes($0) && (sourceFilter == nil || $0.source == sourceFilter) }
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

    // #60 的工具栏 AI 筛选按钮已删:NL 搜索 + 生效筛选 + 清除都挪进右侧「AI 工作台」侧栏
    // (见 ActivityAIWorkbenchView 的 search 区);`runAIFilter` / `clearAIFilter` / 筛选状态保留,由侧栏驱动。

    /// AI 把短语抽成精确条件 → App 确定性应用。抽不到任何条件 / 抛错 → 不点亮 + 气泡提示(用户点名)。
    @MainActor
    private func runAIFilter() async {
        let query = aiFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !aiFilterRunning else { return }
        guard #available(macOS 26.0, *) else { return }
        aiFilterRunning = true
        aiFilterError = nil
        defer { aiFilterRunning = false }
        do {
            let spec = try await AIReportAssistant.activityFilterSpec(for: query)
            // 分类字段现在是 @Generable 枚举,模型被硬约束只能吐合法 token —— 直接 switch,无需容错字符串解析。
            let status: ActivityTaskFilter
            switch spec.status {
            case .all: status = .all
            case .running: status = .running
            case .succeeded: status = .succeeded
            case .failed: status = .failed
            case .cancelled: status = .cancelled
            }
            let source: OperationTask.Source?
            switch spec.source {
            case .any: source = nil
            case .app: source = .app
            case .cli: source = .cli
            case .intent: source = .intent
            case .urlScheme: source = .urlScheme
            case .finder: source = .finder
            }
            let kind: OperationTask.Kind? = spec.kind == .any ? nil : OperationTask.Kind(rawValue: spec.kind.rawValue)
            let keyword = spec.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            // 格式容错:模型可能给「any」(意为不限)或通用词 / 非拉丁(如「压缩包」)—— 都不当成扩展名。
            // 只认拉丁字母数字(允许内部「.」如 tar.gz)的短后缀。
            let rawFormat = spec.format.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            let isExtension = !rawFormat.isEmpty && rawFormat != "any" && rawFormat != "none"
                && rawFormat.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
            let format = isExtension ? rawFormat : ""
            // 单位换算在代码里做(模型只给「数值 + 单位」枚举,不让它算)。
            let unitSeconds: TimeInterval
            switch spec.timeUnit {
            case .none: unitSeconds = 0
            case .seconds: unitSeconds = 1
            case .minutes: unitSeconds = 60
            case .hours: unitSeconds = 3600
            case .days: unitSeconds = 86_400
            case .weeks: unitSeconds = 604_800
            case .months: unitSeconds = 2_592_000      // ~30 天
            case .years: unitSeconds = 31_536_000      // ~365 天
            }
            let seconds = max(0, spec.timeValue) * unitSeconds
            let before = spec.timeDirection == .before
            // 一个条件都没抽到 → 不点亮,提示重述。
            guard !keyword.isEmpty || seconds > 0 || status != .all || source != nil
                    || kind != nil || !format.isEmpty else {
                aiFilterError = L10n.text("tasks.aiFilter.failed")
                return
            }
            aiKeyword = keyword
            aiWithinSeconds = seconds
            aiTimeBefore = before
            aiStatus = status
            aiSource = source
            aiKinds = kind.map { [$0] } ?? []
            aiFormat = format
            aiDiagnosticTags = []
            aiFilterQuery = query
            aiFilterText = ""
        } catch {
            aiFilterError = L10n.text("tasks.aiFilter.failed")
        }
    }

    /// 清空 AI 临时分类 —— 条件全复位即恢复手动筛选视图(用户点高亮的 AI 按钮触发)。
    private func clearAIFilter() {
        aiKeyword = ""
        aiWithinSeconds = 0
        aiTimeBefore = false
        aiStatus = .all
        aiSource = nil
        aiKinds = []
        aiFormat = ""
        aiDiagnosticTags = []
        aiFilterQuery = ""
        aiFilterError = nil
    }

    /// 高亮按钮的 tooltip:当前 AI 筛选的原话。
    private var activeFilterSummary: String {
        "“\(aiFilterQuery)”"
    }

    private func activityAIWorkbenchSnapshot(for category: OperationTask.Category) -> ActivityAIWorkbenchSnapshot {
        // 性能:工作台只喂前 N 个任务的 record(builder 候选上限 50;只 map 这些 → 切 pane 不再全量算
        // 500 个 aiTaskRecord 的脱敏+正则)。配合 aiTaskRecord 烘焙缓存,切 pane 的两个 O(N) 源都被限住。
        let base = ActivityAIWorkbenchBuilder.snapshot(records: Array(filteredTasksForWorkbench(in: category).prefix(80)).map(\.aiTaskRecord))
        let ranked = applyAIChipRanking(to: base, category: category)
        return applyAIClusterChips(to: ranked, category: category)
    }

    /// 建议六 v2「学习到的习惯」:从近期任务(前 80,aiTaskRecord 缓存)确定性算常用来源 / 格式 / 位置摘要。
    /// 不调模型、只摘要(无完整路径);前台 View 渲染。
    private func workbenchHabits(for category: OperationTask.Category) -> ActivityWorkbenchHabits {
        ActivityAIWorkbenchBuilder.habitSummary(
            records: Array(filteredTasksForWorkbench(in: category).prefix(80)).map(\.aiTaskRecord))
    }

    /// 建议六 v2「自动化建议」:近期任务(前 80)里手动操作的稳定重复 → 提示自动化。确定性,不调模型。
    private func workbenchAutomationHint(for category: OperationTask.Category) -> ActivityWorkbenchAutomationHint? {
        guard aiAssistantEnabled else { return nil }
        return ActivityAIWorkbenchBuilder.automationHint(
            records: Array(filteredTasksForWorkbench(in: category).prefix(80)).map(\.aiTaskRecord))
    }

    /// 自动化建议:打开系统「快捷指令」app(用户自行创建工作流;SimpleZip 不代建)。
    private func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 建议六 v2「真建议」:把后台预烘焙的 AI 命名聚集 chip 叠加到「建议筛选」最前(模型命名的真实聚集),
    /// 写死 chip 退到后面作兜底(filter 相同的去重 —— 同一筛选不重复冒)。只读缓存,不在前台跑发现 / 模型。
    /// 无缓存 / AI 关 → 原样返回(纯写死 chip)。chip 携带 displayName(前台直接显示模型起的名字)。
    private func applyAIClusterChips(to snapshot: ActivityAIWorkbenchSnapshot,
                                     category: OperationTask.Category) -> ActivityAIWorkbenchSnapshot {
        guard aiAssistantEnabled,
              let cached = aiIndexStore.workbenchClusterChips(forCategory: category.rawValue),
              !cached.chips.isEmpty else { return snapshot }
        let aiChips = cached.chips.map { chip in
            ActivityAIWorkbenchFilterChip(id: chip.id, filter: chip.filter,
                                          facts: ["matches=\(chip.matchCount)"], displayName: chip.displayName)
        }
        let aiKeys = Set(aiChips.map { chipFilterKey($0.filter) })
        let leftover = snapshot.filterChips.filter { !aiKeys.contains(chipFilterKey($0.filter)) }
        let merged = aiChips + leftover
        guard merged != snapshot.filterChips else { return snapshot }
        return ActivityAIWorkbenchSnapshot(
            schema: snapshot.schema, summary: snapshot.summary, cards: snapshot.cards,
            filterChips: merged, omissions: snapshot.omissions)
    }

    /// 两个 chip 是否指向同一筛选(用于去重写死 chip 与 AI 聚集 chip)。
    private func chipFilterKey(_ f: ActivityAIWorkbenchFilterSpec) -> String {
        "\(f.status ?? "")|\(f.source ?? "")|\(f.kindTokens.sorted().joined(separator: "+"))|\(f.diagnosticTags.sorted().joined(separator: "+"))"
    }

    /// 建议六 v2 模块⑤:把后台预烘焙的 AI chip 排序套到确定性 snapshot 上 —— **指纹匹配当前 chip 池才套**(否则
    /// 保持确定性顺序 = fallback;有筛选时池不同 → 自然走确定性)。AI 选中的在前(按模型给的优先级),没提到的接在后面
    /// (不丢任何 chip,只改顺序 / 把最有用的顶上来)。拒绝假AI:没缓存 / 不匹配 → 确定性。
    private func applyAIChipRanking(to snapshot: ActivityAIWorkbenchSnapshot,
                                    category: OperationTask.Category) -> ActivityAIWorkbenchSnapshot {
        guard aiAssistantEnabled,
              let ranking = aiIndexStore.workbenchChipRanking(forCategory: category.rawValue),
              ranking.fingerprint == AIBackgroundIndexer.chipPoolFingerprint(snapshot.filterChips) else { return snapshot }
        let byID = Dictionary(snapshot.filterChips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = ranking.orderedIDs.compactMap { byID[$0] }
        guard !ranked.isEmpty else { return snapshot }
        let rankedSet = Set(ranking.orderedIDs)
        let leftover = snapshot.filterChips.filter { !rankedSet.contains($0.id) }
        let reordered = ranked + leftover
        guard reordered != snapshot.filterChips else { return snapshot }
        return ActivityAIWorkbenchSnapshot(
            schema: snapshot.schema, summary: snapshot.summary, cards: snapshot.cards,
            filterChips: reordered, omissions: snapshot.omissions)
    }

    /// 建议六 v2 模块1:活动中心「需要处理」卡的 AI 解读 —— **只读后台预烘焙缓存**(META#2:工作台 AI 永远后台预烘焙 +
    /// 幂等 + 前台只读,绝不前台触发模型)。指纹匹配当前未读失败集才用(否则 nil → 卡片退确定性计数文案);有筛选时
    /// 指纹自然不匹配 → 走确定性。后台 pass = `generateWorkbenchNeedsAttentionIfEnabled`。
    private func workbenchNeedsAttentionExplanation(in category: OperationTask.Category) -> String? {
        guard aiAssistantEnabled,
              let cached = aiIndexStore.workbenchNeedsAttentionExplanation(forCategory: category.rawValue) else { return nil }
        let records = filteredTasksForWorkbench(in: category).map(\.aiTaskRecord)
        let fingerprint = AIBackgroundIndexer.needsAttentionFingerprint(records)
        guard !fingerprint.isEmpty, cached.fingerprint == fingerprint, !cached.text.isEmpty else { return nil }
        return cached.text
    }

    /// 建议六 v2 模块①:当前「焦点失败任务」= 当前分类里被**展开**的失败任务中最新的一个(展开 = 用户正在看它,
    /// 复用现有交互,不给卡片加新选择 UI)。没有展开的失败任务 → nil。
    private func focusedWorkbenchFailure(in category: OperationTask.Category) -> OperationTask? {
        filteredTasksForWorkbench(in: category)
            .filter { task in
                guard expandedTaskIDs.contains(task.id) else { return false }
                if case .failed = task.status { return true }
                return false
            }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }

    /// 模块①:给工作台侧栏的失败解释焦点数据(确定性脱敏摘要永远在 + 模型短解释 + 是否能打开完整解释)。
    private func workbenchFailureFocus(in category: OperationTask.Category) -> ActivityWorkbenchFailureFocus? {
        guard aiAssistantEnabled, let task = focusedWorkbenchFailure(in: category) else { return nil }
        let canOpenFull: Bool
        if #available(macOS 26.0, *) { canOpenFull = AIReportAssistant.isReady } else { canOpenFull = false }
        return ActivityWorkbenchFailureFocus(
            taskTitle: task.title,
            deterministicSummary: deterministicFailureSummary(for: task.aiTaskRecord),
            aiExplanation: cachedFailureExplanation(for: task),
            canOpenFull: canOpenFull,
            nextActions: availableNextActions(for: task))
    }

    /// 模块①:焦点失败任务的「失败解释」短文案 —— **只读后台预烘焙缓存**(META#2:永远后台预烘焙 + 幂等 + 前台只读)。
    /// 指纹匹配该任务当前脱敏失败诊断才用(否则 nil → 退回确定性脱敏摘要)。后台 pass = `generateWorkbenchFailureExplanationsIfEnabled`。
    private func cachedFailureExplanation(for task: OperationTask) -> String? {
        let record = task.aiTaskRecord
        guard let cached = aiIndexStore.workbenchFailureExplanation(forTask: record.id),
              cached.fingerprint == AIBackgroundIndexer.failureExplanationFingerprint(record),
              !cached.text.isEmpty else { return nil }
        return cached.text
    }

    /// 模块②:焦点失败任务上**确定性可用**的后续动作(按任务自身闭包是否存在,App 安全枚举,AI 不发明)。
    private func availableNextActions(for task: OperationTask) -> [WorkbenchNextAction] {
        var actions: [WorkbenchNextAction] = []
        if task.openReport != nil || task.reportAttachment != nil { actions.append(.openReport) }
        if task.resumeFromFailure != nil { actions.append(.resumeFromFailure) }
        if task.rerun != nil { actions.append(.rerun) }
        if task.rerunWithChanges != nil { actions.append(.rerunWithChanges) }
        // 复制诊断永远可用:从脱敏的 AITaskRecord 拼一段可粘贴文本(无原始路径 / 已抓 secret)。
        actions.append(.copyDiagnostics)
        return actions
    }

    /// 模块②:把侧栏点的「下一步动作」路由回焦点失败任务自身的闭包,或做只读复制。**只走任务已有的安全动作。**
    private func performWorkbenchNextAction(_ action: WorkbenchNextAction, in category: OperationTask.Category) {
        guard let task = focusedWorkbenchFailure(in: category) else { return }
        switch action {
        case .openReport:
            task.openReport?()
        case .resumeFromFailure:
            task.resumeFromFailure?()
        case .rerun:
            task.rerun?()
        case .rerunWithChanges:
            task.rerunWithChanges?()
        case .copyDiagnostics:
            copyFocusedDiagnostics(task)
        }
    }

    /// 模块②「复制诊断」:从**已脱敏**的 `AITaskRecord` 拼一段纯文本(标题 + 类型/来源/状态 + 脱敏失败消息 + 脱敏错误行),
    /// 适合粘进 issue / 笔记。不含原始路径,secret 已被 redact 抓掉。
    private func copyFocusedDiagnostics(_ task: OperationTask) {
        let record = task.aiTaskRecord
        var lines = [task.title, "\(record.kind) · \(record.source) · \(record.status)"]
        if let message = record.diagnostics.failureMessage, !message.isEmpty { lines.append(message) }
        lines.append(contentsOf: record.diagnostics.errorLines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// 确定性失败摘要(模块①的 fallback):优先脱敏失败消息,其次诊断标签,再不济通用文案。**全部已脱敏,无原始路径。**
    private func deterministicFailureSummary(for record: AITaskRecord) -> String {
        if let message = record.diagnostics.failureMessage, !message.isEmpty { return message }
        if !record.diagnostics.tags.isEmpty { return record.diagnostics.tags.joined(separator: ", ") }
        return L10n.text("tasks.aiWorkbench.failureExplanation.fallback")
    }

    /// 模块①:「打开完整 AI 解释」弹的 sheet —— 复用现成 per-task `AIAssistSheet` + `failureExplanationPrompt`(完整解释,
    /// 只读,与卡片上的「解释失败」按钮同一条路径)。焦点失败任务在 sheet 打开期间用其实时态读 rawOutput。
    @ViewBuilder
    private func workbenchFailureSheet(for category: OperationTask.Category) -> some View {
        if let task = focusedWorkbenchFailure(in: category), case .failed(let message) = task.status {
            AIAssistSheet(
                title: L10n.text("ai.explainFailure.title"),
                subtitle: task.title,
                systemImage: "sparkles"
            ) {
                guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                let built = AIReportAssistant.failureExplanationPrompt(
                    taskTitle: task.title,
                    failureMessage: message,
                    output: task.detailsSession?.rawOutput)
                return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
            }
        }
    }

    private func filteredTasksForWorkbench(in category: OperationTask.Category) -> [OperationTask] {
        let all = tasks(in: category)
        let filter = filter(for: category)
        return all.filter { filter.includes($0) && (sourceFilter == nil || $0.source == sourceFilter) }
    }

    private func applyAIWorkbenchFilter(_ chip: ActivityAIWorkbenchFilterChip) {
        aiKeyword = ""
        aiWithinSeconds = 0
        aiTimeBefore = false
        aiStatus = activityFilter(from: chip.filter.status)
        aiSource = chip.filter.source.flatMap(OperationTask.Source.init(rawValue:))
        aiKinds = Set(chip.filter.kindTokens.compactMap(OperationTask.Kind.init(rawValue:)))
        aiFormat = ""
        aiDiagnosticTags = Set(chip.filter.diagnosticTags)
        aiFilterQuery = L10n.text("tasks.aiWorkbench.chip.\(chip.id)")
        aiFilterError = nil
    }

    private func activityFilter(from rawStatus: String?) -> ActivityTaskFilter {
        switch rawStatus {
        case "running": return .running
        case "succeeded", "skipped": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return .all
        }
    }

    private func openWorkbenchTask(_ id: String) {
        guard let uuid = UUID(uuidString: id),
              let task = (taskCenter.active + taskCenter.history).first(where: { $0.id == uuid }) else { return }
        windowState.locate(taskID: uuid, category: task.category)
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

                // 0.4.4 #10:长任务完成后发系统通知(默认关;打开时请求授权,把系统提示绑在 opt-in 上)。
                SettingsControlRow(
                    title: L10n.text("tasks.settings.notify"),
                    description: L10n.text("tasks.settings.notify.description"),
                    systemImage: "bell.badge",
                    iconTint: .orange
                ) {
                    Toggle("", isOn: $notifyOnFinish)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: notifyOnFinish) { isOn in
                            if isOn { TaskCompletionNotifier.requestAuthorization() }
                        }
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
    /// 0.4.4 #10:长任务完成后发系统通知(默认关)。
    @AppStorage(AppPreferences.Key.tasksNotifyOnFinish) private var notifyOnFinish = false
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

    /// #31:Spotlight 路由用的稳定字符串 → 分页。只有可被索引的 settings / workspace 两页需要。
    static func pane(spotlightRouteKey key: String) -> ActivityPane? {
        switch key {
        case "settings": return .settings
        case "workspace": return .workspace
        default: return nil
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
    /// #29:要滚到并高亮的任务 id(深链 / Spotlight 跳转设它;ActivityView 消费后清空)。只在显式定位时变,
    /// 不在 reload 路径上动 —— 不会引发 A17 的菜单栏抖动。
    @Published var locateTaskID: UUID?

    func select(category: OperationTask.Category) {
        selectedPane = ActivityPane.pane(for: category)
    }

    /// 切到任务所在分类并请求滚动定位 + 高亮。
    func locate(taskID: UUID, category: OperationTask.Category) {
        selectedPane = ActivityPane.pane(for: category)
        locateTaskID = taskID
    }
}

extension OperationTask {
    /// 任务 → AI 任务记录(脱敏派生)。供活动中心 AI 工作台**和** #89 后台发现编排者(AIWorkspaceDiscoveryCoordinator)
    /// 复用。内部辅助仍 file-private。
    var aiTaskRecord: AITaskRecord {
        // 烘焙一次缓存:终态任务 key 稳定 → 命中,不再每帧脱敏+正则(修活动中心切 pane / 滚动卡顿)。
        let key = aiRecordCacheKey
        if let cache = aiRecordCache, cache.key == key { return cache.record }
        let record = AITaskRecord.make(
            id: id.uuidString,
            category: category.rawValue,
            kind: kind.rawValue,
            source: source.rawValue,
            status: aiStatusToken,
            title: title,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outputPaths: aiOutputPaths,
            failureMessage: aiFailureMessage,
            rawOutput: detailsSession?.rawOutput,
            canRerun: rerun != nil,
            canRerunWithChanges: rerunWithChanges != nil,
            canResumeFromFailure: resumeFromFailure != nil,
            skippedReason: aiSkippedReason,
            failureSeen: failureSeen,
            awaitedConcurrencySlot: isAwaitingSlot)
        aiRecordCache = (key, record)
        return record
    }

    /// `aiTaskRecord` 缓存指纹:涵盖派生依赖的可变字段(状态 case + 关联值规模、完成时间、已读、等槽)。
    /// 终态后稳定 → 命中;running → 终态时 status/finishedAt 变 → key 变 → 重算一次拿终态。
    /// (running 期间 rawOutput 累积不进 key —— running 任务不进失败诊断,stale 无害;终态时必重算拿最终输出。)
    private var aiRecordCacheKey: String {
        var key = "\(aiStatusToken)|\(finishedAt?.timeIntervalSince1970 ?? -1)|\(failureSeen)|\(isAwaitingSlot)"
        switch status {
        case .failed(let message): key += "|F\(message.count)"
        case .succeeded(let url): key += "|S\(url?.path.count ?? 0)"
        case .skipped(let reason): key += "|K\(reason?.count ?? 0)"
        default: break
        }
        return key
    }

    private var aiStatusToken: String {
        switch status {
        case .running:
            return "running"
        case .succeeded:
            return "succeeded"
        case .skipped:
            return "skipped"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }

    private var aiFailureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private var aiSkippedReason: String? {
        if case .skipped(let reason) = status { return reason }
        return nil
    }

    private var aiOutputPaths: [String] {
        if case .succeeded(let url) = status, let url { return [url.path] }
        return []
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
    /// #29:被深链 / Spotlight 跳转命中时闪一圈强调色边框。
    var isHighlighted = false
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
        // #29:深链 / Spotlight 跳转定位到本卡 → 闪一圈强调色边框(纯静态描边,不挂动画,符合活动中心防抖规则)。
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .allowsHitTesting(false)
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
