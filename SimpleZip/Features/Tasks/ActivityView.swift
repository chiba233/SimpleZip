//
//  ActivityView.swift
//  SimpleZip
//

import Combine
import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter
    @ObservedObject var windowState: ActivityWindowState
    @State private var isSidebarVisible = true
    @State private var archiveFilter = ActivityTaskFilter.all
    @State private var fileFilter = ActivityTaskFilter.all
    @AppStorage(AppPreferences.Key.activityHistoryLimit) private var historyLimit = AppPreferences.activityHistoryLimit

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                activitySidebar
                Divider()
            }

            ZStack(alignment: .topLeading) {
                selectedPaneView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isSidebarVisible {
                    sidebarToggleButton(systemImage: "sidebar.leading") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isSidebarVisible = true
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.top, 10)
                }
            }
        }
        .frame(
            minWidth: 620, idealWidth: 760, maxWidth: .infinity,
            minHeight: 420, idealHeight: 540, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("tasks.window.title"))
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
            .padding(.leading, isSidebarVisible ? 0 : 34)

            if selectedPane == .settings {
                activitySettingsView
            } else if let category = selectedPane.category {
                List {
                    taskRows(tasks: filteredTasks(in: category))
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }

    private var activitySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                sidebarToggleButton(systemImage: "sidebar.left") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isSidebarVisible = false
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(ActivityPane.allCases) { pane in
                    ActivityPaneSidebarButton(
                        pane: pane,
                        count: pane.category.map(taskCount(in:)),
                        isSelected: selectedPane == pane
                    ) {
                        windowState.selectedPane = pane
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(width: 178)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.bar)
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

            activitySettingsRow(
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

            activitySettingsRow(
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
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
    }

    private func activitySettingsRow<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            control()
        }
        .padding(.vertical, 3)
    }

    private func sidebarToggleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(L10n.text("tasks.window.title"))
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

private struct ActivityPaneSidebarButton: View {
    let pane: ActivityPane
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
        .help(pane.title)
    }
}

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

private struct ActivityTaskRow: View {
    @ObservedObject var task: OperationTask
    @State private var isShowingDetails = false
    @State private var showsCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer()

