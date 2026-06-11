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
            pendingSIZOpen = SIZOpenRequest(url: sizURL)
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
        runSingleArchiveTest(archiveURL)
    }

    /// 单包测试本体（0.4.2 #21 抽出：URL 捕获后可整单重跑，不依赖当时的选区）。
    private func runSingleArchiveTest(_ archiveURL: URL) {
        let force = isForced(archiveURL)
        startManagedArchiveTask(
            title: L10n.format("status.testing", archiveURL.lastPathComponent),
            kind: .test,
            showsDetails: false,
            successStatus: L10n.text("status.archiveTested"),
            rerunAction: { [weak self] in self?.runSingleArchiveTest(archiveURL) }
        ) { operationID, _, outputObserver in
            try await ArchiveService.test(archiveURL, operationID: operationID, force: force, outputObserver: outputObserver)
        }
    }

    // MARK: - 批量测试（0.4.2）

    /// 批量测试选中的多个压缩包：逐个跑 `ArchiveService.test`，活动中心里逐包列结果
    /// （通过 / 口令保护 / 缺分卷 / 数据损坏 / 格式不支持），失败项可一键重试。
    /// 单个失败不打断整批 —— 跟批量 GPG 加密同一套语义。
    func batchTestSelectedArchives() {
        let urls = selectedFileItems
            .filter { !$0.isDirectory && ArchiveService.isSupportedArchive($0.url) }
            .map(\.url)
        guard urls.count >= 2 else {
            testArchive()   // 防御：菜单只在 ≥2 时出现，直接调用时退回单包流程。
            return
        }
        runBatchArchiveTest(urls)
    }

    private struct BatchTestOutcome {
        let url: URL
        let failureMessage: String?   // nil = 通过
    }

    private func runBatchArchiveTest(_ urls: [URL]) {
        let forced = Set(urls.filter { isForced($0) })
        var outcomes: [BatchTestOutcome] = []
        startManagedArchiveTask(
            title: L10n.format("status.batchTesting", "\(urls.count)"),
            kind: .test,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                guard let self else { return }
                let failedCount = outcomes.filter { $0.failureMessage != nil }.count
                status = failedCount == 0
                    ? L10n.format("status.batchTestAllPassed", "\(outcomes.count)")
                    : L10n.format("status.batchTestPartial", "\(outcomes.count - failedCount)", "\(failedCount)")
            },
            onSucceeded: { [weak self] task in
                task.transferLog = outcomes.map { outcome in
                    guard let message = outcome.failureMessage else {
                        return TransferLogEntry(name: outcome.url.lastPathComponent, action: .passed, isDirectory: false)
                    }
                    let kind = ArchiveService.classifyTestFailure(message)
                    let label = L10n.text("test.failure.\(kind.rawValue)")
                    // detail = 归类标签 + 原始诊断（截断防超长行）；完整输出在任务详情日志里。
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    return TransferLogEntry(
                        name: outcome.url.lastPathComponent,
                        action: .failed,
                        isDirectory: false,
                        detail: trimmed.isEmpty ? label : "\(label) — \(trimmed.prefix(200))"
                    )
                }
                let failedURLs = outcomes.compactMap { $0.failureMessage != nil ? $0.url : nil }
                if !failedURLs.isEmpty {
                    task.retryFailed = { [weak self] in
                        self?.runBatchArchiveTest(failedURLs)
                    }
                }
            },
            rerunAction: { [weak self] in self?.runBatchArchiveTest(urls) }
        ) { operationID, progress, outputObserver in
            var collected: [BatchTestOutcome] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                progress(ArchiveProgressState(
                    fraction: Double(index) / Double(urls.count),
                    currentFile: url.lastPathComponent,
                    completedUnitCount: index,
                    totalUnitCount: urls.count
                ))
                outputObserver?("\n=== \(url.lastPathComponent) ===\n")
                do {
                    try await ArchiveService.test(url, operationID: operationID, force: forced.contains(url), outputObserver: outputObserver)
                    collected.append(BatchTestOutcome(url: url, failureMessage: nil))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    collected.append(BatchTestOutcome(url: url, failureMessage: error.localizedDescription))
                }
            }
            outcomes = collected
            progress(ArchiveProgressState(fraction: 1.0, completedUnitCount: urls.count, totalUnitCount: urls.count))
        }
    }

    // MARK: - 重复文件检测（0.4.2 #24）

    /// 归档空白处右键「查找重复文件」：按 大小 + CRC 在当前包内配组（纯内存，毫秒级），出报告 sheet。
    func findDuplicateFilesInArchive() {
        guard case .archive(let url) = mode else { return }
        let groups = ArchiveDuplicates.findDuplicates(in: session.allItems)
        duplicateFilesReport = DuplicateFilesReport(
            archiveName: (archiveDisplayOverride ?? url).lastPathComponent,
            groups: groups
        )
    }

    // MARK: - 发布包检查（0.4.2 #15）

    /// 一次发布包检查的结果。条目侧统计在 Core（ReleaseInspection），这里聚合 测试 / SHA-256 / 注释。
    struct ReleaseInspectionReport: Identifiable {
        let id = UUID()
        let archiveURL: URL
        var listable = false
        var stats: ReleaseInspectionStats?
        var securityFindings: [ArchiveSecurityFinding] = []
        var testPassed: Bool?
        var testFailureMessage: String?
        var sha256: String?
        var hasComment = false
    }

    /// 右键「发布包检查…」：对选中的单个归档跑一套发布前检查（能否解压 / 危险路径 / 垃圾 /
    /// 空目录 / 大小写冲突 / symlink / 可执行权限 / SHA-256），出报告 sheet。
    func inspectSelectedArchiveForRelease() {
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
        runReleaseInspection(archiveURL)
    }

    private func runReleaseInspection(_ url: URL) {
        let force = isForced(url)
        var report = ReleaseInspectionReport(archiveURL: url)
        startManagedArchiveTask(
            title: L10n.format("inspect.taskTitle", url.lastPathComponent),
            kind: .test,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.releaseInspectionReport = report
            },
            rerunAction: { [weak self] in self?.runReleaseInspection(url) }
        ) { operationID, progress, outputObserver in
            // ① 列目录：空口令 + 会话缓存里的口令逐个静默试；全失败 = 读不了条目（报告里如实标注）。
            progress(ArchiveProgressState(fraction: 0.1, statusText: nil))
            var items: [ArchiveItem] = []
            for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                if let listed = try? await ArchiveService.list(url, password: password, force: force) {
                    items = listed
                    report.listable = true
                    break
                }
            }
            if report.listable {
                report.stats = ReleaseInspection.stats(for: items)
                report.securityFindings = ArchiveSecurityReport.analyze(items)
                report.hasComment = !ArchiveService.headerComment(for: url).isEmpty
            }
            // ② 完整性测试（失败不让任务失败 —— 失败本身就是报告内容）。
            progress(ArchiveProgressState(fraction: 0.4, statusText: nil))
            do {
                try await ArchiveService.test(url, operationID: operationID, force: force, outputObserver: outputObserver)
                report.testPassed = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.testPassed = false
                report.testFailureMessage = error.localizedDescription
            }
            // ③ SHA-256（发布说明 / 校验文件用）。
            progress(ArchiveProgressState(fraction: 0.8, statusText: nil))
            report.sha256 = try? await Task.detached(priority: .userInitiated) {
                try HashService.sha256(for: url)
            }.value
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - #111 归档比较

    /// 右键「比较归档」入口：选中 2 个归档直接比；选中 1 个时用 NSOpenPanel 挑第二个。
    /// 菜单项只在这两种选区下出现，这里的兜底报错只防御直接调用。
    func compareSelectedArchives() {
        // 0.4.2 #25:可比对的「侧」= 受支持归档 或 文件夹。归档 vs 归档 / 文件夹 vs 归档 / 文件夹 vs 文件夹都行。
        let comparableURLs = selectedFileItems
            .filter { $0.isDirectory || ArchiveService.isSupportedArchive($0.url) }
            .map(\.url)

        if comparableURLs.count >= 2 {
            runArchiveComparison(left: comparableURLs[0], right: comparableURLs[1])
            return
        }
        guard let first = comparableURLs.first else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openArchive")
        panel.message = L10n.format("diff.choosePrompt", first.lastPathComponent)
        panel.canChooseDirectories = true   // 0.4.2 #25:第二侧也可以选文件夹
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveService.supportedArchiveTypes
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let other = panel.url {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: other.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue || ArchiveService.isSupportedArchive(other) else {
                errorMessage = L10n.text("error.openOrSelectArchive")
                return
            }
            runArchiveComparison(left: first, right: other)
        }
    }

    /// 列出两个包 → Core `ArchiveDiff.compare` → 弹结果 sheet。走托管归档任务（活动中心可见、可取消）。
    /// 加密归档按现状用空密码列出 —— header 加密的包会直接以后端错误失败，错误对用户可见，不静默吞。
    func runArchiveComparison(left: URL, right: URL) {
        let title = L10n.format("status.comparing", left.lastPathComponent, right.lastPathComponent)
        let forceLeft = isForced(left)
        let forceRight = isForced(right)
        startManagedArchiveTask(
            title: title,
            kind: .compare,
            showsDetails: false,
            successStatus: L10n.text("status.compared"),
            // 把结构化结果挂到任务上 —— 活动中心详情渲染和弹窗同款的分区树。
            // 时序：operation 闭包先在 MainActor 上写 archiveDiffReport，任务才被标成功，这里读到的就是本次结果。
            onSucceeded: { [weak self] task in
                task.diffReport = self?.archiveDiffReport
            }
        ) { [weak self] operationID, _, _ in
            // 0.4.2 #25:任一侧是文件夹 → 文件系统快照;是归档 → 照常列出。归档 vs 文件夹随便混。
            let leftItems = try await Self.comparisonItems(for: left, operationID: operationID, force: forceLeft)
            let rightItems = try await Self.comparisonItems(for: right, operationID: operationID, force: forceRight)
            let result = ArchiveDiff.compare(left: leftItems, right: rightItems)
            await MainActor.run {
                self?.archiveDiffReport = ArchiveDiffReport(
                    leftName: left.lastPathComponent,
                    rightName: right.lastPathComponent,
                    result: result
                )
            }
        }
    }

    /// 比较的一侧取条目:文件夹(且不是受支持归档)→ 文件系统快照;否则按归档列出。
    nonisolated private static func comparisonItems(for url: URL, operationID: UUID?, force: Bool) async throws -> [ArchiveItem] {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           !ArchiveService.isSupportedArchive(url) {
            return await Task.detached(priority: .userInitiated) {
                ArchiveDiff.folderItems(at: url)
            }.value
        }
        return try await ArchiveService.list(url, operationID: operationID, force: force)
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
                    // 不再单独 [weak …]：外层 Task 在整个 benchmark 期间已强持有 session/detailsSession/
                    // operationTask,内层再标 weak 与外层强捕获不一致（编译告警）且无实际收益。
                    Task { @MainActor in
                        guard operationTask.status.isRunning else { return }
                        session.report = report
                        session.rawOutput = output
                        detailsSession.rawOutput = output
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

        // 标题带上文件名：单个「正在计算 xxx 的哈希」；多个「正在计算 xxx 等共 N 个文件的哈希」——
        // 比泛泛的「正在计算哈希…」有用，历史里也能一眼看出算的是哪些文件。
        let hashingTitle: String = fileURLs.count == 1
            ? L10n.format("status.hashing.one", fileURLs[0].lastPathComponent)
            : L10n.format("status.hashing.many", fileURLs[0].lastPathComponent, fileURLs.count)

        // 哈希是文件操作（对选中文件算摘要），归「文件操作」。结果用结构化 HashReport 挂到任务上，
        // 活动中心详情里以**格式化 UI**（每文件 + 各算法卡片）渲染，可查看 / 复制——不是命令输出文本。
        let operationTask = TaskCenter.shared.begin(
            category: .fileOperation,
            kind: .hash,
            title: hashingTitle,
            cancellable: true
        )
        operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: nil, statusText: hashingTitle)
        TaskCenter.shared.notifyTaskChanged()

        var swiftTask: Task<Void, Never>?
        operationTask.cancel = {
            swiftTask?.cancel()
        }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            isWorking = true
            errorMessage = nil
            status = hashingTitle
            defer { isWorking = false }

            do {
                let report = try await HashService.calculate(for: fileURLs, includeHiddenFiles: AppPreferences.showHiddenFiles, algorithms: algorithms)
                hashReport = report
                operationTask.hashReport = report   // 活动中心详情用它渲染格式化哈希卡片
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
