//
//  OperationTask.swift
//  SimpleZip
//

import Combine
import Foundation

@MainActor
final class OperationTask: ObservableObject, Identifiable {
    enum Category: Hashable {
        case fileOperation
        case archive
    }

    enum Kind {
        case extract
        case compress
        case test
        case hash
        case paste
        case move
        case copy
        case duplicate
        case delete
        case rename
    }

    enum Status: Equatable {
        case running
        case succeeded(URL?)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let id = UUID()
    let category: Category
    let kind: Kind
    let title: String
    let startedAt = Date()
    let detailsSession: ArchiveOperationDetailsSession?
    var operationID: UUID?
    var cancel: (() -> Void)?

    @Published var status: Status = .running
    @Published var progress = ArchiveProgressState()
    @Published var finishedAt: Date?

    init(
        category: Category,
        kind: Kind,
        title: String,
        cancellable: Bool,
        detailsSession: ArchiveOperationDetailsSession? = nil,
        operationID: UUID? = nil
    ) {
        self.category = category
        self.kind = kind
        self.title = title
        self.detailsSession = detailsSession
        self.operationID = operationID
        if !cancellable {
            self.cancel = nil
        }
    }
}