                trailingControls
            }

            if task.status.isRunning {
                if let fraction = task.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if isShowingDetails, hasDetails {
                if let report = task.hashReport {
                    hashResultDetails(report)
                } else if !task.hashComparisons.isEmpty {
                    hashComparisonDetails(task.hashComparisons)
                } else if let session = task.detailsSession {
                    commandOutputDetails(session)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// 哈希任务详情：复用「文件哈希」弹窗的同一套格式化卡片（HashResultCard），不画文本日志。
    @ViewBuilder
    private func hashResultDetails(_ report: HashReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainTextSummary, forType: .string)
                    withAnimation { showsCopiedConfirmation = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.copyAll"))
            }
            if showsCopiedConfirmation {
                Text(L10n.text("diagnostics.copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(report.results) { result in
                        HashResultCard(report: report, result: result)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 16)   // 预留竖向滚动条宽度，避免盖住右侧长哈希值
            }
            .frame(maxHeight: 280)
        }
    }

    /// 粘贴 / 移动覆盖前的哈希比对详情：每项一张格式化卡片（源哈希 vs 目标哈希 + 跳过/覆盖结果）。
    @ViewBuilder
    private func hashComparisonDetails(_ comparisons: [HashOverwriteResult]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(detailsHeaderTitle)
                .font(.caption.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(comparisons.enumerated()), id: \.offset) { _, result in
                        HashComparisonCard(result: result)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 16)   // 预留竖向滚动条宽度，避免盖住右侧长哈希值
            }
            .frame(maxHeight: 280)
        }
    }

    /// 后端命令详情：实时命令输出文本日志（解压 / 压缩 / 测试）。
    @ViewBuilder
    private func commandOutputDetails(_ session: ArchiveOperationDetailsSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(detailsHeaderTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await DiagnosticsCopier.copy(session: session, errorMessage: errorMessage)
                        withAnimation { showsCopiedConfirmation = true }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showsCopiedConfirmation = false }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.copyDiagnostics"))
            }
            if showsCopiedConfirmation {
                Text(L10n.text("diagnostics.copied"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CommandOutputLogView(text: session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                .frame(height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 6) {
            if task.status.isRunning, task.cancel != nil {
                Button {
                    task.cancel?()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.cancel"))
            }
            // 只有「真有内容可看」时才给详情入口：归档操作运行中（命令输出随时来）或任何已积累了输出/
            // 哈希信息的任务。这样文件操作平平无奇的复制/移动不再出空面板，失败的也不再卡「正在等待命令输出…」，
            // 而哈希结果 / 粘贴时的源·目标哈希这类有用信息照样能展开看。
            if hasDetails {
                Button {
                    isShowingDetails.toggle()
                } label: {
                    Image(systemName: isShowingDetails ? "chevron.up.circle" : "info.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("button.details"))
            }
        }
        .foregroundStyle(.secondary)
    }

    private var iconName: String {
        switch task.kind {
        case .extract:
            return "tray.and.arrow.down"
        case .compress:
            return "doc.zipper"
        case .test:
            return "checkmark.seal"
        case .benchmark:
            return "speedometer"
        case .hash:
            return "number.square"
        case .paste, .copy:
            return "doc.on.doc"
        case .move:
            return "folder.badge.gearshape"
        case .duplicate:
            return "plus.square.on.square"
        case .delete:
            return "trash"
        case .rename:
            return "pencil"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .running:
            return .accentColor
        case .succeeded:
            return .green
        case .skipped:
            // 不用绿色：跳过 = 没改动，绿色会让用户误以为覆盖/写入成功了。用中性灰区分。
            return .secondary
        case .failed:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .running:
            if let detail = task.detail, !detail.isEmpty {
                return detail
            }
            if let statusText = task.progress.statusText, !statusText.isEmpty {
                return statusText
            }
            if let currentFile = task.progress.currentFile, !currentFile.isEmpty {
                return currentFile
            }
            return L10n.text("tasks.running")
        case .succeeded:
            if let detail = task.detail, !detail.isEmpty {
                return detail
            }
            return L10n.text("status.done")
        case .skipped(let reason):
            return reason ?? L10n.text("tasks.fileOperation.skipped.noChange")
        case .failed(let message):
            return message
        case .cancelled:
            return L10n.text("status.cancelled")
        }
    }

    private var errorMessage: String? {
        if case .failed(let message) = task.status {
            return message
        }
        return nil
    }

    /// 是否给这条任务展示「详情」入口/面板。
    /// - 归档操作运行中：允许（后端命令输出会陆续来，先开着看实时输出）。
    /// - 其它情况：仅当 detailsSession 已有内容（哈希结果 / 粘贴的源·目标哈希等）。
    ///   平凡的复制/移动 + 失败任务都没有内容 → 不出空面板，也不再卡「正在等待命令输出…」。
    private var hasDetails: Bool {
        // 哈希任务 / 粘贴·移动的哈希比对：有结构化结果就给详情入口（格式化卡片）。
        if task.hashReport != nil { return true }
        if !task.hashComparisons.isEmpty { return true }
        guard let session = task.detailsSession else { return false }
        // 真·后端命令（解压/压缩/测试）运行中就允许展开看实时输出；其余只在已有内容时给入口。
        if isBackendCommand, task.status.isRunning { return true }
        return !session.rawOutput.isEmpty
    }

    /// 该任务是否跑了真正的后端命令（其详情才是「命令输出」）。哈希结果 / 文件操作的哈希对比不是命令输出。
    private var isBackendCommand: Bool {
        task.category == .archive && task.kind != .hash
    }

    /// 详情面板标题：后端命令 → 「命令输出」；哈希结果 / 文件哈希对比 → 「结果」（避免把哈希信息错叫成命令输出）。
    private var detailsHeaderTitle: String {
        isBackendCommand ? L10n.text("details.commandOutput") : L10n.text("details.results")
    }
}

/// 粘贴 / 移动覆盖前「源 vs 目标」哈希比对的格式化卡片（活动中心详情用）。
/// 风格对齐「文件哈希」弹窗的 HashResultCard：文件名 + 路径 + 哈希行 + 跳过/覆盖状态。
private struct HashComparisonCard: View {
    let result: HashOverwriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.sourceURL.lastPathComponent, systemImage: "doc")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusLabel
            }

            Text(result.targetURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Text(L10n.text("hashCompare.sourceHash"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(result.sourceHash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
                GridRow {
                    Text(L10n.text("hashCompare.targetHash"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(result.targetHash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        Label(
            result.isSame
                ? L10n.text("tasks.fileOperation.hashDetail.skipped")
                : L10n.text("tasks.fileOperation.hashDetail.overwritten"),
            systemImage: result.isSame ? "equal.circle" : "arrow.triangle.2.circlepath"
        )
        .font(.caption)
        .foregroundStyle(result.isSame ? Color.secondary : Color.orange)
    }
}
