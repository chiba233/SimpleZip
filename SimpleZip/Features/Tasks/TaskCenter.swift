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

    private let historyLimit = 10

    var runningCount: Int {
        active.count
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
        cancellable: Bool,
        detailsSession: ArchiveOperationDetailsSession? = nil,
        operationID: UUID? = nil
    ) -> OperationTask {
        let task = OperationTask(
            category: category,
            kind: kind,
            title: title,
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
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
    }

    func cancelAll() {
        for task in active {
            task.cancel?()
        }
    }

    func notifyTaskChanged() {
        objectWillChange.send()
    }
}
