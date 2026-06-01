//
//  ActivityView.swift
//  SimpleZip
//

import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter
    @State private var selectedPane = ActivityPane.archive
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
                        selectedPane = pane
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
        Form {
            Section(L10n.text("tasks.settings.history")) {
                SettingsControlRow(
                    title: L10n.text("tasks.settings.historyLimit"),
                    description: L10n.text("tasks.settings.historyLimit.description")
                ) {
                    Stepper(value: $historyLimit, in: 1...500) {
                        Text(L10n.format("tasks.settings.historyLimit.value", historyLimit))
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                    .onChange(of: historyLimit) { newValue in
                        AppPreferences.activityHistoryLimit = newValue
                        taskCenter.applyHistoryLimitChange()
                    }
                }

                SettingsActionRow(
                    title: L10n.text("tasks.settings.clearHistory"),
                    description: L10n.text("tasks.settings.clearHistory.description"),
                    systemImage: "trash",
                    buttonTitle: L10n.text("tasks.settings.clearHistory.button"),
                    role: .destructive,
                    isDisabled: taskCenter.history.isEmpty
                ) {
                    taskCenter.clearHistory()
                }
            }
        }
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
}

private enum ActivityPane: CaseIterable, Identifiable, Hashable {
    case archive
    case fileOperation
    case settings

    var id: Self { self }

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
            if case .succeeded = task.status { return true }
            return false
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if task.status.isRunning, task.cancel != nil {
                    Button(L10n.text("button.cancel")) {
                        task.cancel?()
                    }
                    .buttonStyle(.borderless)
                }
                if task.detailsSession != nil {
                    Button(L10n.text("button.details")) {
                        isShowingDetails.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if task.status.isRunning {
                if let fraction = task.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if isShowingDetails, let session = task.detailsSession {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.text("details.commandOutput"))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button(L10n.text("button.copyDiagnostics")) {
                            Task {
                                await DiagnosticsCopier.copy(session: session, errorMessage: errorMessage)
                                withAnimation { showsCopiedConfirmation = true }
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                withAnimation { showsCopiedConfirmation = false }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    if showsCopiedConfirmation {
                        Text(L10n.text("diagnostics.copied"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    CommandOutputLogView(text: session.rawOutput.isEmpty ? L10n.text("details.waiting") : session.rawOutput)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch task.kind {
        case .extract:
            return "tray.and.arrow.down"
        case .compress:
            return "doc.zipper"
        case .test:
            return "checkmark.seal"
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
        case .failed:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .running:
            if let statusText = task.progress.statusText, !statusText.isEmpty {
                return statusText
            }
            if let currentFile = task.progress.currentFile, !currentFile.isEmpty {
                return currentFile
            }
            return L10n.text("tasks.running")
        case .succeeded:
            return L10n.text("status.done")
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
}
