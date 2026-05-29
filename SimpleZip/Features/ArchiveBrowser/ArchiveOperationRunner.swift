//
//  ArchiveOperationRunner.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 同一时刻只跑一个归档操作的任务调度器。
///
/// 设计动机：归档创建 / 解压 / 测试 / 哈希 / 基准 / 粘贴 / 拖放都属于
/// 「一次只允许一个」的长任务。原本这部分逻辑混在 ArchiveBrowserModel 里，
/// `operationTask` / `activeOperationID` / `canCancelCurrentOperation` 三个字段
/// 散落和它无关的 UI 状态中间。这里把「启动新任务前先取消上一个」「跟 ArchiveService
/// 的子进程取消挂钩」「同步 cancellable 标志」三件事集中起来，model 只剩
/// 「开始任务」和「想取消时调一下」两个入口。
///
/// Runner 不持有 @Published 进度状态 —— 视图层早已绑定到 model 自己的进度字段，
/// 改动需要的代价超过收益，这一层就留在 model 这边；Runner 只负责生命周期。
@MainActor
final class ArchiveOperationRunner {
    /// 当前任务的 ID。用来 (1) 配对 `ArchiveService.cancelRunningCommand`
    /// 取消的正确子进程；(2) 在 task 异步结束回到 main actor 时判断是不是「就是我」
    /// （而不是已经被新任务接管了），避免误把后任务的状态清掉。
    private(set) var activeID: UUID?

    private var task: Task<Void, Never>?

    /// 启动一个新任务。如果当前还有任务正在跑，会先取消它（包括底层子进程）。
    ///
    /// - Parameters:
    ///   - cancellable: 这次任务用户能否在 UI 里取消。回调给 `onCancellableChange` 让 model
    ///     把可见的取消按钮亮起来；任务结束时再回调 false。
    ///   - onCancellableChange: 把 cancellable 状态写到 model 的 @Published 里。
    ///   - operation: 实际工作。会收到当前任务的 UUID，需要时（例如调 ArchiveService 时）
    ///     传给后端，否则在它跑着时再启动新任务会取消错误的进程。
    func start(
        cancellable: Bool,
        onCancellableChange: @escaping @MainActor (Bool) -> Void,
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        task?.cancel()
        if let activeID {
            // 旧任务可能在 Process 里挂着，Task.cancel() 不会自动 SIGTERM 子进程。
            ArchiveService.cancelRunningCommand(operationID: activeID)
        }

        let id = UUID()
        activeID = id
        onCancellableChange(cancellable)
        task = Task { [weak self] in
            await operation(id)
            await MainActor.run {
                guard let self, self.activeID == id else { return }
                // 同一个 ID 才清除 —— 后任务可能已经接管，这里清掉会污染它的状态。
                self.task = nil
                self.activeID = nil
                onCancellableChange(false)
            }
        }
    }

    /// 用户点取消时调。同时取消 Swift Task 和底层子进程。
    func cancel() {
        let id = activeID
        task?.cancel()
        ArchiveService.cancelRunningCommand(operationID: id)
    }
}
