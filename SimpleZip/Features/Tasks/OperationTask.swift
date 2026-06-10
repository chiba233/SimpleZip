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
        case compare
        case benchmark
        case hash
        case paste
        case move
        case copy
        case create
        case duplicate
        case delete
        case rename
        case permissions
        case split
        case combine
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
    /// 哈希任务的结构化结果 —— 活动中心详情里**用格式化 UI（每文件 + 各算法卡片）**渲染，而不是命令输出文本。
    /// 仅哈希任务设置。随任务历史持久化（见 TaskCenter.PersistedTask），重启后历史里仍可查看。
    var hashReport: HashReport?
    /// 归档比较任务的结构化结果 —— 活动中心详情用它渲染和比较弹窗同款的分区树（不是命令输出）。
    var diffReport: ArchiveDiffReport?
    /// 粘贴 / 移动覆盖前的「源 vs 目标」哈希比对 —— 活动中心详情里同样用格式化卡片渲染，而非文本。
    /// 仅发生比对时才有。随任务历史持久化，重启后仍可查看。
    var hashComparisons: [HashOverwriteResult] = []
    /// 复制 / 移动 / 合并的逐文件结果（新增 / 覆盖 / 跳过）—— 活动中心详情里列出，避免「只记哈希比对、新增文件无痕」。
    /// 随任务历史持久化，重启后仍可查看。
    var transferLog: [TransferLogEntry] = []
    var operationID: UUID?
    var cancel: (() -> Void)?
    /// 批量操作里有项失败时的「重试失败项」动作 —— 仅重跑失败的那些项。
    /// 运行时态（不持久化，重启后历史任务不再可重试）。活动中心在有失败项且此项非 nil 时展示重试按钮。
    var retryFailed: (() -> Void)?

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
