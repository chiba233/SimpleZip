//
//  ArchiveBrowserModel+CreateExtract.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  创建压缩包 / 解压压缩包 / 选择项目解压 / 单项目在外部打开 / 单项目导出 / SIZ 签名 wrap。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// 归档条目「打开方式」目标 —— 用指定 app 打开,或弹系统 app 选择器。
enum ArchiveOpenWithTarget {
    case app(URL)
    case chooseApp
}

/// 「在外部 app 打开的归档内文件」的写回监视项 —— 记临时副本 + 已知 hash,回前台时比对。
struct PendingArchiveWriteBack {
    let archiveURL: URL
    let entryPath: String
    let tempFileURL: URL
    var lastKnownHash: String
}

extension ArchiveBrowserModel {
    func openArchiveItemExternally(_ item: ArchiveItem, openWith: ArchiveOpenWithTarget? = nil, nestedRecordsReturnLocation: Bool = true) {
        guard case .archive(let archiveURL) = mode else { return }

        if ArchiveSafety.requiresExternalOpenConfirmation(item), !allowPotentiallyUnsafeArchiveItemOpen(item) {
            return
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else { return }
        let detectedZipEncryption = archiveURL.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: archiveURL)
            : .unknown
        let shouldPromptBeforeExtraction = ArchiveService.archiveItemsSuggestPasswordRequirement(entries, in: archiveURL)
        // 普通「在外部 app 打开」单个文件 + 当前是可编辑归档 → 之后监视临时副本变化以便写回。
        let allowWriteBack = openWith == nil && !item.isDirectory && canDropIntoOpenArchive
        let writeBackEntryPath = item.name

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            var extractedDiskImageURL: URL?
            var extractedNestedArchiveURL: URL?
            var extractedSpecialFileURL: URL?
            var registeredWriteBack: PendingArchiveWriteBack?
            let didSucceed = await runArchiveTask(L10n.format("status.openingArchiveItem", item.displayName)) { progress in
                let destination = try self.makeArchiveItemOpenDirectory()
                self.openedArchiveItemDirectories.append(destination)
                try self.confirmArchiveExtractionSafety(entries: entries)
                // 预设密码可用时把它作为首选 —— 这样用户不必看到弹窗（除非预设是错的）。
                // 没有预设时 password 仍是空字符串，原本「先弹窗再尝试」的路径完整保留。
                let hasPreset = AppPreferences.hasUsablePresetPassword
                var password = hasPreset ? AppPreferences.presetPassword : ""
                var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
                var isRetry = false
                // 0.4.2 #9：会话里记过的口令优先静默试（先于弹框）；失败再逐个消耗、最后才弹框。
                var untriedSessionPasswords = SessionPasswordCache.shared.candidates(for: archiveURL).filter { $0 != password }

                if shouldPromptBeforeExtraction && !hasPreset {
                    if !untriedSessionPasswords.isEmpty {
                        password = untriedSessionPasswords.removeFirst()
                    } else {
                        guard let authentication = self.promptForArchiveItemPassword(
                            item: item,
                            archiveURL: archiveURL,
                            detectedZipEncryption: detectedZipEncryption,
                            isRetry: false
                        ) else {
                            throw CancellationError()
                        }
                        password = authentication.password
                        zipDecryptionMethod = authentication.zipDecryptionMethod
                        isRetry = true
                    }
                }

                let force = self.isForced(archiveURL)
                while true {
                    do {
                        try? self.fileManager.removeItem(at: destination)
                        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                        try await ArchiveService.extract(
                            archiveURL,
                            entries: entries,
                            to: destination,
                            overwriteBehavior: .overwrite,
                            pathMode: .preserve,
                            password: password,
                            zipDecryptionMethod: zipDecryptionMethod,
                            safetyPolicy: .skipValidation,
                            operationID: operationID,
                            progress: progress,
                            force: force
                        )
                        try self.confirmExtractedArchiveLinks(at: destination)
                        SessionPasswordCache.shared.record(password, for: archiveURL)

                        let extractedURL = try self.extractedURL(for: item, in: destination)
                        // 「打开方式」：解出来后直接用指定 app / 系统选择器打开,**绕过** dmg/嵌套/.siz 等 in-app 路由
                        // ——用户要的就是「用外部 app 打开这个解出来的文件」。任何格式都适用(不白名单)。
                        if let openWith {
                            switch openWith {
                            case .app(let appURL): OpenWithService.open([extractedURL], withApplicationAt: appURL)
                            case .chooseApp: OpenWithService.chooseApplicationAndOpen([extractedURL])
                            }
                            return
                        }
                        if extractedURL.pathExtension.lowercased() == "dmg" {
                            extractedDiskImageURL = extractedURL
                            return
                        }
                        // **嵌套压缩包的固有问题修复**：解出来的项本身又是受支持压缩包（zip 套 zip、tgz 里的 tar、
                        // 7z 套 tar…）→ 在 app 内打开，**绝不**走 NSWorkspace.open。后者把 /tmp 里的临时档案当外部
                        // 文件按 UTI 转回 SimpleZip → openArchive 拿到的是 /tmp 路径且无 displayedAs → 地址栏 + 上一级
                        // 全暴露 `/var/folders/...`（dmg 必须在此判断**之前**拦掉，它也算 supportedArchive 但走挂载）。
                        if ArchiveService.isSupportedArchive(extractedURL) {
                            extractedNestedArchiveURL = extractedURL
                            return
                        }
                        // **同理 fix 给 SimpleZip 自有特殊类型**：解出来是 `.siz`（签名容器）/ `.szs`（签名清单）/
                        // `.gpg`·`.pgp`·`.asc`·`.key`（加密 / 钥匙串）→ 在**当前窗口**内走各自 in-app 流程，**绝不**
                        // NSWorkspace.open。后者按 UTI 把临时文件转回 SimpleZip 的外部打开 → 新建窗口 / 触发自动解压浮窗
                        // （用户反馈「7z 里的 .siz 打开后新建了个窗口」「zip 里的 .gpg 触发自动解压」的根因）。
                        let extLower = extractedURL.pathExtension.lowercased()
                        if extLower == SIZArchive.extensionName
                            || extLower == SZSArchive.extensionName
                            || (AppPreferences.gpgEnabled && GPGFileService.isRecognizedGPGFile(extractedURL)) {
                            extractedSpecialFileURL = extractedURL
                            return
                        }
                        // 监视写回:记下临时副本 + 它当前的 hash,回前台时若 hash 变了就询问写回(#109 part 3)。
                        if allowWriteBack, let hash = try? SIZArchive.computeInnerArchiveSHA256(of: extractedURL) {
                            registeredWriteBack = PendingArchiveWriteBack(
                                archiveURL: archiveURL, entryPath: writeBackEntryPath,
                                tempFileURL: extractedURL, lastKnownHash: hash
                            )
                        }
                        guard NSWorkspace.shared.open(extractedURL) else {
                            throw ArchiveError.openExtractedItemFailed
                        }
                        return
                    } catch {
                        guard self.shouldPromptForArchivePassword(error) else {
                            throw error
                        }
                        if !untriedSessionPasswords.isEmpty {
                            password = untriedSessionPasswords.removeFirst()
                            continue
                        }
                        guard let authentication = self.promptForArchiveItemPassword(
                            item: item,
                            archiveURL: archiveURL,
                            detectedZipEncryption: detectedZipEncryption,
                            isRetry: isRetry
                        ) else {
                            throw CancellationError()
                        }
                        password = authentication.password
                        zipDecryptionMethod = authentication.zipDecryptionMethod
                        isRetry = true
                    }
                }
            }
            if didSucceed {
                // 登记写回监视(去重:同一归档同一条目只留最新)。
                if let registeredWriteBack {
                    pendingArchiveWriteBacks.removeAll { $0.archiveURL == registeredWriteBack.archiveURL && $0.entryPath == registeredWriteBack.entryPath }
                    pendingArchiveWriteBacks.append(registeredWriteBack)
                }
                if let extractedDiskImageURL {
                    openDiskImage(extractedDiskImageURL)
                } else if let extractedNestedArchiveURL {
                    // 在 app 内浏览嵌套档案：地址栏把整条虚拟链堆叠出来（`…/xx.zip/xa/a.zip`），
                    // 「上一级」退出整条链回到最外层档案所在的真实文件夹，全程不露 /tmp。
                    openNestedArchive(extractedNestedArchiveURL, entryName: item.name, recordsReturnLocation: nestedRecordsReturnLocation)
                } else if let extractedSpecialFileURL {
                    routeExtractedSpecialFile(extractedSpecialFileURL, entryName: item.name)
                } else {
                    status = L10n.format("status.openedArchiveItem", item.displayName)
                }
            }
        }
    }

    /// 从档案内解出来的 SimpleZip 自有特殊类型（`.siz` / `.szs` / `.gpg`·`.pgp`·`.asc`·`.key`）在**当前窗口**内
    /// 走各自 in-app 流程，绝不 `NSWorkspace.open`（详见 `openArchiveItemExternally` 内注释）。
    /// - `.siz`：带上 entry 链路 → `handleSIZOpen` 解包验签后走 `openNestedArchive`（地址显示嵌套链、「上一级」回真实文件夹）。
    /// - `.szs`：走验证 sheet。
    /// - `.gpg`/`.pgp`/`.asc`/`.key`：`openGPGFile` 嗅探包头后解密浏览 / 导入钥匙串（仅 `gpgEnabled` 才会被路由到这里）。
    func routeExtractedSpecialFile(_ url: URL, entryName: String) {
        switch url.pathExtension.lowercased() {
        case SIZArchive.extensionName:
            pendingSIZOpen = SIZOpenRequest(url: url, nestedEntryName: entryName)
        case SZSArchive.extensionName:
            pendingSZSOpen = url
        default:
            openGPGFile(url)
        }
    }

    /// 拖出解压:把档案条目解到目标。`destinationURL` 是 `NSFilePromiseProvider` 给的**完整目标文件 URL**
    /// （AppKit 已经用 `fileNameForType` 把文件名拼好,并放在它准备好的位置;父目录已存在）——
    /// ⚠️ 不要再 `appendingPathComponent(displayName)`,否则会拼成 `…/名字/名字`、父目录不存在 → 移动失败、拖出无产物。
    ///
    /// 全程登记成一个**活动中心任务**(进度 + 可取消):本函数被 file promise 的回调 `await`,任务生命周期
    /// (begin→进度→finish)就在这里收尾,promise 的 `completionHandler` 在它返回/抛错时自然触发。
    /// 不主动弹活动中心窗口(拖拽场景弹窗打扰),用户想看时自己打开即可。
    func exportArchiveItem(_ item: ArchiveItem, to destinationURL: URL) async throws {
        guard case .archive(let archiveURL) = mode else {
            throw ArchiveError.unsupportedFormat
        }

        let entries = item.isDirectory ? expandedArchiveItems(for: item) : [item]
        guard !entries.isEmpty else {
            throw ArchiveError.extractedItemNotFound
        }

        let operationID = UUID()
        let taskCenter = TaskCenter.shared
        // 文案显示**实际落点目录**(拖放目标文件夹 = promise 目标 URL 的父目录),而不是泛指「拖放位置」。
        // `~` 缩写让主目录下的路径短一点(如 ~/Desktop)。
        let destinationFolderDisplay = (destinationURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let title = L10n.format("status.exportingArchiveItem", item.displayName, destinationFolderDisplay)
        let task = taskCenter.begin(
            category: .archive,
            kind: .extract,
            title: title,
            cancellable: true,
            operationID: operationID
        )
        task.progress = ArchiveProgressState(fraction: 0, currentFile: nil)
        // 取消:活动中心点取消 → 杀掉后端命令(extract 随即抛错)。didCancel 让 catch 把结果标成「已取消」而非「失败」。
        var didCancel = false
        task.cancel = {
            didCancel = true
            ArchiveService.cancelRunningCommand(operationID: operationID)
        }
        let progressCoalescer = ProgressCoalescer { [weak task] progress in
            guard let task, task.status.isRunning else { return }
            task.progress = progress
            taskCenter.notifyTaskChanged()
        }

        status = title
        let stagingURL = try extractionCoordinator.makeExtractionStagingDirectory()
        defer { try? fileManager.removeItem(at: stagingURL) }

        do {
            try confirmArchiveExtractionSafety(entries: entries)
            try await ArchiveService.extract(
                archiveURL,
                entries: entries,
                to: stagingURL,
                overwriteBehavior: .overwrite,
                pathMode: .preserve,
                safetyPolicy: .skipValidation,
                operationID: operationID,
                progress: { progressCoalescer.submit($0) },
                force: isForced(archiveURL)
            )
            try confirmExtractedArchiveLinks(at: stagingURL)

            let extractedURL = try extractedURL(for: item, in: stagingURL)
            // AppKit 保证 destinationURL 唯一(冲突时它已自行去重),正常不该存在;存在则按安全策略拒绝覆盖。
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw ArchiveError.exportDestinationExists
            }
            try fileManager.moveItem(at: extractedURL, to: destinationURL)
            progressCoalescer.submit(ArchiveProgressState(fraction: 1, currentFile: nil, statusText: L10n.text("status.done")))
            taskCenter.finish(task, outcome: .succeeded(nil))
            status = L10n.format("status.exportedArchiveItem", item.displayName)
        } catch {
            let cancelled = didCancel || error is CancellationError || (error as? CocoaError)?.code == .userCancelled
            taskCenter.finish(task, outcome: cancelled ? .cancelled : .failed(error.localizedDescription))
            status = cancelled ? L10n.text("status.cancelled") : L10n.text("status.failed")
            throw error  // 让 file promise 的 completionHandler(error) 知道失败/取消
        }
    }

    func createArchive() {
        guard case .folder(let currentFolder) = mode else {
            errorMessage = L10n.text("error.openFolderFirst")
            return
        }

        let items = selectedFileItems
        guard !items.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let destination = currentFolder.appendingPathComponent(defaultArchiveName(for: items.map(\.url)))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: items.map(\.url), directoryURL: currentFolder, destinationURL: destination)
    }

    func createArchive(fromFinderURLs urls: [URL]) {
        let fileURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !fileURLs.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }

        let parentDirectory = fileURLs[0].deletingLastPathComponent()
        let destination = parentDirectory.appendingPathComponent(defaultArchiveName(for: fileURLs))
        archiveCreationRequest = ArchiveCreationRequest(sourceURLs: fileURLs, directoryURL: parentDirectory, destinationURL: destination)
    }

    func performCreateArchive(_ request: ArchiveCreationRequest) {
        // **必须延后一个 runloop**：本方法由创建选项 sheet 的「创建」按钮调用，调用方刚把
        // `archiveCreationRequest = nil`（请求 SwiftUI 关闭 sheet），但 sheet 的关闭是异步的。
        // 若立刻在同步路径里跑 `NSApp.runModal`（同名冲突对话框），会卡在 sheet 还没关、模态面板
        // 拿不到 key window 的死锁 → 整个 app 卡死（用户报：创建后撞同名直接卡死）。
        // 延后到下一拍让 sheet 先关掉,模态面板就能正常成为 key window。
        DispatchQueue.main.async { [weak self] in
            self?.performCreateArchiveNow(request)
        }
    }

    private func performCreateArchiveNow(_ request: ArchiveCreationRequest) {
        // 勾选 GPG 签名 → 实际输出会被改名成 `<name>.siz` —— title 也跟着用最终文件名，
        // 避免长任务面板显示「正在创建 1.zip」但实际产物是 1.siz 的违和。
        let intendedDestination = request.options.gpgSign
            ? request.destinationURL.deletingPathExtension().appendingPathExtension(SIZArchive.extensionName)
            : request.destinationURL
        // **输出与已有文件同名** → 按「遇到同名文件时」偏好处理（覆盖 / 跳过 / 询问），
        // 不再像以前那样直接抛「已有同名文件」错误硬跳过。
        let plan = resolveArchiveOutputConflict(intendedDestination)
        let finalDestination: URL
        // 创建成功后的收尾动作：nil = 直接刷新;.replace = 原子替换;.replaceIfDifferent = 比哈希后替换/丢弃。
        let postCreate: PostCreateReplacement?
        switch plan {
        case .abort:
            return
        case .write(let url):
            finalDestination = url
            postCreate = nil
        case .writeThenReplace(let temp, let existing):
            finalDestination = temp
            postCreate = .replace(existing)
        case .writeThenReplaceIfDifferent(let temp, let existing):
            finalDestination = temp
            postCreate = .replaceIfDifferent(existing)
        }
        // 如果冲突解决把目标改了名（「两者都保留」/「仅不同时替换」的临时名）→ 同步改 request 的输出基名。
        var request = request
        if finalDestination != intendedDestination {
            if request.options.gpgSign {
                // finalDestination 是改名后的 `.siz`；后端用 request.destinationURL（内层基名，如 .zip）再 append `.siz`，
                // 所以把基名 stem 换成 finalDestination 的 stem、保留原内层扩展名。
                let innerExt = request.destinationURL.pathExtension
                let stem = finalDestination.deletingPathExtension().lastPathComponent
                let newBaseName = innerExt.isEmpty ? stem : "\(stem).\(innerExt)"
                request.destinationURL = finalDestination.deletingLastPathComponent().appendingPathComponent(newBaseName)
            } else {
                request.destinationURL = finalDestination
            }
        }
        let title = L10n.format("status.creating", finalDestination.lastPathComponent)
        startManagedArchiveTask(
            title: title,
            kind: .compress,
            showsDetails: request.options.showDetails,
            refreshOnSuccess: { [weak self] in
                guard let self else { return }
                // 临时产物已生成 → 按收尾动作原子替换 / 比哈希替换;无冲突则直接刷新。
                switch postCreate {
                case .none:
                    self.refreshVisibleFolder(containing: finalDestination)
                case .replace(let existing):
                    _ = try? self.fileManager.replaceItemAt(existing, withItemAt: finalDestination)
                    self.status = L10n.format("status.created", existing.lastPathComponent)
                    self.refreshVisibleFolder(containing: existing)
                case .replaceIfDifferent(let existing):
                    self.finishReplaceIfDifferent(produced: finalDestination, existing: existing)
                }
            }
        ) { [request] operationID, progress, outputObserver in
            try await ArchiveCreationService.run(request, operationID: operationID, progress: progress, outputObserver: outputObserver)
            // 0.4.3 #7:按设置(默认关)测试刚创建的产物。加密包(test 不带口令)和 .siz(另有验签)跳过。
            if AppPreferences.verifyAfterArchiveCreate, request.options.password.isEmpty, !request.options.gpgSign {
                try await ArchiveService.test(finalDestination, operationID: operationID, outputObserver: outputObserver)
            }
        }
    }

    /// 创建成功后对已有文件的收尾动作。
    private enum PostCreateReplacement {
        case replace(URL)            // 无条件原子替换 existing
        case replaceIfDifferent(URL) // 比哈希,不同才替换、相同则丢弃临时产物
    }

    /// 创建压缩包输出的写入计划。**数据安全**：替换已有文件时一律「写临时 → 创建成功后原子替换」，
    /// 绝不在创建前先删旧文件（否则创建失败会连旧带新都丢）。
    enum ArchiveOutputPlan {
        /// 直接写这个路径（无冲突 / 唯一名,目标本就不存在）。
        case write(URL)
        /// 写到 `temp`（唯一临时名），创建成功后**无条件**用它原子替换 `existing`。
        case writeThenReplace(temp: URL, existing: URL)
        /// 写到 `temp`，创建成功后与 `existing` 比哈希：不同才替换、相同则丢弃临时产物。
        case writeThenReplaceIfDifferent(temp: URL, existing: URL)
        /// 放弃创建（取消 / 跳过）。
        case abort
    }

    /// 创建压缩包输出与已有同名文件冲突时按「遇到同名文件时」偏好处理。
    /// - `.overwrite` → 写临时后原子替换（不再先删后建）。
    /// - `.skipExisting` → 不创建。
    /// - `.ask` → 弹**现代冲突对话框**（与解压 / 粘贴同一套 UI）让用户选；
    /// - `.replaceIfDifferent` → 写临时后比哈希,不同才替换。
    private func resolveArchiveOutputConflict(_ destination: URL) -> ArchiveOutputPlan {
        guard fileManager.fileExists(atPath: destination.path) else { return .write(destination) }
        switch AppPreferences.overwriteBehavior {
        case .overwrite:
            return .writeThenReplace(temp: uniqueSibling(of: destination), existing: destination)
        case .skipExisting:
            status = L10n.format("status.createSkippedExisting", destination.lastPathComponent)
            return .abort
        case .replaceIfDifferent:
            return .writeThenReplaceIfDifferent(temp: uniqueSibling(of: destination), existing: destination)
        case .ask:
            return planFromArchiveOutputConflictDialog(destination)
        }
    }

    /// 弹现代冲突对话框,把用户选择翻译成写入计划。
    private func planFromArchiveOutputConflictDialog(_ destination: URL) -> ArchiveOutputPlan {
        switch extractionCoordinator.archiveOutputConflictChoice(fileName: destination.lastPathComponent) {
        case .replace:
            return .writeThenReplace(temp: uniqueSibling(of: destination), existing: destination)
        case .keepBoth:
            return .write(uniqueSibling(of: destination))
        case .replaceIfDifferent:
            return .writeThenReplaceIfDifferent(temp: uniqueSibling(of: destination), existing: destination)
        default:
            return .abort
        }
    }

    /// 给 `destination` 在同目录算一个不冲突的名字（`a.zip` → `a 2.zip`）。
    private func uniqueSibling(of destination: URL) -> URL {
        UniqueFileName.numbered(
            in: destination.deletingLastPathComponent(),
            preferredName: destination.lastPathComponent,
            exists: { fileManager.fileExists(atPath: $0.path) }
        )
    }

    /// 「仅当内容不同时替换」的收尾（创建成功后调）：比对新产物 `produced` 与 `existing` 的 SHA256。
    /// 不同 → 删 existing、把 produced 改名成 existing 的原路径（完成替换）；
    /// 相同 → 删 produced、保留 existing,状态提示「内容相同已跳过」。
    private func finishReplaceIfDifferent(produced: URL, existing: URL) {
        Task { @MainActor in
            // 哈希计算在后台,避免大包阻塞主线程。
            let hashes = await Task.detached(priority: .utility) {
                (try? HashService.sha256(for: produced), try? HashService.sha256(for: existing))
            }.value
            if let producedHash = hashes.0, let existingHash = hashes.1, producedHash == existingHash {
                // 内容相同 → 丢弃新产物,保留旧文件。
                try? fileManager.removeItem(at: produced)
                status = L10n.format("status.createSameContentSkipped", existing.lastPathComponent)
            } else {
                // 不同（或哈希读不到 → 保守替换）→ 用新产物替换旧文件。
                _ = try? fileManager.replaceItemAt(existing, withItemAt: produced)
                status = L10n.format("status.createReplacedDifferent", existing.lastPathComponent)
            }
            refreshVisibleFolder(containing: existing)
        }
    }

    // MARK: - 拖入文件加进打开的压缩包（#109，走活动中心 + 安全写回）

    /// 0.4.3 #13:当前打开归档的**写入受限原因**(nil = 可写)。`canDropIntoOpenArchive` 的解释版——
    /// 状态栏只读徽章、各写入口的说明共用这一份原因,统一回答「为什么这个包不能编辑」。
    /// 非归档模式 / 归档文件已消失返回 nil(那是另一类问题,不属于能力门控)。
    var archiveWriteRestriction: ArchiveWriteRestriction? {
        guard case .archive(let url) = mode else { return nil }
        if archiveDisplayOverride != nil { return .temporaryExtractedCopy }
        if !nestedArchiveReturnStack.isEmpty { return .nestedArchive }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return ArchiveService.entryUpdateRestriction(forExtension: url.pathExtension)
    }

    /// 当前是否允许把外部文件拖进打开的压缩包：必须是**真实顶层** zip/7z（非嵌套 / 非 `.siz`·`.gpg` 解出来的临时包），
    /// 否则写回 `/tmp` 临时包毫无意义、还可能误导。判定收敛到 `archiveWriteRestriction`(#13 单一来源)。
    var canDropIntoOpenArchive: Bool {
        guard case .archive(let url) = mode,
              fileManager.fileExists(atPath: url.path) else { return false }
        return archiveWriteRestriction == nil
    }

    // MARK: - 归档级注释编辑（0.4.2，仅 zip —— EOCD 原生改写）

    /// 是否允许编辑当前归档的归档级注释。「真实顶层可写包」的判定复用 `canDropIntoOpenArchive`，
    /// 再限定 zip —— 写入走 `ZipArchiveComment` 的 EOCD 原生改写；7z/rar 没有安全的写注释路径（7zz 无参数）。
    var canEditArchiveComment: Bool {
        guard canDropIntoOpenArchive, case .archive(let url) = mode else { return false }
        return url.pathExtension.lowercased() == "zip"
    }

    /// 保存归档级注释（空串 = 清除）。Core 侧临时副本 + 原子替换，失败原包字节不变。
    /// 走活动中心：好处是有失败提示 + 历史可查；坏处可忽略（APFS clonefile 副本瞬时）。
    func saveArchiveComment(_ comment: String) {
        guard canEditArchiveComment, case .archive(let archiveURL) = mode else { return }
        startManagedArchiveTask(
            title: L10n.format("archive.comment.taskTitle", archiveURL.lastPathComponent),
            kind: .compress,
            showsDetails: false,
            successStatus: L10n.text(comment.isEmpty ? "archive.comment.cleared" : "archive.comment.saved"),
            refreshOnSuccess: { [weak self] in
                ArchiveService.recordHeaderComment(comment, for: archiveURL)
                self?.archiveHeaderComment = comment
            }
        ) { [archiveListingStamp] _, _, observer in
            // 0.4.3 #2/#3:注释改写也是「整包安全写回」,同样过写锁 + 外部改动检测。
            await ArchiveWriteLock.shared.acquire(archiveURL, onWait: self.writeLockWaitReporter(observer))
            defer { ArchiveWriteLock.shared.scheduleRelease(archiveURL) }
            try archiveListingStamp?.ensureUnchanged(at: archiveURL)
            try await Task.detached(priority: .userInitiated) {
                try ZipArchiveComment.writeComment(comment, to: archiveURL)
            }.value
            ArchiveService.notifyArchiveRewritten(archiveURL)
        }
    }

    /// 归档内编辑前**确保拿到加密包口令**（若该包需要）。返回 `false` = 用户取消 → 调用方必须中止编辑。
    ///
    /// 为什么需要：header-encrypted 7z 打开时连 list 都要口令，已在 `loadArchive` 存进 `resolvedArchivePassword`；
    /// 但**加密 zip / 内容加密(非 header)7z** 是「列目录不要口令、解压才要」，所以打开时 `resolvedArchivePassword` 还是空。
    /// 若不在这里补口令，增删改 / 写回会用**空口令**跑 7zz —— 要么失败、要么把新/替换条目写成**未加密**塞进加密包（安全混淆）。
    ///
    /// 同步实现（`promptForArchivePassword` 是 NSAlert 同步弹框），所以可在 `startManagedArchiveTask` **之前**调用，
    /// 保证任务闭包按值捕获到的 `resolvedArchivePassword` 已是用户输入的口令。
    /// 不做单独的「先 test 校验口令」：① 大包 `7zz t` 很慢；② 安全写回失败时原包字节不变（增删改用错口令会失败、原包安然）。
    /// 残余：给加密 zip **新增**条目时若口令打错，新条目会用错口令加密进包（非破坏性、用户打开时会发现）—— 可接受。
    @discardableResult
    func ensureArchiveEditPassword(for archiveURL: URL) -> Bool {
        guard resolvedArchivePassword.isEmpty else { return true }   // 已有（header-encrypted 7z 在打开时拿到）
        guard ArchiveService.archiveItemsSuggestPasswordRequirement(session.allItems, in: archiveURL) else {
            return true   // 明文包：空口令正确，无需弹框
        }
        let detectedZipEncryption: ZipEncryptionDetection = archiveURL.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: archiveURL)
            : .unknown
        guard let authentication = promptForArchivePassword(
            archiveURL: archiveURL,
            displayName: (archiveDisplayOverride ?? archiveURL).lastPathComponent,
            detectedZipEncryption: detectedZipEncryption,
            isRetry: false,
            actionTitle: L10n.text("button.continue")
        ) else {
            return false   // 用户取消
        }
        resolvedArchivePassword = authentication.password
        return true
    }

    /// 把拖入的文件 / 文件夹加入当前打开的压缩包 —— 目标路径 = 当前所在的归档内虚拟文件夹。
    /// 走活动中心；后端 `addOrReplaceEntries` 安全写回（复制原包→更新副本→原子替换，失败不破坏原包）。
    func addFilesToOpenArchive(_ urls: [URL]) {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        let additions = Self.archiveAdditions(for: urls, targetDir: session.archivePath)
        guard !additions.isEmpty else { return }
        guard ensureArchiveEditPassword(for: archiveURL) else { return }   // 加密包先拿口令(否则空口令编辑失败/塞明文)

        let title = additions.count == 1
            ? L10n.format("archive.addEntry.single", (additions[0].entryPath as NSString).lastPathComponent)
            : L10n.format("archive.addEntry.multiple", "\(additions.count)", archiveURL.lastPathComponent)
        startManagedArchiveTask(
            title: title,
            kind: .compress,
            showsDetails: true,
            refreshOnSuccess: { [weak self] in
                self?.status = L10n.format("archive.addEntry.done", "\(additions.count)")
                self?.reload()
            },
            onSucceeded: { task in
                task.transferLog = additions.map {
                    TransferLogEntry(name: $0.entryPath, action: .added, isDirectory: false)
                }
            }
        ) { [resolvedArchivePassword, archiveListingStamp] operationID, _, observer in
            try await ArchiveService.addOrReplaceEntries(
                in: archiveURL,
                additions: additions,
                password: resolvedArchivePassword,
                operationID: operationID,
                outputObserver: observer,
                expectedStamp: archiveListingStamp,
                onWaitForLock: self.writeLockWaitReporter(observer)
            )
        }
    }

    /// 把拖入的顶层 URL 列表展开成 `ArchiveEntryAddition`：文件 → 1 条（`targetDir/文件名`）；
    /// 文件夹 → 递归其下所有普通文件，路径保留 `targetDir/文件夹名/…`。非 async（用 `nextObject()` 同步遍历）。
    ///
    /// **空目录保留**：只枚举普通文件会丢掉「空子目录」——用户拖一个含空文件夹的目录进去，结构会少一截。
    /// 所以额外把**空目录**（`contentsOfDirectory` 为空）显式作为一条 addition 加进去（`sourceFile` 是该空目录，
    /// `addOrReplaceEntries` 复制它 + 7zz `a` 会落成空目录条目）。非空目录无需显式加——它会被其下文件的路径隐式创建。
    /// 符号链接 / 特殊文件仍被跳过（只收 regular file + 空目录），保持既有的链接安全策略。
    static func archiveAdditions(for urls: [URL], targetDir: String) -> [ArchiveEntryAddition] {
        let fm = FileManager.default
        let base: String = {
            let trimmed = targetDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "" : trimmed + "/"
        }()
        var result: [ArchiveEntryAddition] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let folderName = url.lastPathComponent
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey])
                var addedAnyDescendant = false
                while let child = enumerator?.nextObject() as? URL {
                    let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    let relWithin = child.path.dropFirst(url.path.count + 1)
                    if values?.isRegularFile == true {
                        result.append(ArchiveEntryAddition(sourceFile: child, entryPath: base + folderName + "/" + relWithin))
                        addedAnyDescendant = true
                    } else if values?.isDirectory == true,
                              ((try? fm.contentsOfDirectory(atPath: child.path))?.isEmpty ?? false) {
                        // 空子目录：显式加,否则拖整个文件夹进归档会丢失空目录结构。
                        result.append(ArchiveEntryAddition(sourceFile: child, entryPath: base + folderName + "/" + relWithin))
                        addedAnyDescendant = true
                    }
                }
                // 整个文件夹本身就是空的（无任何普通文件 / 空子目录被收进来）→ 加它本身,
                // 否则拖一个空文件夹进归档什么都不会发生。
                if !addedAnyDescendant {
                    result.append(ArchiveEntryAddition(sourceFile: url, entryPath: base + folderName))
                }
            } else {
                result.append(ArchiveEntryAddition(sourceFile: url, entryPath: base + url.lastPathComponent))
            }
        }
        return result
    }

    /// 「添加文件…」入口(右键菜单)—— NSOpenPanel 选文件 / 文件夹加进当前归档。比拖入可靠(不跟 AppKit 文件承诺抢)。
    func addArchiveFilesViaPanel() {
        guard canDropIntoOpenArchive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("archive.addFiles.prompt")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addFilesToOpenArchive(panel.urls)
    }

    /// 「粘贴」到归档 —— 剪贴板里有 file URL 时,把它们加进当前归档内文件夹。
    func pasteIntoOpenArchive() {
        guard canDropIntoOpenArchive else { return }
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        addFilesToOpenArchive(urls)
    }

    /// 剪贴板是否有可粘贴进归档的 file URL(菜单是否显示「粘贴」用)。
    var clipboardHasFileURLsForArchivePaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true])
    }

    /// 删除选中的归档条目(目录递归)—— 二次确认 + 走活动中心 + 安全删除(失败不破坏原包)。
    func deleteSelectedArchiveEntries() {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        let items = selectedArchiveItems
        guard !items.isEmpty else { return }
        // 收集归档内路径:每个选中项;目录还要带上其所有后代条目。
        var paths = Set<String>()
        for item in items {
            paths.insert(item.name)
            if item.isDirectory {
                for child in expandedArchiveItems(for: item) { paths.insert(child.name) }
            }
        }
        let entryPaths = Array(paths)
        guard !entryPaths.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? L10n.format("archive.deleteEntry.confirmSingle", items[0].displayName)
            : L10n.format("archive.deleteEntry.confirmMultiple", "\(items.count)")
        alert.informativeText = L10n.text("archive.deleteEntry.confirmMessage")
        alert.addButton(withTitle: L10n.text("archive.deleteEntry.confirmButton"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard ensureArchiveEditPassword(for: archiveURL) else { return }   // 加密包先拿口令

        let title = items.count == 1
            ? L10n.format("archive.deleteEntry.titleSingle", items[0].displayName)
            : L10n.format("archive.deleteEntry.titleMultiple", "\(entryPaths.count)")
        startManagedArchiveTask(
            title: title,
            kind: .delete,
            showsDetails: true,
            refreshOnSuccess: { [weak self] in self?.reload() },
            onSucceeded: { task in
                task.transferLog = entryPaths.map { TransferLogEntry(name: $0, action: .deleted, isDirectory: false) }
            }
        ) { [resolvedArchivePassword, archiveListingStamp] operationID, _, observer in
            try await ArchiveService.deleteEntries(from: archiveURL, entryPaths: entryPaths, password: resolvedArchivePassword,
                                                   operationID: operationID, outputObserver: observer,
                                                   expectedStamp: archiveListingStamp,
                                                   onWaitForLock: self.writeLockWaitReporter(observer))
        }
    }

    /// 提交一个归档条目的**内联重命名**(由 ArchiveTable 的内联编辑器调用,跟文件浏览器同一 idiom——不弹窗)。
    /// `newLeaf` = 用户在内联输入框里改的叶名;走活动中心 + 安全重命名(失败不破坏原包)。
    func renameArchiveEntry(_ item: ArchiveItem, to newLeaf: String) {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        let trimmed = newLeaf.trimmingCharacters(in: .whitespacesAndNewlines)
        // 叶名不得含路径分隔符 `/` 或 `\`(后者是 Windows 分隔 / UNC,属归档路径逃逸面,见
        // ArchiveEntryUpdate.normalizedEntryRelativePath)。无效名静默忽略,跟文件浏览器内联改名一致。
        guard !trimmed.isEmpty, trimmed != item.displayName,
              !trimmed.contains("/"), !trimmed.contains("\\") else { return }

        let oldPath = item.name
        let parent = (oldPath as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
        guard ensureArchiveEditPassword(for: archiveURL) else { return }   // 加密包先拿口令

        startManagedArchiveTask(
            title: L10n.format("archive.renameEntry.taskTitle", item.displayName, trimmed),
            kind: .rename,
            showsDetails: true,
            refreshOnSuccess: { [weak self] in self?.reload() }
        ) { [resolvedArchivePassword, archiveListingStamp] operationID, _, observer in
            try await ArchiveService.renameEntry(in: archiveURL, from: oldPath, to: newPath, password: resolvedArchivePassword,
                                                 operationID: operationID, outputObserver: observer,
                                                 expectedStamp: archiveListingStamp,
                                                 onWaitForLock: self.writeLockWaitReporter(observer))
        }
    }

    /// 在当前归档内文件夹新建一个空文件夹 / 空文件(zip/7z)。**给 `createNewFolderAndBeginRename` /
    /// `createNewFileAndBeginRename` 在归档模式下复用**——不是另起 API,只是它们在归档里的实现分支。
    /// 建完进内联重命名(跟文件夹模式一致),靠 `pendingInlineRenameArchiveEntry` + ArchiveTable 消费。
    func createNewArchiveEntry(isDirectory: Bool, contents: Data?, defaultName: String) {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        guard ensureArchiveEditPassword(for: archiveURL) else { return }   // 加密包先拿口令
        let base = session.archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base.isEmpty ? "" : base + "/"
        let existing = Set(archiveItems.map(\.displayName))
        let leaf = Self.uniqueArchiveLeaf(defaultName, existing: existing)

        // 在系统临时目录建一个空文件 / 空文件夹,加进归档后清掉。
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SimpleZip-NewEntry-\(UUID().uuidString)", isDirectory: true)
        let source = tempRoot.appendingPathComponent(leaf, isDirectory: isDirectory)
        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            if isDirectory {
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
            } else {
                try (contents ?? Data()).write(to: source)
            }
        } catch {
            errorMessage = error.localizedDescription
            try? fm.removeItem(at: tempRoot)
            return
        }

        let entryPath = prefix + leaf
        let additions = [ArchiveEntryAddition(sourceFile: source, entryPath: entryPath)]
        startManagedArchiveTask(
            title: L10n.format("archive.addEntry.single", leaf),
            kind: .create,
            showsDetails: true,
            refreshOnSuccess: { [weak self] in
                try? FileManager.default.removeItem(at: tempRoot)
                // 建完进内联重命名(跟文件夹模式 pendingInlineRenameURL 一致的 idiom)。
                self?.pendingInlineRenameArchiveEntry = entryPath
                self?.reload()
            },
            onSucceeded: { task in
                task.transferLog = [TransferLogEntry(name: entryPath, action: .added, isDirectory: isDirectory)]
            }
        ) { [resolvedArchivePassword, archiveListingStamp] operationID, _, observer in
            try await ArchiveService.addOrReplaceEntries(in: archiveURL, additions: additions, password: resolvedArchivePassword,
                                                         operationID: operationID, outputObserver: observer,
                                                         expectedStamp: archiveListingStamp,
                                                         onWaitForLock: self.writeLockWaitReporter(observer))
        }
    }

    /// 在 `existing` 名字集合里给 `base` 找一个不冲突的名字(`base`、`base 2`、`base 3`…)。
    static func uniqueArchiveLeaf(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - 外部编辑写回(#109 part 3)

    /// app 回到前台时调:检查所有被监视的临时副本,有外部编辑(hash 变了)就逐个询问写回。
    /// 临时副本 / 原归档已不在 → 丢弃该监视。
    func checkPendingArchiveWriteBacks() {
        guard !pendingArchiveWriteBacks.isEmpty else { return }
        var keep: [PendingArchiveWriteBack] = []
        var changed: [PendingArchiveWriteBack] = []
        for wb in pendingArchiveWriteBacks {
            guard fileManager.fileExists(atPath: wb.tempFileURL.path),
                  fileManager.fileExists(atPath: wb.archiveURL.path) else { continue }
            if let hash = try? SIZArchive.computeInnerArchiveSHA256(of: wb.tempFileURL), hash != wb.lastKnownHash {
                changed.append(wb)
            } else {
                keep.append(wb)
            }
        }
        pendingArchiveWriteBacks = keep
        for wb in changed { promptArchiveWriteBack(wb) }
    }

    /// 单个条目被外部编辑 → 询问写回。不管选啥都更新已知 hash 并继续监视(避免对同一改动反复弹)。
    private func promptArchiveWriteBack(_ wb: PendingArchiveWriteBack) {
        let leaf = (wb.entryPath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.format("archive.writeBack.title", leaf)
        alert.informativeText = L10n.format("archive.writeBack.message", wb.archiveURL.lastPathComponent)
        alert.addButton(withTitle: L10n.text("archive.writeBack.confirmButton"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        let response = alert.runModal()

        // 继续监视:把已知 hash 更新到当前(无论写不写回),下次再编辑才会重新提示。
        var updated = wb
        updated.lastKnownHash = (try? SIZArchive.computeInnerArchiveSHA256(of: wb.tempFileURL)) ?? wb.lastKnownHash
        pendingArchiveWriteBacks.removeAll { $0.archiveURL == wb.archiveURL && $0.entryPath == wb.entryPath }
        pendingArchiveWriteBacks.append(updated)

        guard response == .alertFirstButtonReturn else { return }
        let archiveURL = wb.archiveURL, entryPath = wb.entryPath, tempURL = wb.tempFileURL
        guard ensureArchiveEditPassword(for: archiveURL) else { return }   // 加密包先拿口令
        startManagedArchiveTask(
            title: L10n.format("archive.writeBack.taskTitle", leaf),
            kind: .compress,
            showsDetails: true,
            refreshOnSuccess: { [weak self] in self?.reload() }
        ) { [resolvedArchivePassword, archiveListingStamp] operationID, _, observer in
            try await ArchiveService.addOrReplaceEntries(
                in: archiveURL,
                additions: [ArchiveEntryAddition(sourceFile: tempURL, entryPath: entryPath)],
                password: resolvedArchivePassword, operationID: operationID, outputObserver: observer,
                expectedStamp: archiveListingStamp,
                onWaitForLock: self.writeLockWaitReporter(observer)
            )
        }
    }

    /// 当前上下文的「删除」——给菜单栏 ⌘⌫ 命令统一入口:归档(可编辑)里删条目,否则删文件(移废纸篓)。
    func deleteSelectionInCurrentContext() {
        if case .archive = mode, canDropIntoOpenArchive {
            deleteSelectedArchiveEntries()
        } else {
            deleteSelectedFiles()
        }
    }

    func extractFromCurrentContext() {
        if case .archive = mode, !selectedArchiveItems.isEmpty {
            extractSelectedArchiveItems()
        } else {
            extractArchive()
        }
    }

    func extractArchive() {
        // 文件浏览器里选中 `.siz` + 点 Extract —— `.siz` 不在 `supportedExtensions` 里（ArchiveService
        // 不直接处理 tar 壳），所以特判走 @Published 状态给 ContentView 跑「unwrap + 验签 + 标准解压对话框」。
        if case .folder = mode,
           let sizURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SIZArchive.extensionName })?.url {
            pendingSIZExtract = sizURL
            return
        }
        // `.szs` 不是压缩包 —— 解压语义不适用。改成弹 alert 解释，附「以虚拟目录浏览」按钮把用户引到正确流程。
        if case .folder = mode,
           let szsURL = selectedFileItems.first(where: { $0.url.pathExtension.lowercased() == SZSArchive.extensionName })?.url {
            pendingSZSExtractHint = szsURL
            return
        }
        // 0.4.2：.gpg/.szs **虚拟浏览**里点「解压」= 把解密出的文件保存到用户选的目录
        //（这个视图里的文件本来就是解密产物,「解压」的合理语义就是导出）。
        if case .folder = mode, manifestVirtualMode != nil {
            exportVirtualModeFiles()
            return
        }
        // 0.4.2 用户点名：`.gpg`/`.pgp`/`.asc` 的「解压」要真的能用 —— 弹确认对话框（产物名 / 目标目录），
        // 走完整任务管线（活动中心 / 可重跑）。钥匙串材料则引去导入。
        if case .folder = mode,
           let gpgURL = selectedFileItems.first(where: { !$0.isDirectory && GPGFileService.isRecognizedGPGFile($0.url) })?.url {
            extractGPGFileHere(gpgURL)
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

        // 预设密码开启时 request 的初始密码就填好；ExtractOptionsForm 那一头会同时把
        // 「使用预设密码」复选框默认勾上 —— 用户不需要在偏好和对话框两处再点一遍。
        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractArchiveRequest = ExtractArchiveRequest(
            archiveURL: archiveURL,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    /// 0.4.2：虚拟浏览导出确认请求（非 nil = 弹专用对话框）。用户点名「不能偷懒用系统面板」。
    struct VirtualExportRequest: Identifiable {
        let id = UUID()
        let files: [URL]
        var destinationURL: URL
    }

    /// 虚拟浏览（.gpg/.szs 解密临时内容）的「解压」= 导出。选中的文件优先,没选就全部；
    /// 弹专用对话框（文件清单 + 可改目标目录）。
    private func exportVirtualModeFiles() {
        let candidates = selectedFileItems.isEmpty ? fileItems : selectedFileItems
        let files = candidates.filter { !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else {
            errorMessage = L10n.text("error.selectFilesToArchive")
            return
        }
        // 默认目的地：原容器（.gpg/.szs）所在目录;拿不到就退回下载目录。
        let fallback = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let defaultDestination = archiveDisplayOverride?.deletingLastPathComponent() ?? fallback
        virtualExportRequest = VirtualExportRequest(files: files, destinationURL: defaultDestination)
    }

    /// 执行虚拟导出：逐个复制（唯一名,绝不覆盖），任一失败立即停（已成功的保留）。
    func performVirtualExport(_ request: VirtualExportRequest) {
        var exported = 0
        for file in request.files {
            let desired = request.destinationURL.appendingPathComponent(file.lastPathComponent)
            let target = fileManager.fileExists(atPath: desired.path)
                ? UniqueFileName.suffixed(for: desired, suffix: "", exists: { self.fileManager.fileExists(atPath: $0.path) })
                : desired
            do {
                try fileManager.copyItem(at: file, to: target)
                exported += 1
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        if exported > 0 {
            status = L10n.format("virtual.export.done", "\(exported)")
        }
    }

    /// 解压默认目标路径 —— 普通 archive 用自身父目录；`.siz` 打开内层时 archiveURL 是 /tmp 路径，
    /// 这时回退到 `archiveDisplayOverride`（=原始 .siz 文件路径）的父目录，
    /// 用户期望的「桌面 / 下载」目录，而不是 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-xxx/`。
    private func defaultExtractDestination(for archiveURL: URL) -> URL {
        if let displayed = archiveDisplayOverride {
            return displayed.deletingLastPathComponent()
        }
        return archiveURL.deletingLastPathComponent()
    }

    func performExtractArchive(_ request: ExtractArchiveRequest) {
        let title = L10n.format("status.extracting", request.archiveURL.lastPathComponent)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            },
            rerunAction: { [weak self] in self?.performExtractArchive(request) }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            // `.siz` v3 加密前置：如果是加密的内层 archive（`.gpg` 后缀 + sizSignature 带 encryption），
            // 先用 gpg --decrypt 出明文 sibling 文件，再走原本的 ArchiveService.extract 路径。
            // 用 defer 把解密产物在任务结束时抹掉，避免明文长期留在 /tmp。
            // **后缀检查 `.lowercased()`**：容错跨平台 / 手工拼包的 `.GPG` 大写。
            let archiveURLForExtract: URL
            let decryptedSiblingToCleanup: URL?
            if request.sizSignature?.encryption != nil,
               request.archiveURL.lastPathComponent.lowercased().hasSuffix(".gpg") {
                do {
                    archiveURLForExtract = try await SIZArchive.decryptInnerArchive(
                        encryptedURL: request.archiveURL,
                        decryptionKeyFingerprint: request.gpgDecryptionKeyFingerprint.isEmpty ? nil : request.gpgDecryptionKeyFingerprint,
                        passphrase: request.gpgDecryptionPassphrase.isEmpty ? nil : request.gpgDecryptionPassphrase,
                        operationID: operationID
                    )
                    decryptedSiblingToCleanup = archiveURLForExtract
                } catch {
                    throw ArchiveError.commandFailed(L10n.format("error.siz.decryptionFailed", error.localizedDescription))
                }
            } else {
                archiveURLForExtract = request.archiveURL
                decryptedSiblingToCleanup = nil
            }
            defer {
                if let toCleanup = decryptedSiblingToCleanup {
                    try? self.fileManager.removeItem(at: toCleanup)
                }
            }

            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            // 安全检查只跑一次 —— 第一次 list 成功后置 true，后续 retry 不重复跑 NSAlert。
            // 旧版本把这步放在循环外，对 header-encrypted 7z 用空密码 list 直接失败，
            // 用户根本进不到下面的密码 prompt。
            var didCheckSafety = false
            // 安全检查 list 出的文件数 —— 复用给 ArchiveService.extract 的 knownFileCount，省掉解压时再 list 一遍。
            var knownFileCount: Int?
            // 0.4.2 #9：会话里记过的口令，口令失败时先静默逐个试，全试完才弹框。
            var untriedSessionPasswords = SessionPasswordCache.shared.candidates(for: archiveURLForExtract).filter { $0 != password }
            while true {
                do {
                    if !didCheckSafety {
                        let items = try await self.confirmArchiveExtractionSafety(
                            archiveURL: archiveURLForExtract,
                            password: password,
                            operationID: operationID,
                            force: force
                        )
                        knownFileCount = items.filter { !$0.isDirectory }.count
                        didCheckSafety = true
                    }
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        archiveURLForExtract,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        knownFileCount: knownFileCount,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    if !untriedSessionPasswords.isEmpty {
                        password = untriedSessionPasswords.removeFirst()
                        continue
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: archiveURLForExtract,
                        displayName: request.archiveURL.lastPathComponent,
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            SessionPasswordCache.shared.record(password, for: archiveURLForExtract)
            // 0.4.2：「不解压 macOS 元数据垃圾」—— 合并前在 staging 上清掉，目标目录原有文件零接触。
            if request.skipJunk {
                ArchiveJunkFiles.removeJunk(in: stagingURL)
            }
            // 0.4.3 #15:「不解压符号链接」—— 同样在 staging 上处理,目标目录零接触。
            if request.skipSymlinks {
                ArchiveJunkFiles.removeSymlinks(in: stagingURL)
            }
            // #13:「去单层目录」—— staging 顶层只有那个壳时把内容上提一层(壳为符号链接 /
            // 结构对不上时安静放弃,按原结构合并 —— lift 自带防越界与同名嵌套保护)。
            if request.stripSingleRootFolder {
                ArchiveSingleRootFolder.lift(in: stagingURL)
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { status in
                progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status))
            } updateProgress: { mergeProgress in
                progress(mergeProgress)
            }
        }
    }

    // MARK: - 清理 macOS 元数据（0.4.2 #16）

    /// 当前归档里的元数据垃圾条目数（.DS_Store / __MACOSX / ._* / Thumbs.db / desktop.ini）。
    /// 右键菜单按需调用（菜单打开时算一次，O(n) 字符串检查）。
    var archiveJunkEntryCount: Int {
        ArchiveJunkFiles.junkEntries(in: session.allItems).count
    }

    /// 右键「清理 macOS 元数据」：把垃圾条目从可编辑归档里删掉（安全写回：副本上删 + 原子替换）。
    func cleanArchiveJunkEntries() {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        let junk = ArchiveJunkFiles.junkEntries(in: session.allItems)
        guard !junk.isEmpty else { return }
        guard ensureArchiveEditPassword(for: archiveURL) else { return }
        let password = resolvedArchivePassword
        let paths = junk.map(\.name)
        startManagedArchiveTask(
            title: L10n.format("archive.cleanJunk.taskTitle", "\(paths.count)"),
            kind: .compress,
            showsDetails: true,
            successStatus: L10n.format("archive.cleanJunk.done", "\(paths.count)"),
            refreshOnSuccess: { [weak self] in
                self?.reload()
            },
            onSucceeded: { task in
                task.transferLog = paths.map {
                    TransferLogEntry(name: $0, action: .deleted, isDirectory: false)
                }
            }
        ) { [archiveListingStamp] operationID, _, outputObserver in
            try await ArchiveService.deleteEntries(
                from: archiveURL,
                entryPaths: paths,
                password: password,
                operationID: operationID,
                outputObserver: outputObserver,
                expectedStamp: archiveListingStamp,
                onWaitForLock: self.writeLockWaitReporter(outputObserver)
            )
        }
    }

    // MARK: - 批量重命名（0.4.2 #11）

    /// 批量重命名 sheet 的输入：选中的文件条目 + 包内全部条目路径（预览查撞名用）。
    struct BatchRenameRequest: Identifiable {
        let id = UUID()
        let archiveURL: URL
        let items: [ArchiveItem]
        let allEntryPaths: [String]
        /// 0.4.2：非 nil = **文件浏览**批量重命名（重命名磁盘文件,不是归档条目）。
        /// 复用同一个 sheet / 同一套 BatchRename 引擎 —— 只有落盘方式不同（moveItem vs 7zz rn）。
        var fileURLs: [URL]? = nil
    }

    /// 0.4.2（用户点名）：批量重命名扩展到**文件浏览** —— 选中 ≥2 个文件 / 文件夹右键或菜单栏触发。
    /// 引擎与归档内共用（替换 / 前后缀 / 大小写 / 序号 + 实时预览 + 冲突标红）；
    /// 落盘 = 逐个 moveItem + 整批注册撤销（⌘Z 一次全部回退）。
    func requestBatchRenameFiles() {
        guard case .folder(let folderURL) = mode else { return }
        let items = selectedFileItems
        guard items.count >= 2 else {
            errorMessage = L10n.text("batchRename.needTwoFiles")
            return
        }
        // 「全部名字」= 当前目录可见项 + 隐藏项的名字,用于与未选中项的冲突检查。
        let allNames = fileItems.map { $0.url.lastPathComponent }
        batchRenameRequest = BatchRenameRequest(
            archiveURL: folderURL,
            items: items.map { item in
                ArchiveItem(name: item.url.lastPathComponent, isDirectory: item.isDirectory, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
            },
            allEntryPaths: allNames,
            fileURLs: items.map(\.url)
        )
    }

    /// 文件浏览批量重命名落盘：逐对 moveItem,成功对整批注册撤销;任何一对失败立即停（已成功的保留并可撤销）。
    func performFileBatchRename(_ request: BatchRenameRequest, changes: [BatchRenameChange]) {
        guard let fileURLs = request.fileURLs else { return }
        let byOldName = Dictionary(uniqueKeysWithValues: fileURLs.map { ($0.lastPathComponent, $0) })
        var movedPairs: [(URL, URL)] = []
        var failureMessage: String?
        for change in changes where !change.isConflicting && change.toPath != change.fromPath {
            guard let source = byOldName[change.fromPath] else { continue }
            let target = source.deletingLastPathComponent().appendingPathComponent(change.toPath)
            let caseOnly = target.path.caseInsensitiveCompare(source.path) == .orderedSame
            if !caseOnly, fileManager.fileExists(atPath: target.path) {
                failureMessage = L10n.format("file.rename.conflict.message", change.toPath)
                break
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                movedPairs.append((source, target))
            } catch {
                failureMessage = error.localizedDescription
                break
            }
        }
        if !movedPairs.isEmpty {
            registerMoveUndo(movedPairs.map { (from: $0.0, to: $0.1) }, actionName: L10n.text("undo.action.rename"))
            pendingSelectionURL = movedPairs[0].1.standardizedFileURL
            recordInstantFileTask(
                kind: .rename,
                title: L10n.format("batchRename.taskTitle.files", "\(movedPairs.count)"),
                detail: movedPairs.map { "\($0.0.lastPathComponent) → \($0.1.lastPathComponent)" }.joined(separator: "\n")
            )
            status = L10n.format("batchRename.done.files", "\(movedPairs.count)")
        }
        if let failureMessage {
            errorMessage = failureMessage
        }
        // 刷新交给 FolderWatcher（同目录改名触发 FSEvents 自动 reload）。
    }

    /// 菜单栏「批量重命名…」：按当前模式路由（归档条目 vs 磁盘文件）。
    func requestBatchRenameAnywhere() {
        switch mode {
        case .archive:
            requestBatchRename()
        case .folder, .tag:
            requestBatchRenameFiles()
        }
    }

    /// 右键「批量重命名…」：可编辑归档里选中 ≥2 个文件条目 → 弹计划 sheet。
    func requestBatchRename() {
        guard canDropIntoOpenArchive, case .archive(let archiveURL) = mode else { return }
        let files = selectedArchiveItems.filter { !$0.isDirectory }
        guard files.count >= 2 else { return }
        batchRenameRequest = BatchRenameRequest(
            archiveURL: archiveURL,
            items: files,
            allEntryPaths: session.allItems.map(\.name)
        )
    }

    /// 执行批量重命名：冲突项已被 sheet 排除；一次 7zz `rn` 多对 + 原子替换（改一半不会发生）。
    func performBatchRename(_ request: BatchRenameRequest, changes: [BatchRenameChange]) {
        let valid = changes.filter { !$0.isConflicting }
        guard !valid.isEmpty else { return }
        guard ensureArchiveEditPassword(for: request.archiveURL) else { return }
        let password = resolvedArchivePassword
        startManagedArchiveTask(
            title: L10n.format("archive.batchRename.taskTitle", "\(valid.count)"),
            kind: .compress,
            showsDetails: true,
            successStatus: L10n.format("archive.batchRename.done", "\(valid.count)"),
            refreshOnSuccess: { [weak self] in
                self?.reload()
            },
            onSucceeded: { task in
                task.transferLog = valid.map {
                    TransferLogEntry(name: $0.fromLeaf, action: .changed, isDirectory: false, detail: "→ \($0.toLeaf)")
                }
            }
        ) { [archiveListingStamp] operationID, _, outputObserver in
            try await ArchiveService.renameEntries(
                in: request.archiveURL,
                pairs: valid.map { (from: $0.fromPath, to: $0.toPath) },
                password: password,
                operationID: operationID,
                outputObserver: outputObserver,
                expectedStamp: archiveListingStamp,
                onWaitForLock: self.writeLockWaitReporter(outputObserver)
            )
        }
    }

    // MARK: - 临时预览 / 保存副本（0.4.2 #10）

    /// 把选中的**文件**条目解到注册过清理的临时目录（随归档关闭 / 退出自动清掉，预览副本不落地），
    /// 成功后回调解出的 URL。「快速预览」与「保存副本到…」共用。
    /// 口令：已解析口令 + 会话缓存静默试，失败弹框重试 —— 与打开条目同款语义。
    private func extractSelectedFileEntriesToTemp(completion: @escaping ([URL]) -> Void) {
        guard case .archive(let archiveURL) = mode else { return }
        let items = selectedArchiveItems.filter { !$0.isDirectory }
        guard !items.isEmpty else { return }
        let detectedZipEncryption: ZipEncryptionDetection = archiveURL.pathExtension.lowercased() == "zip"
            ? ArchiveService.detectZipEncryption(in: archiveURL)
            : .unknown
        let force = isForced(archiveURL)

        startOperationTask(cancellable: true) { [weak self] operationID in
            guard let self else { return }
            var extracted: [URL] = []
            let didSucceed = await runArchiveTask(L10n.format("status.openingArchiveItem", items[0].displayName)) { progress in
                let destination = try self.makeArchiveItemOpenDirectory()
                self.openedArchiveItemDirectories.append(destination)
                try self.confirmArchiveExtractionSafety(entries: items)
                var password = self.resolvedArchivePassword
                var zipDecryptionMethod: ArchiveDecryptionMethod = .automatic
                var isRetry = false
                var untriedSessionPasswords = SessionPasswordCache.shared.candidates(for: archiveURL).filter { $0 != password }
                while true {
                    do {
                        try? self.fileManager.removeItem(at: destination)
                        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                        try await ArchiveService.extract(
                            archiveURL,
                            entries: items,
                            to: destination,
                            overwriteBehavior: .overwrite,
                            pathMode: .preserve,
                            password: password,
                            zipDecryptionMethod: zipDecryptionMethod,
                            safetyPolicy: .skipValidation,
                            operationID: operationID,
                            progress: progress,
                            force: force
                        )
                        try self.confirmExtractedArchiveLinks(at: destination)
                        SessionPasswordCache.shared.record(password, for: archiveURL)
                        break
                    } catch {
                        guard self.shouldPromptForArchivePassword(error) else { throw error }
                        if !untriedSessionPasswords.isEmpty {
                            password = untriedSessionPasswords.removeFirst()
                            continue
                        }
                        guard let authentication = self.promptForArchivePassword(
                            archiveURL: archiveURL,
                            displayName: items[0].displayName,
                            detectedZipEncryption: detectedZipEncryption,
                            isRetry: isRetry,
                            actionTitle: L10n.text("button.open")
                        ) else {
                            throw CancellationError()
                        }
                        password = authentication.password
                        zipDecryptionMethod = authentication.zipDecryptionMethod
                        isRetry = true
                    }
                }
                extracted = items.compactMap { try? self.extractedURL(for: $0, in: destination) }
            }
            if didSucceed, !extracted.isEmpty {
                completion(extracted)
            }
        }
    }

    /// 右键「快速预览」（归档条目）：解到临时目录后回调，coordinator 拿去喂 QLPreviewPanel。
    func quickLookSelectedArchiveItems(present: @escaping ([URL]) -> Void) {
        extractSelectedFileEntriesToTemp(completion: present)
    }

    /// 右键「保存副本到…」（单文件条目）：NSSavePanel 选位置 → 解到临时 → 落位。
    /// 不走解压对话框 / 冲突流程 —— 保存面板自身已让用户确认过覆盖；已存在时原子替换。
    func saveSelectedArchiveItemCopy() {
        guard case .archive = mode,
              selectedArchiveItems.count == 1,
              let item = selectedArchiveItems.first,
              !item.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.displayName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        extractSelectedFileEntriesToTemp { [weak self] urls in
            guard let self, let source = urls.first else { return }
            do {
                if self.fileManager.fileExists(atPath: target.path) {
                    _ = try self.fileManager.replaceItemAt(target, withItemAt: source)
                } else {
                    try self.fileManager.copyItem(at: source, to: target)
                }
                self.status = L10n.format("archive.saveCopy.done", target.lastPathComponent)
                self.refreshVisibleFolder(containing: target)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func extractSelectedArchiveItems() {
        guard case .archive(let archiveURL) = mode else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }

        let entries = expandedSelectedArchiveItems()
        guard !entries.isEmpty else {
            errorMessage = L10n.text("error.selectArchiveItemsToExtract")
            return
        }

        let preset = AppPreferences.hasUsablePresetPassword ? AppPreferences.presetPassword : ""
        extractSelectionRequest = ExtractSelectionRequest(
            archiveURL: archiveURL,
            entries: entries,
            destinationURL: defaultExtractDestination(for: archiveURL),
            password: preset,
            detectedZipEncryption: ArchiveService.detectZipEncryption(in: archiveURL)
        )
    }

    func performExtractSelection(_ request: ExtractSelectionRequest) {
        let title = L10n.format("status.extractingSelected", request.entries.count)
        let force = isForced(request.archiveURL)
        startManagedArchiveTask(
            title: title,
            showsDetails: request.showDetails,
            refreshOnSuccess: { [weak self] in
                self?.refreshVisibleFolder(request.destinationURL)
            },
            rerunAction: { [weak self] in self?.performExtractSelection(request) }
        ) { operationID, progress, outputObserver in
            let stagingURL = try self.extractionCoordinator.makeExtractionStagingDirectory()
            defer { try? self.fileManager.removeItem(at: stagingURL) }

            try self.confirmArchiveExtractionSafety(entries: request.entries)
            let backendOverwriteBehavior = AppPreferences.overwriteBehavior == .skipExisting ? OverwriteBehavior.skipExisting : .overwrite
            var password = request.password
            var zipDecryptionMethod = request.zipDecryptionMethod
            var isRetry = !password.isEmpty
            // 0.4.2 #9：会话里记过的口令，口令失败时先静默逐个试，全试完才弹框。
            var untriedSessionPasswords = SessionPasswordCache.shared.candidates(for: request.archiveURL).filter { $0 != password }
            while true {
                do {
                    try? self.fileManager.removeItem(at: stagingURL)
                    try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                    try await ArchiveService.extract(
                        request.archiveURL,
                        entries: request.entries,
                        to: stagingURL,
                        overwriteBehavior: backendOverwriteBehavior,
                        pathMode: request.pathMode,
                        password: password,
                        zipDecryptionMethod: zipDecryptionMethod,
                        safetyPolicy: .skipValidation,
                        operationID: operationID,
                        progress: progress,
                        outputObserver: outputObserver,
                        force: force
                    )
                    break
                } catch {
                    guard self.shouldPromptForArchivePassword(error) else {
                        throw error
                    }
                    if !untriedSessionPasswords.isEmpty {
                        password = untriedSessionPasswords.removeFirst()
                        continue
                    }
                    guard let authentication = self.promptForArchivePassword(
                        archiveURL: request.archiveURL,
                        displayName: L10n.format("status.extractingSelected", request.entries.count),
                        detectedZipEncryption: request.detectedZipEncryption,
                        isRetry: isRetry,
                        actionTitle: L10n.text("button.extract")
                    ) else {
                        throw CancellationError()
                    }
                    password = authentication.password
                    zipDecryptionMethod = authentication.zipDecryptionMethod
                    isRetry = true
                }
            }
            SessionPasswordCache.shared.record(password, for: request.archiveURL)
            // 0.4.2：「不解压 macOS 元数据垃圾」—— 合并前在 staging 上清掉，目标目录原有文件零接触。
            if request.skipJunk {
                ArchiveJunkFiles.removeJunk(in: stagingURL)
            }
            // 0.4.3 #15:「不解压符号链接」—— 同样在 staging 上处理,目标目录零接触。
            if request.skipSymlinks {
                ArchiveJunkFiles.removeSymlinks(in: stagingURL)
            }
            try await self.extractionCoordinator.mergeExtractedItems(
                from: stagingURL,
                to: request.destinationURL,
                defaultOverwriteBehavior: AppPreferences.overwriteBehavior
            ) { status in
                progress(ArchiveProgressState(fraction: nil, currentFile: nil, statusText: status))
            } updateProgress: { mergeProgress in
                progress(mergeProgress)
            }
        }
    }

    /// 「右键 → 创建签名清单」入口：把当前选中的 file URL 集合 + 推断出的 payload root 发到 ContentView 弹 CreateSZSSheet。
    /// payload root 推断：所有选中文件的最深公共祖先目录。多选时如果分散在不同父目录，公共祖先可能是 `/` 之类的祖先 —— UI 仍然
    /// 让用户在 sheet 里改 payload root（默认值即可），不强制走推断结果。
    func createSignedManifest() {
        let urls = selectedFileItems.map(\.url)
        guard !urls.isEmpty else {
            errorMessage = L10n.text("error.openOrSelectArchive")
            return
        }
        let inferredRoot = Self.commonAncestorDirectory(for: urls) ?? urls.first!.deletingLastPathComponent()
        pendingCreateSZS = CreateSZSPrefill(payloadRoot: inferredRoot, files: urls)
    }

    /// 算 URL 集合的最深公共祖先目录（用于推断 payload root）。
    /// 如果集合空 → nil；单个文件 → 其父目录。
    static func commonAncestorDirectory(for urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let paths = urls.map { $0.standardizedFileURL.deletingLastPathComponent().pathComponents }
        // 逐层比对，找最长共同前缀。
        var prefix: [String] = []
        outer: for i in 0..<(paths.first?.count ?? 0) {
            let comp = paths[0][i]
            for p in paths.dropFirst() {
                if i >= p.count || p[i] != comp { break outer }
            }
            prefix.append(comp)
        }
        guard prefix.count > 1 else { return URL(fileURLWithPath: "/") } // 只剩根 → /
        // pathComponents 第一个是 "/"，URL 还原时不能简单 joined；走 NSString 拼接。
        let joined = (prefix as NSArray).componentsJoined(by: "/")
            .replacingOccurrences(of: "//", with: "/")
        return URL(fileURLWithPath: joined)
    }

    private func defaultArchiveName(for urls: [URL]) -> String {
        if urls.count == 1 {
            return urls[0].deletingPathExtension().lastPathComponent + ".zip"
        }
        return "Archive.zip"
    }

    /// 选中压缩包内目录时，展开成目录下所有项目，避免后端只收到目录占位项。
    func expandedSelectedArchiveItems() -> [ArchiveItem] {
        session.expand(selectedArchiveItems)
    }

    func expandedArchiveItems(for item: ArchiveItem) -> [ArchiveItem] {
        session.expand(item)
    }

    func isOpenableArchiveDirectoryPackage(_ item: ArchiveItem) -> Bool {
        guard item.isDirectory else { return false }
        let ext = URL(fileURLWithPath: item.displayName).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .applicationBundle)
    }

    private func makeArchiveItemOpenDirectory() throws -> URL {
        try TemporaryResourceManager.makeOpenedArchiveItemDirectory(fileManager: fileManager)
    }

    private func extractedURL(for item: ArchiveItem, in destination: URL) throws -> URL {
        let relativePath = item.isDirectory
            ? ArchiveSession.normalizedDirectoryPrefix(item.name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : ArchiveSession.normalizedEntryName(item.name, isDirectory: false)
        let expectedURL = destination.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }

        if let fallbackURL = firstExtractedURL(named: item.displayName, in: destination) {
            return fallbackURL
        }
        throw ArchiveError.extractedItemNotFound
    }

    private func firstExtractedURL(named fileName: String, in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }
}
