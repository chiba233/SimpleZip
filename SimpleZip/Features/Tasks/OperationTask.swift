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
        /// 0.4.3:撤销 / 重做留痕 —— 活动中心独立一组,与归档 / 文件操作分开计数与展示。
        case undoRedo

        /// 解码容错(与 Kind / TransferAction 同口径):新版本写的新分类被旧版本读到时降级,
        /// 不让一条记录废掉整段历史。
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Category(rawValue: raw) ?? .fileOperation
        }
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
        case convert
        case undo
        case redo

        /// 解码容错：新版本的新 kind 被旧版本读到时降级 `.extract`，不废掉整条历史。
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .extract
        }
    }

    /// 0.4.4 F1:任务来源 —— 谁发起的这次操作(app 内 UI / CLI / Shortcuts·Siri / URL Scheme / Finder 服务)。
    /// 口径:**经对话框确认后才执行的算 `.app`**(如 Finder 服务拉起创建对话框);来源标记的是「启动执行」的表面。
    enum Source: String, Codable, CaseIterable {
        case app
        case cli
        case intent
        case urlScheme
        case finder

        /// 解码容错(与 Category / Kind 同口径):未知来源降级 `.app`,不废掉历史记录。
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .app
        }
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
    /// 任务来源(0.4.4 F1)。begin 时定死,随历史持久化;活动中心来源筛选与自动化中心统计用。
    let source: Source
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
    /// 0.4.2 #21：整个任务的「重新运行」动作 —— 用同样的输入再跑一遍（解压 / 转换 / 测试 / 检查等）。
    /// 运行时态（不持久化，重启后历史任务不可重跑）。任务结束后活动中心展示重跑按钮。
    var rerun: (() -> Void)?
    /// 0.4.4 C:「从失败步继续」—— 发布助手在产物已打出、后续步骤失败时挂上;跳过重新打包,
    /// 对既有产物续跑检查/校验/清单。运行时态(不持久化,重启后不可续跑)。
    var resumeFromFailure: (() -> Void)?

    /// 队列管理②跟进:任务正在等并发槽(还没真正开跑)。活动中心据此把它分进「等待中」组。
    /// 运行时态不持久化;普通 var —— 翻转的两个时刻都伴随 progress 赋值 + notifyTaskChanged,
    /// 不需要自己再发布。
    var isAwaitingSlot = false

    /// 队列管理③:暂停 / 继续。闭包由 startManagedArchiveTask 注入(SIGSTOP/SIGCONT 后端子进程),
    /// 运行时态不持久化;只有「后端驱动」的任务种类才会被注入(纯进程内任务无可暂停的东西)。
    var pause: (() -> Void)?
    var resume: (() -> Void)?
    /// 用户视角的暂停态。@Published:翻转由用户点击触发,没有伴生的 progress 发布可搭车。
    /// (A17 管的是 ArchiveBrowserModel;OperationTask 是逐任务的 ObservableObject,不在禁区。)
    @Published var isPaused = false

    /// 后端驱动、SIGSTOP 真能冻住主要工作量的任务种类。纯进程内的(哈希 / 拆分合并 / 文件操作)
    /// 不给暂停按钮 —— 按了没效果比没有按钮更糟。
    static let pausableKinds: Set<Kind> = [.extract, .compress, .create, .test, .convert, .compare, .benchmark]

    @Published var status: Status = .running
    @Published var progress = ArchiveProgressState()
    @Published var finishedAt: Date?

    init(
        id: UUID = UUID(),
        category: Category,
        kind: Kind,
        source: Source = .app,
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
        self.source = source
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
