//
//  ArchiveBrowserModel+OperationLifecycle.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  长任务的统一外壳：startOperationTask / runArchiveTask / 失败 alert / Details 抽屉 / 取消。
//

import Foundation

extension ArchiveBrowserModel {
    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        operationRunner.cancel()
    }

    func showOperationDetails() {
        guard operationDetailsSession != nil else { return }
        isShowingOperationDetails = true
    }

    func dismissOperationFailureAlert() {
        operationFailureFullMessage = nil
    }

    func openOperationDetailsFromFailureAlert() {
        guard operationDetailsSession != nil else { return }
        isShowingOperationDetails = true
        dismissOperationFailureAlert()
    }

    func handleOperationDetailsPresentationChange(_ isPresented: Bool) {
        guard !isPresented else { return }
        if operationDetailsSession?.isRunning == false {
            operationDetailsSession = nil
        }
        isShowingOperationDetails = false
    }

    func closeOperationDetails() {
        if operationDetailsSession?.isRunning == false {
            operationDetailsSession = nil
        }
        isShowingOperationDetails = false
    }

    private func prepareOperationDetailsSession(title: String, showsDetails: Bool) -> ArchiveOperationDetailsSession? {
        guard showsDetails else {
            operationDetailsSession = nil
            isShowingOperationDetails = false
            return nil
        }
        let session = ArchiveOperationDetailsSession(title: title)
        operationDetailsSession = session
        isShowingOperationDetails = true
        return session
    }

    private func makeOperationOutputObserver(for session: ArchiveOperationDetailsSession?) -> (@Sendable (String) -> Void)? {
        guard let session else { return nil }
        return { chunk in
            Task { @MainActor [weak session] in
                session?.append(chunk)
            }
        }
    }

    private func finishOperationDetailsSession(_ session: ArchiveOperationDetailsSession?) {
        session?.finishedAt = Date()
    }

    private func preserveFailureDetailsIfNeeded(title: String, error: Error) {
        guard operationDetailsSession == nil else { return }
        let session = ArchiveOperationDetailsSession(title: title)
        session.append(error.localizedDescription)
        session.finishedAt = Date()
        operationDetailsSession = session
    }

    func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        startOperationTask(cancellable: cancellable) { _ in
            await operation()
        }
    }

    func startOperationTask(cancellable: Bool = false, _ operation: @escaping @MainActor (UUID) async -> Void) {
        operationRunner.start(
            cancellable: cancellable,
            onCancellableChange: { [weak self] value in self?.canCancelCurrentOperation = value },
            operation: operation
        )
    }

    func startManagedArchiveTask(
        title: String,
        showsDetails: Bool,
        cancellable: Bool = true,
        successStatus: String? = nil,
        refreshOnSuccess: (() -> Void)? = nil,
        operation: @escaping (UUID?, @escaping @Sendable (ArchiveProgressState) -> Void, (@Sendable (String) -> Void)?) async throws -> Void
    ) {
        let detailsSession = prepareOperationDetailsSession(title: title, showsDetails: showsDetails)
        let outputObserver = makeOperationOutputObserver(for: detailsSession)
        startOperationTask(cancellable: cancellable) { [weak self] operationID in
            guard let self else { return }
            let didSucceed = await runArchiveTask(title) { progress in
                try await operation(operationID, progress, outputObserver)
            }
            finishOperationDetailsSession(detailsSession)
            guard didSucceed else { return }
            if let successStatus {
                status = successStatus
            }
            refreshOnSuccess?()
        }
    }

    /// 包装耗时归档任务，统一处理进度状态、错误提示和结束状态。
    func runArchiveTask(
        _ workingStatus: String,
        initialProgress: ArchiveProgressState = ArchiveProgressState(fraction: 0, currentFile: nil),
        operation: @escaping (@escaping @Sendable (ArchiveProgressState) -> Void) async throws -> Void
    ) async -> Bool {
        isWorking = true
        errorMessage = nil
        operationProgress = initialProgress
        status = workingStatus
        defer {
            isWorking = false
            operationProgress = ArchiveProgressState()
        }

        do {
            try await operation { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.operationProgress = progress
                    if let statusText = progress.statusText, !statusText.isEmpty {
                        self?.status = statusText
                    } else if let currentFile = progress.currentFile, !currentFile.isEmpty {
                        self?.status = currentFile
                    }
                }
            }
            status = L10n.text("status.done")
            return true
        } catch is CancellationError {
            errorMessage = nil
            status = L10n.text("status.cancelled")
            return false
        } catch {
            preserveFailureDetailsIfNeeded(title: workingStatus, error: error)
            if isShowingOperationDetails && operationDetailsSession != nil {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
            status = L10n.text("status.failed")
            return false
        }
    }
}
