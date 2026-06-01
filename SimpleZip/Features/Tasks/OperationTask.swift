//
//  OperationTask.swift
//  SimpleZip
//

import Combine
import Foundation

@MainActor
final class OperationTask: ObservableObject, Identifiable {
    enum Category: String, Codable, Hashable {
        case fileOperation
        case archive
    }

    enum Kind: String, Codable {
        case extract
        case compress
        case test
        case benchmark
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
        /// 操作完成但**什么都没改动**（如粘贴/移动时目标与源内容相同被跳过）。
        /// 单列出来避免被画成绿色「成功」——否则用户会以为覆盖发生了，其实没有。可选附带原因文案。
        case skipped(String?)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let id: UUID
    let category: Category
    let kind: Kind
    let title: String
    let detail: String?
    let startedAt: Date
    let detailsSession: ArchiveOperationDetailsSession?
    var operationID: UUID?
    var cancel: (() -> Void)?

    @Published var status: Status = .running
    @Published var progress = ArchiveProgressState()
    @Published var finishedAt: Date?

    init(
        id: UUID = UUID(),
        category: Category,
        kind: Kind,
        title: String,
        detail: String? = nil,
        startedAt: Date = Date(),
        cancellable: Bool,
        detailsSession: ArchiveOperationDetailsSession? = nil,
        operationID: UUID? = nil,
        status: Status = .running,
        progress: ArchiveProgressState? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.detailsSession = detailsSession
        self.operationID = operationID
        self.status = status
        self.progress = progress ?? ArchiveProgressState()
        self.finishedAt = finishedAt
        if !cancellable {
            self.cancel = nil
        }
    }
}
