//
//  ArchiveBrowserModel+TestHashBenchmark.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  测试压缩包 / SHA & 校验值 / 7-Zip benchmark。
//

import AppKit
import Foundation

extension ArchiveBrowserModel {
    func testArchive() {
        // `.siz` 走自有签名 + SHA 校验作为「测试」—— 路由进 handleSIZOpen 同款流程，签名 sheet 本身就是测试结果
        // （签名通过 + SHA 对得上 = 容器完整、未篡改，等价于普通归档「测试通过」）。
        // 否则 ArchiveService.test 不识别 .siz 容器格式，用户会得到「不支持」错误。
        if case .folder = mode,
           let sizURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SIZArchive.extensionName })?.url {
            pendingSIZOpen = sizURL
            return
        }
        // `.szs` 同样道理 —— 验证 sheet 跑 GPG clearsign 校验 + per-file SHA 校验，本质就是「测试」。
        if case .folder = mode,
           let szsURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SZSArchive.extensionName })?.url {
            pendingSZSOpen = szsURL
            return
        }

        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            archiveURL = url
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { ArchiveService.isSupportedArchive($0.url) })?.url
        }

        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let force = isForced(archiveURL)
        startManagedArchiveTask(
            title: L10n.format("status.testing", archiveURL.lastPathComponent),
            kind: .test,
            showsDetails: false,
            successStatus: L10n.text("status.archiveTested")
        ) { operationID, _, outputObserver in
            try await ArchiveService.test(archiveURL, operationID: operationID, force: force, outputObserver: outputObserver)
        }
    }

    func showSevenZipBenchmarkOptions() {
        benchmarkRequest = SevenZipBenchmarkRequest()
    }

    func runSevenZipBenchmark(_ request: SevenZipBenchmarkRequest) {
        let session = SevenZipBenchmarkSession(options: request.options)
        benchmarkSession = session

        let title = L10n.text("status.benchmarking")
        let detailsSession = ArchiveOperationDetailsSession(title: title)
        let operationID = UUID()
        let operationTask = TaskCenter.shared.begin(
            category: .archive,
            kind: .benchmark,
            title: title,
            cancellable: true,
            detailsSession: detailsSession,
            operationID: operationID
        )
        operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: title)
        TaskCenter.shared.notifyTaskChanged()

        var swiftTask: Task<Void, Never>?
        operationTask.cancel = {
            swiftTask?.cancel()
            ArchiveService.cancelRunningCommand(operationID: operationID)
        }

        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            isWorking = true
            errorMessage = nil
            operationProgress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: title)
            status = title
            defer {
                isWorking = false
                operationProgress = ArchiveProgressState()
            }

            do {
                let report = try await ArchiveService.benchmark(options: request.options, operationID: operationID) { report, output in
                    Task { @MainActor [weak session, weak detailsSession, weak operationTask] in
                        guard operationTask?.status.isRunning == true else { return }
                        session?.report = report
                        session?.rawOutput = output
                        detailsSession?.rawOutput = output
                    }
                }
                session.report = report
                session.rawOutput = report.output
                session.finishedAt = Date()
                detailsSession.rawOutput = report.output
                detailsSession.finishedAt = session.finishedAt
                operationTask.progress = ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.benchmarkReady"))
                TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
                status = L10n.text("status.benchmarkReady")
                SystemSound.operationComplete?.play()
            } catch is CancellationError {
                session.finishedAt = Date()
                detailsSession.finishedAt = session.finishedAt
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
                status = L10n.text("status.cancelled")
            } catch {
                session.finishedAt = Date()
                if detailsSession.rawOutput.isEmpty {
                    detailsSession.append(error.localizedDescription)
                }
                detailsSession.finishedAt = session.finishedAt
                errorMessage = error.localizedDescription
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
                status = L10n.text("status.failed")
            }
        }
    }

    func calculateHash() {
        calculateHash(algorithms: HashAlgorithm.allCases)
    }

    func calculateHash(algorithms: [HashAlgorithm]) {
        let urls: [URL]
        switch mode {
        case .folder, .tag:
            urls = selectedFileItems.map(\.url)
        case .archive(let url):
            urls = [url]
        }

        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.selectFilesForHash")
            return
        }

        calculateHash(for: urls, algorithms: algorithms)
    }

    func calculateHash(forFinderURLs urls: [URL]) {
        calculateHash(for: urls, algorithms: HashAlgorithm.allCases)
    }

    private func calculateHash(for urls: [URL], algorithms: [HashAlgorithm]) {
        let fileURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !fileURLs.isEmpty else {
            errorMessage = L10n.text("error.selectFilesForHash")
            return
        }

        // 哈希是「跑工具产出结果」的操作（同 测试 / 基准），归到「归档操作」并带 detailsSession ——
        // 这样算完的哈希值能存进活动中心的详情里（可查看 / 复制），而不是只剩一个「完成」。
        let detailsSession = ArchiveOperationDetailsSession(title: L10n.text("status.hashing"))
        let operationTask = TaskCenter.shared.begin(
            category: .archive,
            kind: .hash,
            title: L10n.text("status.hashing"),
            cancellable: true,
            detailsSession: detailsSession
        )
        operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("status.hashing"))
        TaskCenter.shared.notifyTaskChanged()

        var swiftTask: Task<Void, Never>?
        operationTask.cancel = {
            swiftTask?.cancel()
        }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            isWorking = true
            errorMessage = nil
            status = L10n.text("status.hashing")
            defer { isWorking = false }

            do {
                let report = try await HashService.calculate(for: fileURLs, includeHiddenFiles: AppPreferences.showHiddenFiles, algorithms: algorithms)
                hashReport = report
                detailsSession.append(report.plainTextSummary)
                status = L10n.text("status.hashReady")
                operationTask.progress = ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.hashReady"))
                TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
            } catch is CancellationError {
                status = L10n.text("status.cancelled")
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                errorMessage = error.localizedDescription
                status = L10n.text("status.failed")
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
