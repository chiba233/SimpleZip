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
        ) { [weak self] operationID, _, outputObserver in
            guard let self else { return }
            switch try await self.passwordAwareArchiveTest(archiveURL, operationID: operationID, force: force, outputObserver: outputObserver) {
            case .passed:
                return
            case .skippedNoPassword:
                // 取消密码框 = 任务取消,不算失败(0.4.3 #6 拍板语义)。
                throw CancellationError()
            case .failed(let message):
                throw ArchiveError.commandFailed(message)
            }
        }
    }

    /// 0.4.3 #6 统一密码中心:带密码智能测试的结果三态。
    enum PasswordAwareTestOutcome {
        case passed
        case skippedNoPassword
        case failed(String)
    }

    /// 0.4.3 #6:带密码智能的归档完整性测试。
    /// 顺序:①无口令直测 → ②错误表明要口令时,**静默**依次试 会话缓存(本包→本会话最近成功)+ 预设密码
    /// → ③仍不行才弹密码框(等待期间任务详情 + 状态栏显示「等待输入密码」),口令错就带提示重弹。
    /// 成功口令记入会话缓存 —— 同归档本会话只问一次,批量任务里后续同口令的包静默通过。
    /// 取消密码框返回 `.skippedNoPassword`(语义=跳过/取消,不是失败)。
    func passwordAwareArchiveTest(
        _ archiveURL: URL,
        operationID: UUID?,
        force: Bool,
        outputObserver: (@Sendable (String) -> Void)?
    ) async throws -> PasswordAwareTestOutcome {
        func attempt(_ password: String) async throws {
            try await ArchiveService.test(archiveURL, password: password, operationID: operationID, force: force, outputObserver: outputObserver)
        }
        do {
            try await attempt("")
            return .passed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard ArchiveService.errorSuggestsPasswordRequirement(error) else {
                return .failed(error.localizedDescription)
            }
            // ② 静默候选:本包记过的 → 本会话最近成功的 → 预设密码(去重)。错口令无害,后端只会再报错。
            var candidates = SessionPasswordCache.shared.candidates(for: archiveURL)
            if AppPreferences.hasUsablePresetPassword {
                let preset = AppPreferences.presetPassword
                if !preset.isEmpty, !candidates.contains(preset) { candidates.append(preset) }
            }
            for candidate in candidates {
                do {
                    try await attempt(candidate)
                    SessionPasswordCache.shared.record(candidate, for: archiveURL)
                    return .passed
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard ArchiveService.errorSuggestsPasswordRequirement(error) else {
                        return .failed(error.localizedDescription)
                    }
                }
            }
            // ③ 弹框循环。等待期间把状态写进任务详情 + 状态栏 —— 活动中心能看到「等待输入密码」。
            var isRetry = false
            while true {
                let waiting = L10n.format("status.waitingForPassword", archiveURL.lastPathComponent)
                outputObserver?("\n" + waiting + "\n")
                status = waiting
                guard let authentication = promptForArchivePassword(
                    archiveURL: archiveURL,
                    displayName: archiveURL.lastPathComponent,
                    detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL),
                    isRetry: isRetry,
                    actionTitle: L10n.text("password.action.test")
                ) else {
                    return .skippedNoPassword
                }
                do {
                    try await attempt(authentication.password)
                    SessionPasswordCache.shared.record(authentication.password, for: archiveURL)
                    return .passed
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard ArchiveService.errorSuggestsPasswordRequirement(error) else {
                        return .failed(error.localizedDescription)
                    }
                    isRetry = true
                }
            }
        }
    }

    // MARK: - 批量测试（0.4.2）

    /// 批量测试选中的多个压缩包：逐个跑 `ArchiveService.test`，活动中心里逐包列结果
    /// （通过 / 口令保护 / 缺分卷 / 数据损坏 / 格式不支持），失败项可一键重试。
    /// 单个失败不打断整批 —— 跟批量 GPG 加密同一套语义。
    func batchTestSelectedArchives() {
        let urls = selectedFileItems
            .filter { !$0.isDirectory && SignedContainerService.isToolableArchive($0.url) }
            .map(\.url)
        guard urls.count >= 2 else {
            testArchive()   // 防御：菜单只在 ≥2 时出现，直接调用时退回单包流程。
            return
        }
        runBatchArchiveTest(urls)
    }

    /// #16 URL scheme:对外部给定的归档 URL 跑测试(已在 AppDelegate 经确认弹窗)。
    /// 复用批量测试任务流(单个也走它 —— 结果同样进活动中心逐包汇总)。
    func testArchives(at urls: [URL], source: OperationTask.Source = .app) {
        let supported = urls.filter { ArchiveService.isSupportedArchive($0) }
        guard !supported.isEmpty else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runBatchArchiveTest(supported, source: source)
    }

    private struct BatchTestOutcome {
        let url: URL
        let result: PasswordAwareTestOutcome
    }

    private func runBatchArchiveTest(_ urls: [URL], source: OperationTask.Source = .app) {
        let forced = Set(urls.filter { isForced($0) })
        var outcomes: [BatchTestOutcome] = []
        startManagedArchiveTask(
            title: L10n.format("status.batchTesting", "\(urls.count)"),
            kind: .test,
            source: source,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                guard let self else { return }
                let passedCount = outcomes.filter { if case .passed = $0.result { return true } else { return false } }.count
                status = passedCount == outcomes.count
                    ? L10n.format("status.batchTestAllPassed", "\(outcomes.count)")
                    : L10n.format("status.batchTestPartial", "\(passedCount)", "\(outcomes.count - passedCount)")
            },
            onSucceeded: { [weak self] task in
                task.transferLog = outcomes.map { outcome in
                    switch outcome.result {
                    case .passed:
                        return TransferLogEntry(name: outcome.url.lastPathComponent, action: .passed, isDirectory: false)
                    case .skippedNoPassword:
                        // 0.4.3 #6:取消密码框 = 跳过,不打成失败。
                        return TransferLogEntry(
                            name: outcome.url.lastPathComponent,
                            action: .skipped,
                            isDirectory: false,
                            detail: L10n.text("test.skipped.noPassword")
                        )
                    case .failed(let message):
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
                }
                // 失败 + 跳过(没给密码)的都可重试 —— 重试时会话缓存里可能已经有别的包验证过的口令。
                let retryURLs = outcomes.compactMap { outcome -> URL? in
                    if case .passed = outcome.result { return nil }
                    return outcome.url
                }
                if !retryURLs.isEmpty {
                    task.retryFailed = { [weak self] in
                        self?.runBatchArchiveTest(retryURLs)
                    }
                }
            },
            rerunAction: { [weak self] in self?.runBatchArchiveTest(urls) }
        ) { [weak self] operationID, progress, outputObserver in
            guard let self else { return }
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
                    // 0.4.3 #6:批量测试走密码智能 —— 加密包先静默试会话缓存/预设,要弹框也只弹一次,
                    // 验证过的口令进缓存,同口令的后续包全部静默通过。
                    // 0.4.4:`.siz` 测的是内层 archive(A5;unwrap 失败 = 该包失败,不中断整批)。
                    let result = try await SignedContainerService.withToolAdaptedArchive(url) { target in
                        try await self.passwordAwareArchiveTest(target, operationID: operationID, force: forced.contains(url), outputObserver: outputObserver)
                    }
                    collected.append(BatchTestOutcome(url: url, result: result))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    collected.append(BatchTestOutcome(url: url, result: .failed(error.localizedDescription)))
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

    // MARK: - 内容搜索(队列 #11:只文本/限大小/主动触发/临时区即用即删)

    /// 待确认的内容搜索(sheet item):搜索词 + 单文件大小上限。
    struct ContentSearchRequest: Identifiable {
        let id = UUID()
        let archiveURL: URL
        var query = ""
        var maxBytes: Int64 = ArchiveContentSearch.defaultMaxFileBytes
    }

    /// 一次内容搜索的结果(sheet item)。
    struct ContentSearchReport: Identifiable {
        let id = UUID()
        let archiveName: String
        let query: String
        let candidateCount: Int
        let matches: [ArchiveContentSearch.Match]
    }

    /// 归档空白处右键「在内容中搜索…」:弹搜索词输入 sheet(主动触发,绝不自动扫)。
    func promptContentSearch() {
        guard case .archive(let url) = mode else { return }
        contentSearchRequest = ContentSearchRequest(archiveURL: url)
    }

    /// 确认后的搜索:候选 = 文本类扩展名 + ≤大小上限的条目;解到临时目录(搜完即删),
    /// 逐文件嗅探二进制后逐行匹配。加密包走会话口令静默重试,全失败任务如实失败。
    func runContentSearch(_ request: ContentSearchRequest) {
        guard case .archive(let url) = mode else { return }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let displayName = (archiveDisplayOverride ?? url).lastPathComponent
        let candidates = session.allItems.filter { ArchiveContentSearch.isTextCandidate($0, maxBytes: request.maxBytes) }
        guard !candidates.isEmpty else {
            contentSearchReport = ContentSearchReport(archiveName: displayName, query: query, candidateCount: 0, matches: [])
            return
        }
        let force = isForced(url)
        var report = ContentSearchReport(archiveName: displayName, query: query, candidateCount: candidates.count, matches: [])
        startManagedArchiveTask(
            title: L10n.format("contentSearch.taskTitle", displayName),
            kind: .test,
            showsDetails: false,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.contentSearchReport = report
            },
            rerunAction: { [weak self] in self?.runContentSearch(request) }
        ) { operationID, progress, outputObserver in
            // A7:系统临时目录 + UUID;搜完(含失败路径)立即删除 —— 临时安全区即用即删。
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimpleZip-ContentSearch-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

            progress(ArchiveProgressState(fraction: 0.05, statusText: nil))
            var extracted = false
            var lastError: Error?
            for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                do {
                    try await ArchiveService.extract(
                        url,
                        entries: candidates,
                        to: scratch,
                        overwriteBehavior: .overwrite,
                        pathMode: .preserve,
                        password: password,
                        zipDecryptionMethod: .automatic,
                        safetyPolicy: .skipValidation,
                        operationID: operationID,
                        progress: { state in
                            var scaled = state
                            scaled.fraction = state.fraction.map { 0.05 + $0 * 0.6 }
                            progress(scaled)
                        },
                        force: force
                    )
                    extracted = true
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            guard extracted else {
                throw lastError ?? ArchiveError.commandFailed(L10n.text("inspect.notListable"))
            }

            progress(ArchiveProgressState(fraction: 0.7, statusText: nil))
            var matches: [ArchiveContentSearch.Match] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let relativePath = ArchiveSession.normalizedEntryName(candidate.name, isDirectory: false)
                let fileURL = scratch.appendingPathComponent(relativePath)
                // 只读普通文件:解出来的 symlink(可能指向树外)一律不追。
                guard let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
                      values.isSymbolicLink != true, values.isRegularFile == true,
                      let data = try? Data(contentsOf: fileURL) else { continue }
                for hit in ArchiveContentSearch.matches(in: data, query: query) {
                    matches.append(ArchiveContentSearch.Match(
                        entryPath: candidate.name, lineNumber: hit.lineNumber, lineText: hit.lineText
                    ))
                }
                if matches.count >= 500 { break }
            }
            report = ContentSearchReport(
                archiveName: displayName, query: query,
                candidateCount: candidates.count, matches: matches
            )
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - 疑似重复归档检测(队列 #10)

    /// 一次扫描的展示模型(sheet item)。分组在 Core(ArchiveDuplicateScan,纯函数已测),
    /// 这里聚合「扫了几个 / 跳过几个」与组列表。
    struct DuplicateArchivesReport: Identifiable {
        let id = UUID()
        let folderName: String
        let scannedCount: Int
        let skippedNames: [String]
        let groups: [ArchiveDuplicateScan.Group]
    }

    /// 「查找疑似重复归档」:选中 ≥2 个归档只扫选中,否则扫当前文件夹里全部受支持归档。
    /// 逐包列条目算结构指纹(加密包试会话口令,仍读不了的跳过并在报告里点名),纯只读。
    func findDuplicateArchivesInFolder() {
        let selectedArchives = selectedFileItems.filter { !$0.isDirectory && SignedContainerService.isToolableArchive($0.url) }
        let candidates: [URL]
        if selectedArchives.count >= 2 {
            candidates = selectedArchives.map(\.url)
        } else {
            candidates = fileItems
                .filter { !$0.isDirectory && SignedContainerService.isToolableArchive($0.url) }
                .map(\.url)
        }
        guard candidates.count >= 2, case .folder(let folderURL) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runDuplicateArchiveScan(candidates: candidates, folderName: folderURL.lastPathComponent)
    }

    private func runDuplicateArchiveScan(candidates: [URL], folderName: String) {
        var report = DuplicateArchivesReport(folderName: folderName, scannedCount: 0, skippedNames: [], groups: [])
        startManagedArchiveTask(
            title: L10n.format("dupArchives.taskTitle", folderName),
            kind: .test,
            showsDetails: false,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.duplicateArchivesReport = report
            },
            rerunAction: { [weak self] in self?.runDuplicateArchiveScan(candidates: candidates, folderName: folderName) }
        ) { operationID, progress, _ in
            var sources: [ArchiveDuplicateScan.Source] = []
            var skipped: [String] = []
            for (index, url) in candidates.enumerated() {
                try Task.checkCancellation()
                progress(ArchiveProgressState(
                    fraction: Double(index) / Double(candidates.count),
                    currentFile: url.lastPathComponent,
                    completedUnitCount: index, totalUnitCount: candidates.count
                ))
                // 0.4.4:`.siz` 按内层 archive 的条目算指纹(A5;解不开 = 跳过,与列不动同款)。
                var listed: [ArchiveItem]?
                if let items = try? await SignedContainerService.withToolAdaptedArchive(url, perform: { target -> [ArchiveItem]? in
                    for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                        if let items = try? await ArchiveService.list(target, password: password, operationID: operationID) {
                            return items
                        }
                    }
                    return nil
                }) {
                    listed = items
                }
                guard let items = listed else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                let files = items.filter { !$0.isDirectory }
                sources.append(ArchiveDuplicateScan.Source(
                    url: url,
                    fingerprint: ArchiveStructuralFingerprint.compute(for: items),
                    entryCount: files.count,
                    totalBytes: files.reduce(0) { $0 + ($1.size ?? 0) }
                ))
            }
            report = DuplicateArchivesReport(
                folderName: folderName,
                scannedCount: sources.count,
                skippedNames: skipped,
                groups: ArchiveDuplicateScan.groups(from: sources)
            )
            progress(ArchiveProgressState(fraction: 1.0, completedUnitCount: candidates.count, totalUnitCount: candidates.count))
        }
    }

    // MARK: - 发布助手(选目录→打包→检查→校验文件→可选签名一条流)

    /// 工具菜单「发布助手…」:预填当前浏览的文件夹,弹确认 sheet。
    func showReleaseAssistant() {
        var request = ReleaseAssistantRequest()
        if case .folder(let url) = mode {
            request.sourceFolder = url
            request.fileName = url.lastPathComponent
            request.destinationFolder = url.deletingLastPathComponent()
        }
        releaseAssistantRequest = request
    }

    /// 创建对话框「使用发布助手」转场:尽量带上用户已填的内容 —— 文件名 / 输出目录 / 格式照搬;
    /// 选区恰好是单个文件夹时完整映射为产物目录,其他选区(多选 / 单文件)发布助手装不下,
    /// 源目录留空让用户挑,不瞎猜。
    func showReleaseAssistant(prefillFrom creationRequest: ArchiveCreationRequest) {
        var request = ReleaseAssistantRequest()
        let stem = creationRequest.destinationURL.deletingPathExtension().lastPathComponent
        if !stem.isEmpty {
            request.fileName = stem
        }
        request.destinationFolder = creationRequest.destinationURL.deletingLastPathComponent()
        if creationRequest.options.format == .zip || creationRequest.options.format == .sevenZip {
            request.format = creationRequest.options.format
        }
        var isDirectory: ObjCBool = false
        if creationRequest.sourceURLs.count == 1,
           let source = creationRequest.sourceURLs.first,
           FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            request.sourceFolder = source
        }
        releaseAssistantRequest = request
    }

    /// 发布助手管线:① 打包(可排垃圾 / 可复现,输出重名自动唯一化绝不覆盖) → ② 发布检查
    /// (与右键「发布包检查」同一套步骤) → ③ 写 SHA256SUMS → ④ 可选转入现有「创建签名清单」sheet。
    /// 检查失败不让任务失败 —— 失败本身就是报告内容;打包失败才算任务失败。
    /// F3:执行体在 ReleaseAssistantPipeline(发布 intent 复用同一函数);本方法只是任务壳。
    /// `resumingWith`:上次跑出的产物还在 → 跳过打包,从检查/校验续跑(createArchive 重跑 =
    /// UniqueFileName 新文件,不存在「原位续打包」)。
    func runReleaseAssistant(_ request: ReleaseAssistantRequest, resumingWith existingArtifact: URL? = nil) {
        guard let source = request.sourceFolder, let destination = request.destinationFolder else { return }
        let trimmedName = request.fileName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let outputURL: URL
        let skipCreate: Bool
        if let existingArtifact, FileManager.default.fileExists(atPath: existingArtifact.path) {
            outputURL = existingArtifact
            skipCreate = true
        } else {
            let preferred = destination
                .appendingPathComponent(trimmedName)
                .appendingPathExtension(request.format.pathExtension)
            outputURL = UniqueFileName.suffixed(for: preferred, suffix: "") {
                FileManager.default.fileExists(atPath: $0.path)
            }
            skipCreate = false
        }

        var options = ArchiveCreationOptions()
        options.format = request.format
        options.skipDSStore = request.excludeJunk
        if request.excludeJunk {
            // 与 Core 垃圾识别(ArchiveJunkFiles)同一族:AppleDouble、Thumbs.db、desktop.ini。
            // .DS_Store 由 skipDSStore 负责;__MACOSX 是 Archive Utility 的归档内产物,源目录不会有。
            // 创建走 7zz `-xr!`(递归按名排除,命中任一路径段),不需要 `*/` 变体。
            options.customExcludes = "._*, Thumbs.db, desktop.ini"
        }
        if request.reproducible {
            options.reproducibleArchive = true
        }

        var report = ReleaseInspectionReport(archiveURL: outputURL)
        let recorder = ReleaseStepRecorder()
        startManagedArchiveTask(
            title: L10n.format("releaseAssistant.taskTitle", outputURL.lastPathComponent),
            kind: .create,
            showsDetails: true,
            // C:运行中活动中心直接可见产物完整路径。
            detail: outputURL.path,
            successStatus: L10n.format("releaseAssistant.done", outputURL.lastPathComponent),
            refreshOnSuccess: { [weak self] in
                guard let self else { return }
                if request.runInspection {
                    // C:步骤耗时随报告进 sheet(「步骤」小节)。
                    report.steps = recorder.steps
                    self.releaseInspectionReport = report
                }
                if request.createSignedManifest {
                    // 转入现有「创建签名清单」sheet(payload root = 输出目录,预选刚打的包)——
                    // 不在助手里重绘密钥选择(A1)。交互式签名步不进步骤引擎(F3 设计如此)。
                    self.pendingCreateSZS = CreateSZSPrefill(payloadRoot: destination, files: [outputURL])
                }
            },
            onSucceeded: { task in
                // 活动中心详情里列出产物(路径 + SHA-256)+ F3 各步骤耗时(现成持久化通道)。
                var rows = [TransferLogEntry(name: outputURL.path, action: .passed, isDirectory: false,
                                             detail: report.sha256 ?? "")]
                if request.writeChecksums {
                    rows.append(TransferLogEntry(name: "SHA256SUMS", action: .passed, isDirectory: false, detail: ""))
                }
                for step in recorder.steps {
                    rows.append(TransferLogEntry(
                        name: L10n.text("releaseAssistant.step.\(step.id.rawValue)"),
                        action: step.status == .skipped ? .skipped : .passed,
                        isDirectory: false,
                        detail: step.status == .skipped ? "" : step.formattedDuration
                    ))
                }
                task.transferLog = rows
                // 用户点名:检查报告可从活动中心重开(只在本次开了发布检查时给)。
                if request.runInspection {
                    var reopened = report
                    reopened.steps = recorder.steps
                    task.openReport = { [weak self] in
                        self?.releaseInspectionReport = reopened
                    }
                    // 0.4.4:报告本体随历史落盘 —— 重启后仍可打开(闭包只活一个会话)。
                    task.reportAttachment = .releaseInspection(reopened)
                }
                // #2:成功跑进发布账本(失败留在活动历史不进账)。后端版本要起进程,异步补记。
                let steps = recorder.steps
                let inspection = report
                let trimmedLabel = request.versionLabel.trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    let metadata = await ReportMetadataBuilder.make(targetPath: nil)
                    ReleaseLedgerStore().append(ReleaseLedgerEntry(
                        date: Date(),
                        artifactPath: outputURL.path,
                        versionLabel: trimmedLabel.isEmpty ? trimmedName : trimmedLabel,
                        formatRawValue: request.format.rawValue,
                        sha256: inspection.sha256,
                        structuralFingerprint: inspection.structuralFingerprint,
                        reproducible: request.reproducible,
                        excludeJunk: request.excludeJunk,
                        inspectionRan: request.runInspection,
                        testPassed: inspection.testPassed,
                        suspiciousPathCount: request.runInspection
                            ? inspection.securityFindings.reduce(0) { $0 + $1.entryPaths.count } : nil,
                        junkCount: inspection.stats?.junkCount,
                        emptyDirectoryCount: inspection.stats?.emptyDirectoryCount,
                        fileCount: inspection.stats?.fileCount,
                        totalBytes: inspection.stats?.totalBytes,
                        wroteChecksums: request.writeChecksums,
                        signRequested: request.createSignedManifest,
                        appVersion: metadata.appVersion,
                        backendVersion: metadata.backendVersion,
                        steps: steps
                    ))
                }
            },
            rerunAction: { [weak self] in self?.runReleaseAssistant(request) },
            // C:产物已打出、后续步骤失败 → 挂「从失败步继续」(跳过重新打包,对既有产物续跑)。
            onFailed: { [weak self] task, _ in
                guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
                task.resumeFromFailure = { [weak self] in
                    self?.runReleaseAssistant(request, resumingWith: outputURL)
                }
            }
        ) { operationID, progress, outputObserver in
            report = try await ReleaseAssistantPipeline.run(
                request: request,
                source: source,
                destination: destination,
                outputURL: outputURL,
                options: options,
                skipCreate: skipCreate,
                recorder: recorder,
                operationID: operationID,
                progress: progress,
                outputObserver: outputObserver
            )
        }
    }

    // MARK: - 归档元数据报告(0.4.4 #13)

    /// 归档打开状态右键「元数据报告」:头部块属性(单独跑一次 `l -slt`,密码静默走会话缓存)+
    /// 已列条目的聚合(零额外后端调用)。只读。
    func showArchiveMetadataReport() {
        guard case .archive(let url) = mode else { return }
        let displayName = (archiveDisplayOverride ?? url).lastPathComponent
        let aggregate = ArchiveMetadataAggregate.aggregate(items: session.allItems)
        let securityFindingCount = archiveSecurityFindings.reduce(0) { $0 + $1.entryPaths.count }
        var properties: ArchiveProperties?
        startManagedArchiveTask(
            title: L10n.format("metadata.taskTitle", displayName),
            kind: .test,
            showsDetails: false,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                guard let self else { return }
                self.archiveMetadataReport = ArchiveMetadataReport(
                    archiveName: displayName,
                    archivePath: url.path,
                    properties: properties,
                    aggregate: aggregate,
                    headerComment: ArchiveService.headerComment(for: url),
                    securityFindingCount: securityFindingCount
                )
            },
            onSucceeded: { [weak self] task in
                let report = ArchiveMetadataReport(
                    archiveName: displayName,
                    archivePath: url.path,
                    properties: properties,
                    aggregate: aggregate,
                    headerComment: ArchiveService.headerComment(for: url),
                    securityFindingCount: securityFindingCount
                )
                task.openReport = { self?.archiveMetadataReport = report }
                // 0.4.4:报告本体随历史落盘 —— 重启后仍可打开。
                task.reportAttachment = .metadata(report)
            },
            rerunAction: { [weak self] in self?.showArchiveMetadataReport() }
        ) { operationID, progress, _ in
            // 头部块读不出(加密 header 没密码 / 非 7zz 格式)→ properties 留 nil,聚合照常出报告。
            for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                if let parsed = try? await ArchiveService.archiveProperties(of: url, password: password, operationID: operationID) {
                    properties = parsed
                    break
                }
            }
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - 数据救援(0.4.4 #8)

    /// 右键损坏归档「尝试数据救援…」:7zz 兜底解坏包(CRC 错继续解 / 中央目录坏扫 local header)。
    /// 只读救援 —— 原包永不被改动;安全检查不放松;救援目录唯一化绝不覆盖。
    func salvageSelectedArchive() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            // `.siz` 打开态:救援对象是磁盘上的 .siz 本体(tar 容器,7zz 兜底可解),
            // 救援目录落在它旁边 —— 不能用 /tmp 的内层临时档案(救出的东西会跟着临时区消失)。
            if let display = archiveDisplayOverride, SignedContainerService.isSIZContainer(display) {
                archiveURL = display
            } else {
                archiveURL = url
            }
        case .folder, .tag:
            archiveURL = selectedFileItems.first(where: { !$0.isDirectory && SignedContainerService.isToolableArchive($0.url) })?.url
        }
        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runArchiveSalvage(archiveURL)
    }

    private func runArchiveSalvage(_ url: URL) {
        var outcome: ArchiveSalvage.Outcome?
        var totalEntryCount: Int?
        startManagedArchiveTask(
            title: L10n.format("salvage.taskTitle", url.lastPathComponent),
            kind: .extract,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                guard let self, let outcome else { return }
                self.status = L10n.format("salvage.done", "\(outcome.rescuedFileCount)")
                self.archiveSalvageReport = ArchiveSalvageReport(
                    archiveName: url.lastPathComponent,
                    outcome: outcome,
                    totalEntryCount: totalEntryCount
                )
            },
            onSucceeded: { [weak self] task in
                guard let outcome else { return }
                var log = [TransferLogEntry(name: outcome.destination.path, action: .added, isDirectory: true)]
                log.append(contentsOf: outcome.failedEntryPaths.map {
                    TransferLogEntry(name: $0, action: .failed, isDirectory: false, detail: L10n.text("salvage.entryFailed"))
                })
                task.transferLog = log
                let total = totalEntryCount
                task.openReport = {
                    self?.archiveSalvageReport = ArchiveSalvageReport(
                        archiveName: url.lastPathComponent,
                        outcome: outcome,
                        totalEntryCount: total
                    )
                }
            },
            rerunAction: { [weak self] in self?.runArchiveSalvage(url) }
        ) { operationID, progress, outputObserver in
            // 列目录:静默试口令。列不动照样救(7zz local header 兜底);列得动先过路径安全检查。
            // `.siz` 不解包、按 tar 容器整体救(force 跳过扩展名路由)——容器坏时 unwrap 本身就不可靠,
            // 救出内层 archive + metadata 让用户接着处理才是「尽力而为」的诚实形态。
            let force = SignedContainerService.isSIZContainer(url)
            var items: [ArchiveItem]?
            var usablePassword = ""
            for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                if let listed = try? await ArchiveService.list(url, password: password, operationID: operationID, force: force) {
                    items = listed
                    usablePassword = password
                    break
                }
            }
            totalEntryCount = items?.filter { !$0.isDirectory }.count
            progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: L10n.text("salvage.running")))
            let result = try await ArchiveSalvage.run(
                archive: url,
                listedItems: items,
                password: usablePassword,
                operationID: operationID,
                outputObserver: outputObserver
            )
            outcome = result
            if result.rescuedFileCount == 0 {
                // 一个都没救出来:清掉空救援目录,任务如实失败。
                try? FileManager.default.removeItem(at: result.destination)
                throw ArchiveError.commandFailed(L10n.text("salvage.nothingRescued"))
            }
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - 归档体检批处理(0.4.4 #7)

    /// 右键「批量体检」:多选归档 → 体检选中的;单选文件夹 → 体检该文件夹顶层全部归档。
    /// 串行逐包(单包失败不中断);密码**只走会话缓存静默试,绝不弹窗** —— 解不开如实标「需要密码」。
    func checkupSelectedArchives() {
        var urls = selectedFileItems.filter { !$0.isDirectory && SignedContainerService.isToolableArchive($0.url) }.map(\.url)
        var scopeName = L10n.format("checkup.scope.selection", "\(urls.count)")
        if urls.isEmpty,
           selectedFileItems.count == 1,
           let folder = selectedFileItems.first, folder.isDirectory, !folder.isPackage {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.url.path)) ?? []
            urls = names
                .map { folder.url.appendingPathComponent($0) }
                .filter { SignedContainerService.isToolableArchive($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            scopeName = folder.url.lastPathComponent
        }
        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runArchiveCheckup(urls, scopeName: scopeName)
    }

    private func runArchiveCheckup(_ urls: [URL], scopeName: String) {
        var rows: [ArchiveCheckupRow] = []
        startManagedArchiveTask(
            title: L10n.format("checkup.taskTitle", "\(urls.count)"),
            kind: .test,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.archiveCheckupReport = ArchiveCheckupReport(scopeName: scopeName, rows: rows)
            },
            onSucceeded: { [weak self] task in
                task.transferLog = rows.map { row in
                    let passed: Bool = { if case .passed = row.testOutcome { return true } else { return false } }()
                    return TransferLogEntry(name: row.fileName, action: passed ? .passed : .failed, isDirectory: false)
                }
                task.openReport = { self?.archiveCheckupReport = ArchiveCheckupReport(scopeName: scopeName, rows: rows) }
            },
            rerunAction: { [weak self] in self?.runArchiveCheckup(urls, scopeName: scopeName) }
        ) { operationID, progress, outputObserver in
            var duplicateSources: [ArchiveDuplicateScan.Source] = []
            for (index, url) in urls.enumerated() {
                progress(ArchiveProgressState(
                    fraction: Double(index) / Double(urls.count),
                    currentFile: url.lastPathComponent
                ))
                outputObserver?("\n== \(url.lastPathComponent)\n")
                // `.siz`:体检跑在 unwrap 出的内层 archive 上(A5);解不开容器 = 如实标「无法列出」。
                var effectiveURL = url
                var sizTempRoot: URL?
                defer { if let sizTempRoot { try? FileManager.default.removeItem(at: sizTempRoot) } }
                if SignedContainerService.isSIZContainer(url) {
                    do {
                        let unwrapped = try await SignedContainerService.unwrapAndVerifySIZ(at: url)
                        effectiveURL = unwrapped.innerArchiveURL
                        sizTempRoot = unwrapped.tempRoot
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        rows.append(ArchiveCheckupRow(
                            fileName: url.lastPathComponent,
                            testOutcome: .notListable,
                            facts: nil,
                            missingVolumeCount: 0,
                            readOnlyFormat: false
                        ))
                        continue
                    }
                }
                // ① 列目录:空口令 + 会话缓存逐个静默试(不弹窗)。
                var items: [ArchiveItem]?
                var usablePassword = ""
                var lastError: Error?
                for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                    do {
                        items = try await ArchiveService.list(effectiveURL, password: password, operationID: operationID)
                        usablePassword = password
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                // ② 缺分卷 / 只读格式(不依赖能否打开)。
                let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
                let missingVolumes = FileSplitCombine.volumeSet(forMemberNamed: url.lastPathComponent, among: siblings)?.missingIndices.count ?? 0
                let readOnly = ArchiveService.entryUpdateRestriction(forExtension: url.pathExtension) != nil
                guard let items else {
                    let needsPassword = lastError.map { ArchiveService.errorSuggestsPasswordRequirement($0) } ?? false
                    rows.append(ArchiveCheckupRow(
                        fileName: url.lastPathComponent,
                        testOutcome: needsPassword ? .needsPassword : .notListable,
                        facts: nil,
                        missingVolumeCount: missingVolumes,
                        readOnlyFormat: readOnly
                    ))
                    continue
                }
                // ③ 条目侧事实(可疑路径 / 垃圾 / 加密)。
                let facts = ArchiveCheckup.entryFacts(items: items)
                // ④ 完整性测试(用列目录成功的同一口令;失败归类,不中断整批)。
                var outcome = ArchiveCheckupRow.TestOutcome.passed
                do {
                    try await ArchiveService.test(effectiveURL, password: usablePassword, operationID: operationID, outputObserver: outputObserver)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcome = .failed(ArchiveService.classifyTestFailure(error.localizedDescription))
                }
                rows.append(ArchiveCheckupRow(
                    fileName: url.lastPathComponent,
                    testOutcome: outcome,
                    facts: facts,
                    missingVolumeCount: missingVolumes,
                    readOnlyFormat: readOnly
                ))
                let files = items.filter { !$0.isDirectory }
                duplicateSources.append(ArchiveDuplicateScan.Source(
                    url: url,
                    fingerprint: ArchiveStructuralFingerprint.compute(for: items),
                    entryCount: files.count,
                    totalBytes: files.reduce(0) { $0 + ($1.size ?? 0) }
                ))
            }
            // ⑤ 疑似同包(结构指纹相同):跑完整批后标注互为伙伴。
            for group in ArchiveDuplicateScan.groups(from: duplicateSources) {
                let names = group.urls.map(\.lastPathComponent)
                for index in rows.indices where names.contains(rows[index].fileName) {
                    rows[index].duplicatePeers = names.filter { $0 != rows[index].fileName }
                }
            }
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - 发布目录完整性检查(0.4.4 #11)

    /// 右键文件夹「检查发布目录…」:SHA256SUMS 覆盖与实测 / .szs 清单文件级核对 / VERIFY.md 引用 /
    /// 随包公钥独立验签(临时 GNUPGHOME) / 孤儿文件。**只读** —— 不改目录里任何文件。
    func auditSelectedReleaseDirectory() {
        guard let directory = selectedFileItems.first(where: { $0.isDirectory && !$0.isPackage })?.url else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runReleaseDirectoryAudit(directory)
    }

    private func runReleaseDirectoryAudit(_ directory: URL) {
        var findings: [ReleaseDirectoryAuditFinding] = []
        startManagedArchiveTask(
            title: L10n.format("dirAudit.taskTitle", directory.lastPathComponent),
            kind: .test,
            showsDetails: false,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.releaseDirectoryAuditReport = ReleaseDirectoryAuditReport(directoryURL: directory, findings: findings)
            },
            onSucceeded: { [weak self] task in
                task.openReport = { self?.releaseDirectoryAuditReport = ReleaseDirectoryAuditReport(directoryURL: directory, findings: findings) }
            },
            rerunAction: { [weak self] in self?.runReleaseDirectoryAudit(directory) }
        ) { operationID, progress, _ in
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let inventory = ReleaseDirectoryAudit.classify(names: names) { name in
                ArchiveService.isSupportedArchive(directory.appendingPathComponent(name))
            }

            // ① SHA256SUMS:覆盖情况 + 在场条目逐个实测哈希。
            if inventory.checksumFiles.isEmpty {
                if !inventory.artifacts.isEmpty {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .warning, message: L10n.text("dirAudit.noChecksums")))
                }
            } else {
                for sumsName in inventory.checksumFiles {
                    let sumsURL = directory.appendingPathComponent(sumsName)
                    guard let sumsText = try? String(contentsOf: sumsURL, encoding: .utf8) else {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .failure, message: L10n.format("dirAudit.checksumUnreadable", sumsName)))
                        continue
                    }
                    let entries = ChecksumFile.parse(sumsText, fileName: sumsName)
                    let coverage = ReleaseDirectoryAudit.checksumCoverage(entryNames: entries.map(\.name), artifacts: inventory.artifacts)
                    if coverage.uncovered.isEmpty, coverage.stale.isEmpty, !entries.isEmpty {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .pass, message: L10n.format("dirAudit.checksumCoverage.ok", sumsName)))
                    }
                    if !coverage.uncovered.isEmpty {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .warning, message: L10n.format("dirAudit.checksumCoverage.uncovered", "\(coverage.uncovered.count)"), detailItems: coverage.uncovered))
                    }
                    if !coverage.stale.isEmpty {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .warning, message: L10n.format("dirAudit.checksumCoverage.stale", sumsName, "\(coverage.stale.count)"), detailItems: coverage.stale))
                    }
                    var mismatches: [String] = []
                    var verified = 0
                    let presentEntries = entries.filter { names.contains($0.name) }
                    for (index, entry) in presentEntries.enumerated() {
                        progress(ArchiveProgressState(
                            fraction: Double(index) / Double(max(presentEntries.count, 1)),
                            currentFile: entry.name
                        ))
                        let fileURL = directory.appendingPathComponent(entry.name)
                        let digest = try? await Task.detached(priority: .userInitiated) {
                            try HashService.sha256(for: fileURL)
                        }.value
                        if let digest, digest.lowercased() == entry.digestHex.lowercased() {
                            verified += 1
                        } else {
                            mismatches.append(entry.name)
                        }
                    }
                    if mismatches.isEmpty, verified > 0 {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .pass, message: L10n.format("dirAudit.hashes.ok", "\(verified)")))
                    } else if !mismatches.isEmpty {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .failure, message: L10n.format("dirAudit.hashes.mismatch", "\(mismatches.count)"), detailItems: mismatches))
                    }
                }
            }

            // ② .szs 清单的文件级核对(SHA;签名真伪在④)。.siz 是单文件容器,不在目录核对范围。
            let szsNames = inventory.containers.filter { $0.lowercased().hasSuffix(".szs") }
            for containerName in szsNames {
                let containerURL = directory.appendingPathComponent(containerName)
                if let manifestReport = try? SZSArchive.verifyWithoutSignature(manifestURL: containerURL, payloadRoot: directory, allowNewerVersion: true) {
                    let summary = manifestReport.summary
                    if summary.mismatched == 0, summary.missing == 0, summary.unreadable == 0 {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .pass, message: L10n.format("dirAudit.manifest.ok", containerName, "\(summary.matched)")))
                    } else {
                        let problems = manifestReport.entries.compactMap { entry -> String? in
                            if case .match = entry { return nil }
                            return entry.relativePath
                        }
                        findings.append(ReleaseDirectoryAuditFinding(severity: .failure, message: L10n.format("dirAudit.manifest.problems", containerName, "\(summary.mismatched + summary.missing + summary.unreadable)"), detailItems: problems))
                    }
                } else {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .failure, message: L10n.format("dirAudit.manifest.unreadable", containerName)))
                }
            }

            // ③ VERIFY.md 引用的文件名还在不在(改名/删除后文档忘更新)。
            for docName in inventory.verifyDocs {
                guard let docText = try? String(contentsOf: directory.appendingPathComponent(docName), encoding: .utf8) else { continue }
                let missing = ReleaseDirectoryAudit.missingDocumentReferences(documentText: docText, directoryNames: names)
                if missing.isEmpty {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .pass, message: L10n.format("dirAudit.docRefs.ok", docName)))
                } else {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .warning, message: L10n.format("dirAudit.docRefs.missing", docName, "\(missing.count)"), detailItems: missing))
                }
            }

            // ④ 随包公钥独立验签(收件人视角,临时 GNUPGHOME 只读,不碰用户钥匙环)。
            //    A4:GPG 关 / 多义(多把公钥或多份 .szs)→ 如实报「已跳过」,不静默不瞎猜。
            if !szsNames.isEmpty {
                if inventory.publicKeys.isEmpty {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .warning, message: L10n.text("inspect.publicKey.missing")))
                } else if AppPreferences.gpgEnabled, GPGBackend.isAvailable(), szsNames.count == 1, inventory.publicKeys.count == 1 {
                    let result = try? await GPGBackend.verifyClearsignWithIsolatedKey(
                        publicKeyURL: directory.appendingPathComponent(inventory.publicKeys[0]),
                        signedURL: directory.appendingPathComponent(szsNames[0]),
                        operationID: operationID
                    )
                    if let result, case .validSignature = result {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .pass, message: L10n.format("dirAudit.isolatedVerify.ok", inventory.publicKeys[0], szsNames[0])))
                    } else {
                        findings.append(ReleaseDirectoryAuditFinding(severity: .failure, message: L10n.format("dirAudit.isolatedVerify.bad", inventory.publicKeys[0], szsNames[0])))
                    }
                } else {
                    findings.append(ReleaseDirectoryAuditFinding(severity: .info, message: L10n.text("dirAudit.isolatedVerify.skipped")))
                }
            }

            // ⑤ 孤儿文件:既不是产物也不是已知发布角色 —— 不一定是问题,过目用。
            let orphans = ReleaseDirectoryAudit.orphans(in: inventory)
            if !orphans.isEmpty {
                findings.append(ReleaseDirectoryAuditFinding(severity: .info, message: L10n.format("dirAudit.orphans", "\(orphans.count)"), detailItems: orphans))
            }
            if findings.isEmpty {
                findings.append(ReleaseDirectoryAuditFinding(severity: .info, message: L10n.text("dirAudit.nothingToCheck")))
            }
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - 发布包检查（0.4.2 #15）

    /// 一次发布包检查的结果。条目侧统计在 Core（ReleaseInspection），这里聚合 测试 / SHA-256 / 注释。
    struct ReleaseInspectionReport: Identifiable, Codable {
        let id = UUID()
        /// Codable 排除 `id`(带初值的 let 不能解码)—— 0.4.4 报告随任务历史持久化用。
        private enum CodingKeys: String, CodingKey {
            case archiveURL, listable, stats, securityFindings, testPassed, testFailureMessage
            case sha256, hasComment, publicKeyBesideSignature, structuralFingerprint
            case bundleFindings, isBundleOnly, gateViolations, steps
        }
        let archiveURL: URL
        var listable = false
        var stats: ReleaseInspectionStats?
        var securityFindings: [ArchiveSecurityFinding] = []
        var testPassed: Bool?
        var testFailureMessage: String?
        var sha256: String?
        var hasComment = false
        /// 公钥分发检查:归档同目录有签名容器(.szs/.siz)时,旁边有没有可分发的公钥(.asc)。
        /// nil = 目录里没有签名容器,报告不显示该行;false = 有容器没公钥(收件人无法独立验证,提醒)。
        var publicKeyBesideSignature: Bool?
        /// 结构指纹(#9):条目结构(路径/类型/大小/CRC)的 SHA-256,忽略时间戳/注释/垃圾 ——
        /// 两个包指纹相同 = 结构上同一份东西(哪怕重新打包、文件级 SHA-256 不同)。listable 才有。
        var structuralFingerprint: String?
        /// #6 专项检查:目标是 .app/.dmg/.xip 时的 bundle 级结论(Info.plist/codesign/spctl/
        /// DMG 顶层结构/XIP 签名)。空 = 不适用,报告不显示该区。
        var bundleFindings: [BundleReleaseCheck.Finding] = []
        /// true = 直接对 .app 目录跑的检查 —— 归档侧区块(完整性测试/条目/SHA-256)整段不渲染。
        var isBundleOnly = false
        /// #10:质量门触发的违规(发布助手跑、且开了规则才非空;阻断的运行不会走到报告 sheet)。
        var gateViolations: [ReleaseGate.Violation] = []
        /// C:本次发布运行的步骤耗时(右键检查流程为空 —— 它没有步骤引擎)。
        var steps: [ReleaseRunStep] = []
    }

    /// 同目录的「签名容器 ↔ 公钥」同捆检查(发包端闭环):有 .szs/.siz 而没有任何 .asc → 提醒。
    nonisolated static func publicKeyPresenceBesideSignature(at directory: URL) -> Bool? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let lowered = names.map { $0.lowercased() }
        let hasContainer = lowered.contains { $0.hasSuffix(".\(SZSArchive.extensionName)") || $0.hasSuffix(".\(SIZArchive.extensionName)") }
        guard hasContainer else { return nil }
        return lowered.contains { $0.hasSuffix(".asc") }
    }

    /// 右键「发布包检查…」：对选中的单个归档跑一套发布前检查（能否解压 / 危险路径 / 垃圾 /
    /// 空目录 / 大小写冲突 / symlink / 可执行权限 / SHA-256），出报告 sheet。
    func inspectSelectedArchiveForRelease() {
        let archiveURL: URL?
        switch mode {
        case .archive(let url):
            // `.siz` 打开态:检查对象是真正的发布物(.siz 本体,SHA/公钥同捆都对它),不是 /tmp 内层。
            if let display = archiveDisplayOverride, SignedContainerService.isSIZContainer(display) {
                archiveURL = display
            } else {
                archiveURL = url
            }
        case .folder, .tag:
            // #6:单选 .app 目录 → 纯 bundle 检查(Info.plist/codesign/Gatekeeper),不走归档管线。
            if selectedFileItems.count == 1, let item = selectedFileItems.first,
               BundleReleaseCheck.Target.detect(at: item.url) == .appBundle {
                runAppBundleInspection(item.url)
                return
            }
            archiveURL = selectedFileItems.first(where: { SignedContainerService.isToolableArchive($0.url) })?.url
        }
        guard let archiveURL else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        runReleaseInspection(archiveURL)
    }

    /// #6:.app 目录的专项发布检查(只读;只签名校验不签名)。
    private func runAppBundleInspection(_ url: URL) {
        var report = ReleaseInspectionReport(archiveURL: url)
        report.isBundleOnly = true
        startManagedArchiveTask(
            title: L10n.format("inspect.taskTitle", url.lastPathComponent),
            kind: .test,
            showsDetails: true,
            successStatus: nil,
            refreshOnSuccess: { [weak self] in
                self?.releaseInspectionReport = report
            },
            onSucceeded: { [weak self] task in
                task.openReport = { self?.releaseInspectionReport = report }
                task.reportAttachment = .releaseInspection(report)
            },
            rerunAction: { [weak self] in self?.runAppBundleInspection(url) }
        ) { operationID, progress, outputObserver in
            progress(ArchiveProgressState(fraction: 0.2, statusText: nil))
            report.bundleFindings = await BundleReleaseCheck.inspectAppBundle(
                at: url, operationID: operationID, outputObserver: outputObserver
            )
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    /// #8 空间分析:打开的归档直接用已列出的条目(瞬时);文件夹里单选归档则先列出(托管任务)。
    func analyzeSelectedArchiveSpace() {
        switch mode {
        case .archive(let url):
            spaceAnalysisReport = ArchiveSpaceAnalysisReport(
                archiveName: (archiveDisplayOverride ?? url).lastPathComponent,
                analysis: ArchiveSpaceAnalysis.analyze(session.allItems)
            )
        case .folder, .tag:
            guard let archiveURL = selectedFileItems.first(where: { SignedContainerService.isToolableArchive($0.url) })?.url else {
                errorMessage = L10n.text("error.openOrSelectArchive")
                return
            }
            runSpaceAnalysisTask(for: archiveURL)
        }
    }

    /// E:按 URL 跑空间分析(发布检查报告「打开空间分析」跳转也走这里 —— 数据同源,不依赖选区)。
    func runSpaceAnalysisTask(for archiveURL: URL) {
            let force = isForced(archiveURL)
            var computedAnalysis: ArchiveSpaceAnalysis?
            startManagedArchiveTask(
                title: L10n.format("space.taskTitle", archiveURL.lastPathComponent),
                kind: .test,
                showsDetails: false,
                successStatus: nil,
                onSucceeded: { [weak self] task in
                    // 报告可从活动中心重开(与发布检查同款;运行时态)。
                    task.openReport = {
                        guard let analysis = computedAnalysis else { return }
                        self?.spaceAnalysisReport = ArchiveSpaceAnalysisReport(
                            archiveName: archiveURL.lastPathComponent,
                            analysis: analysis
                        )
                    }
                },
                rerunAction: { [weak self] in self?.runSpaceAnalysisTask(for: archiveURL) }
            ) { [weak self] operationID, _, _ in
                // `.siz`:分析对象是内层 archive 的条目(A5)。
                var items: [ArchiveItem] = []
                try await SignedContainerService.withToolAdaptedArchive(archiveURL) { target in
                    for password in [""] + SessionPasswordCache.shared.candidates(for: archiveURL) {
                        if let listed = try? await ArchiveService.list(target, password: password, operationID: operationID, force: force) {
                            items = listed
                            break
                        }
                    }
                }
                guard !items.isEmpty else {
                    throw ArchiveError.commandFailed(L10n.text("inspect.notListable"))
                }
                let analysis = ArchiveSpaceAnalysis.analyze(items)
                computedAnalysis = analysis
                await MainActor.run {
                    self?.spaceAnalysisReport = ArchiveSpaceAnalysisReport(
                        archiveName: archiveURL.lastPathComponent,
                        analysis: analysis
                    )
                }
            }
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
            onSucceeded: { [weak self] task in
                // 用户点名:报告可从活动中心重开,不必重跑;0.4.4 报告本体随历史落盘,重启后照旧。
                task.openReport = { self?.releaseInspectionReport = report }
                task.reportAttachment = .releaseInspection(report)
            },
            rerunAction: { [weak self] in self?.runReleaseInspection(url) }
        ) { operationID, progress, outputObserver in
            // `.siz`:条目侧检查(列目录/测试/指纹/注释)跑在 unwrap 出的内层 archive 上(A5);
            // ③ 起的 SHA-256 / 公钥同捆 / 专项检查仍对外层 .siz —— 它才是用户实际分发的产物。
            var items: [ArchiveItem] = []
            try await SignedContainerService.withToolAdaptedArchive(url) { target in
                // ① 列目录：空口令 + 会话缓存里的口令逐个静默试；全失败 = 读不了条目（报告里如实标注）。
                progress(ArchiveProgressState(fraction: 0.1, statusText: nil))
                for password in [""] + SessionPasswordCache.shared.candidates(for: url) {
                    if let listed = try? await ArchiveService.list(target, password: password, force: force) {
                        items = listed
                        report.listable = true
                        break
                    }
                }
                if report.listable {
                    report.stats = ReleaseInspection.stats(for: items)
                    report.securityFindings = ArchiveSecurityReport.analyze(items)
                    report.hasComment = !ArchiveService.headerComment(for: target).isEmpty
                    report.structuralFingerprint = ArchiveStructuralFingerprint.compute(for: items)
                }
                // ② 完整性测试（失败不让任务失败 —— 失败本身就是报告内容）。
                progress(ArchiveProgressState(fraction: 0.4, statusText: nil))
                do {
                    try await ArchiveService.test(target, operationID: operationID, force: force, outputObserver: outputObserver)
                    report.testPassed = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    report.testPassed = false
                    report.testFailureMessage = error.localizedDescription
                }
            }
            // ③ SHA-256（发布说明 / 校验文件用）。
            progress(ArchiveProgressState(fraction: 0.8, statusText: nil))
            report.sha256 = try? await Task.detached(priority: .userInitiated) {
                try HashService.sha256(for: url)
            }.value
            // ④ 公钥同捆检查:同目录有签名容器而没有 .asc 公钥 → 报告里提醒(发包端闭环)。
            report.publicKeyBesideSignature = Self.publicKeyPresenceBesideSignature(at: url.deletingLastPathComponent())
            // ⑤ #6 专项检查:DMG(顶层结构/签名/Gatekeeper)与 XIP(签名摘要)在归档检查之上追加。
            switch BundleReleaseCheck.Target.detect(at: url) {
            case .diskImage:
                progress(ArchiveProgressState(fraction: 0.92, statusText: nil))
                report.bundleFindings = await BundleReleaseCheck.inspectDiskImage(
                    at: url, listedItems: report.listable ? items : nil,
                    operationID: operationID, outputObserver: outputObserver
                )
            case .xipArchive:
                progress(ArchiveProgressState(fraction: 0.92, statusText: nil))
                report.bundleFindings = await BundleReleaseCheck.inspectXIP(
                    at: url, operationID: operationID, outputObserver: outputObserver
                )
            case .appBundle, .none:
                break
            }
            progress(ArchiveProgressState(fraction: 1.0, statusText: nil))
        }
    }

    // MARK: - #111 归档比较

    /// 右键「比较归档」入口：选中 2 个归档直接比；选中 1 个时用 NSOpenPanel 挑第二个。
    /// 菜单项只在这两种选区下出现，这里的兜底报错只防御直接调用。
    func compareSelectedArchives() {
        // 0.4.2 #25:可比对的「侧」= 受支持归档 或 文件夹(0.4.4:含 .siz,比内层条目)。
        let comparableURLs = selectedFileItems
            .filter { $0.isDirectory || SignedContainerService.isToolableArchive($0.url) }
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
            guard exists, isDirectory.boolValue || SignedContainerService.isToolableArchive(other) else {
                errorMessage = L10n.text("error.openOrSelectArchive")
                return
            }
            runArchiveComparison(left: first, right: other)
        }
    }

    /// 列出两个包 → Core `ArchiveDiff.compare` → 弹结果 sheet。走托管归档任务（活动中心可见、可取消）。
    /// 加密归档按现状用空密码列出 —— header 加密的包会直接以后端错误失败，错误对用户可见，不静默吞。
    func runArchiveComparison(left: URL, right: URL, source: OperationTask.Source = .app) {
        let title = L10n.format("status.comparing", left.lastPathComponent, right.lastPathComponent)
        let forceLeft = isForced(left)
        let forceRight = isForced(right)
        // 0.4.2 #25：「这一侧是文件夹还是归档」在主 actor 上**预判**（isSupportedArchive 是
        // 主 actor 隔离的），把结论传进后台闭包 —— 闭包里不再碰隔离 API。
        let leftIsFolder = Self.urlIsPlainDirectory(left) && !ArchiveService.isSupportedArchive(left)
        let rightIsFolder = Self.urlIsPlainDirectory(right) && !ArchiveService.isSupportedArchive(right)
        startManagedArchiveTask(
            title: title,
            kind: .compare,
            source: source,
            showsDetails: false,
            successStatus: L10n.text("status.compared"),
            // 把结构化结果挂到任务上 —— 活动中心详情渲染和弹窗同款的分区树。
            // 时序：operation 闭包先在 MainActor 上写 archiveDiffReport，任务才被标成功，这里读到的就是本次结果。
            onSucceeded: { [weak self] task in
                task.diffReport = self?.archiveDiffReport
            }
        ) { [weak self] operationID, _, _ in
            // 0.4.2 #25:任一侧是文件夹 → 文件系统快照;是归档 → 照常列出。归档 vs 文件夹随便混。
            // 0.4.4:`.siz` 侧比的是内层 archive 的条目(A5)。
            let leftItems = try await SignedContainerService.withToolAdaptedArchive(left) {
                try await Self.comparisonItems(for: $0, isFolder: leftIsFolder, operationID: operationID, force: forceLeft)
            }
            let rightItems = try await SignedContainerService.withToolAdaptedArchive(right) {
                try await Self.comparisonItems(for: $0, isFolder: rightIsFolder, operationID: operationID, force: forceRight)
            }
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

    // MARK: - .szs 清单 vs 当前文件夹（0.4.2 #26）

    /// 右键 .szs「与当前文件夹比较」：清单条目 vs 同目录现状的结构比较 ——
    /// **新增** = 目录里出现的未签名新文件；**删除** = 清单里有但目录里没了；**修改** = 大小变了。
    /// 清单不存 mtime → 时间维度自动不比；这是快速结构对照，逐字节核验请走完整验证（双击 .szs）。
    /// 复用归档比较的报告 sheet —— 导出 JSON / CSV / Markdown 全部白送。
    func compareSelectedSZSWithFolder() {
        guard case .folder = mode,
              let szsURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SZSArchive.extensionName })?.url else { return }
        runSZSFolderComparison(szsURL)
    }

    private func runSZSFolderComparison(_ szsURL: URL) {
        let folderURL = szsURL.deletingLastPathComponent()
        let szsName = szsURL.lastPathComponent
        startManagedArchiveTask(
            title: L10n.format("status.comparing", szsName, folderURL.lastPathComponent),
            kind: .compare,
            showsDetails: false,
            successStatus: L10n.text("status.compared"),
            onSucceeded: { [weak self] task in
                task.diffReport = self?.archiveDiffReport
            },
            rerunAction: { [weak self] in self?.runSZSFolderComparison(szsURL) }
        ) { [weak self] _, _, _ in
            // 结构比较不验签（extractClearsignedManifest 只解析 armor 内 JSON）——
            // 签名真伪与逐文件 SHA 由完整验证流程负责，这里比的是「清单 vs 目录现状」的形状。
            let manifest = try SZSArchive.extractClearsignedManifest(manifestURL: szsURL)
            let manifestItems = manifest.files.map { entry in
                ArchiveItem(
                    name: entry.relativePath,
                    isDirectory: false,
                    size: Int64(entry.size),
                    modified: nil,
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file),
                    modifiedText: "",
                    method: ""
                )
            }
            let folderSnapshot = await Task.detached(priority: .userInitiated) {
                ArchiveDiff.folderItems(at: folderURL)
            }.value
            // 清单只记文件：目录条目剔除；.szs 自己也剔除（它不该算「未签名新增」）。
            let folderFiles = folderSnapshot.filter { !$0.isDirectory && $0.name != szsName }
            let result = ArchiveDiff.compare(left: manifestItems, right: folderFiles)
            await MainActor.run {
                self?.archiveDiffReport = ArchiveDiffReport(
                    leftName: szsName,
                    rightName: folderURL.lastPathComponent,
                    result: result
                )
            }
        }
    }

    /// URL 是否是普通目录（存在且 isDirectory）。主 actor 上给 runArchiveComparison 预判用。
    private static func urlIsPlainDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// 比较的一侧取条目:文件夹 → 文件系统快照;否则按归档列出。`isFolder` 由调用方在主 actor 预判
    ///（isSupportedArchive 是主 actor 隔离的,不能在本 nonisolated 函数里调）。
    nonisolated private static func comparisonItems(for url: URL, isFolder: Bool, operationID: UUID?, force: Bool) async throws -> [ArchiveItem] {
        if isFolder {
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
        calculateHash(for: urls, algorithms: HashAlgorithm.allCases, source: .finder)
    }

    private func calculateHash(for urls: [URL], algorithms: [HashAlgorithm], source: OperationTask.Source = .app) {
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
            source: source,
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

// MARK: - 0.4.3 #11 校验文件(SHA256SUMS / .sha256 / .md5 / .sfv)

extension ArchiveBrowserModel {

    /// 右键「生成 SHA256SUMS」:对选中的非目录文件各算 SHA-256,在当前文件夹写一份 GNU 兼容的
    /// SHA256SUMS(`sha256sum -c` 直接可验)。同名按「SHA256SUMS 2」避让,绝不覆盖。
    func generateChecksumFileForSelection() {
        guard case .folder(let folderURL) = mode else { return }
        let files = selectedFileItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        writeSHA256SUMS(for: files.map { (name: $0.name, url: $0.url) }, in: folderURL)
    }

    /// 发布检查「导出 SHA256SUMS」:对单个归档在其所在目录写校验文件(非 SimpleZip 用户也能验证)。
    func exportSHA256SUMS(forArchiveAt url: URL) {
        writeSHA256SUMS(for: [(name: url.lastPathComponent, url: url)], in: url.deletingLastPathComponent())
    }

    private func writeSHA256SUMS(for files: [(name: String, url: URL)], in folderURL: URL) {
        let operationTask = TaskCenter.shared.begin(
            category: .fileOperation,
            kind: .hash,
            title: L10n.format("checksum.generate.taskTitle", "\(files.count)"),
            cancellable: true
        )
        TaskCenter.shared.notifyTaskChanged()
        var swiftTask: Task<Void, Never>?
        operationTask.cancel = { swiftTask?.cancel() }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            do {
                var entries: [(name: String, digestHex: String)] = []
                for file in files {
                    try Task.checkCancellation()
                    operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: file.name, statusText: nil)
                    TaskCenter.shared.notifyTaskChanged()
                    let url = file.url
                    let digest = try await Task.detached(priority: .userInitiated) {
                        try HashService.sha256(for: url)
                    }.value
                    entries.append((name: file.name, digestHex: digest))
                }
                let preferred = folderURL.appendingPathComponent("SHA256SUMS")
                let destination = UniqueFileName.suffixed(for: preferred, suffix: "") {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try ChecksumFile.generateSHA256SUMS(entries).write(to: destination, atomically: true, encoding: .utf8)
                operationTask.transferLog = entries.map {
                    TransferLogEntry(name: $0.name, action: .passed, isDirectory: false, detail: $0.digestHex)
                }
                status = L10n.format("checksum.generate.done", destination.lastPathComponent)
                TaskCenter.shared.finish(operationTask, outcome: .succeeded(destination))
                reload()
            } catch is CancellationError {
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                errorMessage = error.localizedDescription
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// 右键「验证校验文件」:解析(GNU / BSD / SFV / 单摘要 sidecar),对同目录的每个目标重算
    /// 对应算法的摘要比对。不匹配 / 缺失 / 不安全路径 → 任务失败并逐行列明;全过 = 成功。
    func verifyChecksumFile(_ item: FileItem) {
        let checksumURL = item.url
        let baseDir = checksumURL.deletingLastPathComponent()
        guard let text = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            errorMessage = L10n.text("checksum.verify.unreadable")
            return
        }
        let entries = ChecksumFile.parse(text, fileName: checksumURL.lastPathComponent)
        guard !entries.isEmpty else {
            errorMessage = L10n.text("checksum.verify.noEntries")
            return
        }

        let operationTask = TaskCenter.shared.begin(
            category: .fileOperation,
            kind: .hash,
            title: L10n.format("checksum.verify.taskTitle", checksumURL.lastPathComponent),
            cancellable: true
        )
        TaskCenter.shared.notifyTaskChanged()
        var swiftTask: Task<Void, Never>?
        operationTask.cancel = { swiftTask?.cancel() }
        swiftTask = Task { @MainActor [weak self, weak operationTask] in
            guard let self, let operationTask else { return }
            do {
                var rows: [TransferLogEntry] = []
                var failureCount = 0
                for entry in entries {
                    try Task.checkCancellation()
                    operationTask.progress = ArchiveProgressState(fraction: nil, currentFile: entry.name, statusText: nil)
                    TaskCenter.shared.notifyTaskChanged()
                    // 校验文件是不可信输入:名字带 `..` / 绝对路径 / 反斜杠逃逸 → 不碰文件系统,按失败记。
                    let separatorNormalized = entry.name.replacingOccurrences(of: "\\", with: "/")
                    if entry.name.hasPrefix("/")
                        || separatorNormalized.split(separator: "/").contains("..") {
                        rows.append(TransferLogEntry(name: entry.name, action: .failed, isDirectory: false,
                                                     detail: L10n.text("checksum.verify.unsafePath")))
                        failureCount += 1
                        continue
                    }
                    let target = baseDir.appendingPathComponent(entry.name)
                    guard FileManager.default.fileExists(atPath: target.path) else {
                        rows.append(TransferLogEntry(name: entry.name, action: .failed, isDirectory: false,
                                                     detail: L10n.text("checksum.verify.missing")))
                        failureCount += 1
                        continue
                    }
                    guard let algorithm = HashAlgorithm(rawValue: entry.algorithm.rawValue) else { continue }
                    let report = try await HashService.calculate(for: [target], includeHiddenFiles: true, algorithms: [algorithm])
                    let actual = report.results.first?.hashes[algorithm]?.lowercased() ?? ""
                    if actual == entry.digestHex {
                        rows.append(TransferLogEntry(name: entry.name, action: .passed, isDirectory: false,
                                                     detail: entry.algorithm.rawValue))
                    } else {
                        rows.append(TransferLogEntry(name: entry.name, action: .failed, isDirectory: false,
                                                     detail: L10n.format("checksum.verify.mismatch", entry.algorithm.rawValue)))
                        failureCount += 1
                    }
                }
                operationTask.transferLog = rows
                if failureCount == 0 {
                    let done = L10n.format("checksum.verify.allPassed", "\(entries.count)")
                    status = done
                    operationTask.progress = ArchiveProgressState(fraction: 1, currentFile: nil, statusText: done)
                    TaskCenter.shared.finish(operationTask, outcome: .succeeded(nil))
                } else {
                    let message = L10n.format("checksum.verify.failures", "\(failureCount)", "\(entries.count)")
                    errorMessage = message
                    TaskCenter.shared.finish(operationTask, outcome: .failed(message))
                }
            } catch is CancellationError {
                TaskCenter.shared.finish(operationTask, outcome: .cancelled)
            } catch {
                errorMessage = error.localizedDescription
                TaskCenter.shared.finish(operationTask, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
