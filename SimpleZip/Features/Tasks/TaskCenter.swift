//
//  TaskCenter.swift
//  SimpleZip
//

import Combine
import Foundation

@MainActor
final class TaskCenter: ObservableObject {
    static let shared = TaskCenter()

    @Published private(set) var active: [OperationTask] = []
    @Published private(set) var history: [OperationTask] = []

    private var historyLimit: Int {
        AppPreferences.activityHistoryLimit
    }

    init() {
        history = Self.loadPersistedHistory()
        trimHistoryToLimit()
    }

    var runningCount: Int {
        active.count
    }

    var primaryActiveCategory: OperationTask.Category? {
        active.first?.category
    }

    var aggregateFraction: Double? {
        let fractions = active.compactMap(\.progress.fraction)
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    var primaryProgressText: String? {
        active.lazy.compactMap { task -> String? in
            if let statusText = task.progress.statusText, !statusText.isEmpty {
                return statusText
            }
            if let currentFile = task.progress.currentFile, !currentFile.isEmpty {
                return currentFile
            }
            return nil
        }.first
    }

    @discardableResult
    func begin(
        category: OperationTask.Category,
        kind: OperationTask.Kind,
        title: String,
        detail: String? = nil,
        cancellable: Bool,
        detailsSession: ArchiveOperationDetailsSession? = nil,
        operationID: UUID? = nil
    ) -> OperationTask {
        let task = OperationTask(
            category: category,
            kind: kind,
            title: title,
            detail: detail,
            cancellable: cancellable,
            detailsSession: detailsSession,
            operationID: operationID
        )
        active.append(task)
        return task
    }

    func finish(_ task: OperationTask, outcome: OperationTask.Status) {
        guard let index = active.firstIndex(where: { $0.id == task.id }) else { return }
        let finishedTask = active.remove(at: index)
        finishedTask.status = outcome
        finishedTask.finishedAt = Date()
        finishedTask.detailsSession?.finishedAt = finishedTask.finishedAt
        history.insert(finishedTask, at: 0)
        trimHistoryToLimit()
        persistHistory()
    }

    func cancelAll() {
        for task in active {
            task.cancel?()
        }
    }

    func notifyTaskChanged() {
        objectWillChange.send()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    func applyHistoryLimitChange() {
        trimHistoryToLimit()
        persistHistory()
    }

    private func trimHistoryToLimit() {
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
    }

    private func persistHistory() {
        let snapshots = history.map(PersistedTask.init(task:))
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferences.Key.activityHistory)
    }

    private static func loadPersistedHistory() -> [OperationTask] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.Key.activityHistory),
              let snapshots = try? JSONDecoder().decode([PersistedTask].self, from: data)
        else { return [] }
        return snapshots.map(\.task)
    }
}

private struct PersistedTask: Codable {
    let id: UUID
    let category: OperationTask.Category
    let kind: OperationTask.Kind
    let title: String
    let detail: String?
    let startedAt: Date
    let status: PersistedStatus
    let finishedAt: Date?
    let progress: PersistedProgress
    let details: PersistedDetails?

    init(task: OperationTask) {
        id = task.id
        category = task.category
        kind = task.kind
        title = task.title
        detail = task.detail
        startedAt = task.startedAt
        status = PersistedStatus(status: task.status)
        finishedAt = task.finishedAt
        progress = PersistedProgress(progress: task.progress)
        if let session = task.detailsSession {
            details = PersistedDetails(title: session.title, rawOutput: session.rawOutput, finishedAt: session.finishedAt)
        } else {
            details = nil
        }
    }

    @MainActor
    var task: OperationTask {
        OperationTask(
            id: id,
            category: category,
            kind: kind,
            title: title,
            detail: detail,
            startedAt: startedAt,
            cancellable: false,
            detailsSession: details?.session,
            status: status.status,
            progress: progress.progress,
            finishedAt: finishedAt
        )
    }
}

private struct PersistedProgress: Codable {
    let fraction: Double?
    let currentFile: String?
    let statusText: String?
    let completedUnitCount: Int?
    let totalUnitCount: Int?

    init(progress: ArchiveProgressState) {
        fraction = progress.fraction
        currentFile = progress.currentFile
        statusText = progress.statusText
        completedUnitCount = progress.completedUnitCount
        totalUnitCount = progress.totalUnitCount
    }

    var progress: ArchiveProgressState {
        ArchiveProgressState(
            fraction: fraction,
            currentFile: currentFile,
            statusText: statusText,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }
}

private struct PersistedDetails: Codable {
    let title: String
    let rawOutput: String
    let finishedAt: Date?

    @MainActor
    var session: ArchiveOperationDetailsSession {
        ArchiveOperationDetailsSession(title: title, rawOutput: rawOutput, finishedAt: finishedAt)
    }
}

private enum PersistedStatus: Codable {
    case succeeded(URL?)
    case skipped(String?)
    case failed(String)
    case cancelled

    init(status: OperationTask.Status) {
        switch status {
        case .running:
            self = .cancelled
        case .succeeded(let url):
            self = .succeeded(url)
        case .skipped(let reason):
            self = .skipped(reason)
        case .failed(let message):
            self = .failed(message)
        case .cancelled:
            self = .cancelled
        }
    }

    var status: OperationTask.Status {
        switch self {
        case .succeeded(let url):
            return .succeeded(url)
        case .skipped(let reason):
            return .skipped(reason)
        case .failed(let message):
            return .failed(message)
        case .cancelled:
            return .cancelled
        }
    }
}
