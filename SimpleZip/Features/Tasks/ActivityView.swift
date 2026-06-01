//
//  ActivityView.swift
//  SimpleZip
//

import SwiftUI

struct ActivityView: View {
    @ObservedObject var taskCenter: TaskCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("tasks.window.title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                if taskCenter.runningCount > 0 {
                    Button(L10n.text("tasks.cancelAll")) {
                        taskCenter.cancelAll()
                    }
                }
            }

            List {
                taskSection(
                    title: L10n.text("tasks.archiveSection"),
                    tasks: tasks(in: .archive)
                )
                taskSection(
                    title: L10n.text("tasks.fileSection"),
                    tasks: tasks(in: .fileOperation)
                )
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
    }

    private func tasks(in category: OperationTask.Category) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.category == category }
    }

    @ViewBuilder
    private func taskSection(title: String, tasks: [OperationTask]) -> some View {
        Section(title) {
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
