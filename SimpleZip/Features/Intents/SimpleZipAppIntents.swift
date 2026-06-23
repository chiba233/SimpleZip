//
//  SimpleZipAppIntents.swift
//  SimpleZip
//
//  Shortcuts / Siri 建议接入(App Intents)—— **只剩需要 app 共享状态的 Tier-2 intent**:
//  发布打包(发布账本 + Spotlight + 重度流水线)、改设置(app 偏好域)、查含某文件的归档(已打开归档索引,
//  在 CachedArchiveEntity.swift)。其余「干活」intent(解压 / 创建 / 测试 / 校验 / 比较 / 搜索 / 检查 /
//  分析空间 / 体检 / 救援)已迁入 **App Intents 扩展**(`SimpleZipIntentsExtension`):macOS 26 要求 App Intents
//  扩展沙箱化才注册,注册后系统在轻量扩展进程跑 perform,**不拉起完整 app** → 根治 Shortcuts 超时
//  「Couldn't communicate with a helper application」。沙箱扩展访问不到 app 的偏好域 / 账本 / 已打开索引,
//  故这三个 Tier-2 留在 app。
//
//  本地化口径:静态元数据(标题 / 参数名 / 描述)是字面 LocalizedStringResource —— 英文字面量即键,各 .lproj
//  补对应条目,由系统按 Shortcuts 进程语言解析;运行期 dialog / 错误消息走 L10n(intent.* 键)。扩展有独立
//  bundle,其 intent 的同款键已复制进扩展自己的 Localizable.strings(全 10 语种)。
//

import AppIntents
import Foundation

/// Intent 执行错误:消息原样展示给 Shortcuts 用户(已本地化)。
struct SimpleZipIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// IntentFile → 磁盘 URL。Shortcuts 传内存数据(无落盘位置)时明确拒绝 ——
/// 归档操作全部按路径工作,不接受把未知数据悄悄写进临时目录再处理。
private func intentFileURL(_ file: IntentFile) throws -> URL {
    guard let url = file.fileURL else {
        throw SimpleZipIntentError(message: L10n.format("intent.error.noFileURL", file.filename))
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", url.path))
    }
    return url
}

// MARK: - 发布打包(0.4.4 B)

struct CreateReleasePackageIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Release Package"
    static let description = IntentDescription(
        "Runs SimpleZip's Release Assistant headlessly: pack a build folder (junk excluded, reproducible), inspect the archive and write SHA256SUMS — using a saved workspace preset when one is chosen. Signing as .szs is interactive-only and never runs unattended."
    )

    @Parameter(title: "Build Folder")
    var sourceFolder: IntentFile

    @Parameter(title: "Workspace Preset")
    var preset: ReleaseWorkspacePresetEntity?

    @Parameter(title: "Archive Name")
    var archiveName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a release package from \(\.$sourceFolder)") {
            \.$preset
            \.$archiveName
        }
    }

    // 稳定返回契约(发版后不得改类型/语义):ReturnsValue<IntentFile> = 产物归档文件(可直接被下游
    // 动作消费);产物文件名 + 是否真写了 SHA256SUMS(按本次实际结果,不假定)在 dialog。无人值守绝不签 .szs。
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let source = try intentFileURL(sourceFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SimpleZipIntentError(message: L10n.format("intent.error.missingFile", source.path))
        }

        // 组装请求:选了工作区预设(实体)就按 id 取出存储记录套用 —— 预设已被删 = 明确报错,不静默回落;
        // 没选 = 全默认(排垃圾 + 可复现 + 检查 + 校验)。
        var request = ReleaseAssistantRequest()
        request.sourceFolder = source
        request.destinationFolder = source.deletingLastPathComponent()
        request.fileName = source.lastPathComponent
        if let preset {
            guard let stored = ReleaseWorkspacePresetStore().loadAll().first(where: { $0.id == preset.id }) else {
                throw SimpleZipIntentError(message: L10n.format("intent.release.unknownPreset", preset.name))
            }
            request.fileName = stored.fileName.isEmpty ? source.lastPathComponent : stored.fileName
            request.versionLabel = stored.versionLabel ?? ""
            if let format = ArchiveCreateFormat(rawValue: stored.formatRawValue), format == .zip || format == .sevenZip {
                request.format = format
            }
            request.excludeJunk = stored.excludeJunk
            request.reproducible = stored.reproducible
            request.runInspection = stored.runInspection
            request.writeChecksums = stored.writeChecksums
            request.writeManifest = stored.writeManifest ?? false
            request.gateRules = stored.gateRules ?? ReleaseGateRules()
        }
        if let archiveName, !archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.fileName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 无人值守红线:绝不进入交互式 .szs 签名(预设里勾了也压掉)。
        request.createSignedManifest = false
        // P1 同款:输出名必须是单段纯文件名(Shortcuts 是无人值守入口)。
        guard !ArchiveSafety.isUnsafeOutputBaseName(request.fileName) else {
            throw SimpleZipIntentError(message: L10n.format("intent.error.badName", request.fileName))
        }

        let destination = request.destinationFolder ?? source.deletingLastPathComponent()
        let preferred = destination
            .appendingPathComponent(request.fileName)
            .appendingPathExtension(request.format.pathExtension)
        let outputURL = UniqueFileName.suffixed(for: preferred, suffix: "") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var options = ArchiveCreationOptions()
        options.format = request.format
        options.skipDSStore = request.excludeJunk
        if request.excludeJunk {
            options.customExcludes = "._*, Thumbs.db, desktop.ini"
        }
        if request.reproducible {
            options.reproducibleArchive = true
        }

        let operationID = UUID()
        let recorder = ReleaseStepRecorder()
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .create,
            source: .intent,
            title: L10n.format("releaseAssistant.taskTitle", outputURL.lastPathComponent),
            detail: outputURL.path,
            cancellable: false,
            operationID: operationID
        )
        let progressCoalescer = ProgressCoalescer { [weak task] state in
            task?.progress = state
        }
        do {
            // F3 抽出的同一条流水线 —— 不造平行引擎。
            let report = try await ReleaseAssistantPipeline.run(
                request: request,
                source: source,
                destination: destination,
                outputURL: outputURL,
                options: options,
                skipCreate: false,
                recorder: recorder,
                operationID: operationID,
                progress: { state in progressCoalescer.submit(state) },
                outputObserver: nil
            )
            task.transferLog = recorder.steps.map { step in
                TransferLogEntry(
                    name: L10n.text("releaseAssistant.step.\(step.id.rawValue)"),
                    action: step.status == .skipped ? .skipped : .passed,
                    isDirectory: false,
                    detail: step.status == .skipped ? "" : step.formattedDuration
                )
            }
            TaskCenter.shared.finish(task, outcome: .succeeded(outputURL))
            // 与 GUI 同口径:成功跑进发布账本。
            let steps = recorder.steps
            let trimmedLabel = request.versionLabel.trimmingCharacters(in: .whitespaces)
            let fileName = request.fileName
            Task { @MainActor in
                let metadata = await ReportMetadataBuilder.make(targetPath: nil)
                ReleaseLedgerStore().append(ReleaseLedgerEntry(
                    date: Date(),
                    artifactPath: outputURL.path,
                    versionLabel: trimmedLabel.isEmpty ? fileName : trimmedLabel,
                    formatRawValue: request.format.rawValue,
                    sha256: report.sha256,
                    structuralFingerprint: report.structuralFingerprint,
                    reproducible: request.reproducible,
                    excludeJunk: request.excludeJunk,
                    inspectionRan: request.runInspection,
                    testPassed: report.testPassed,
                    suspiciousPathCount: request.runInspection
                        ? report.securityFindings.reduce(0) { $0 + $1.entryPaths.count } : nil,
                    junkCount: report.stats?.junkCount,
                    emptyDirectoryCount: report.stats?.emptyDirectoryCount,
                    fileCount: report.stats?.fileCount,
                    totalBytes: report.stats?.totalBytes,
                    // P3b:记**真写成功**(report.wroteChecksums),不是「请求里勾了」的意图。
                    wroteChecksums: report.wroteChecksums,
                    signRequested: false,
                    appVersion: metadata.appVersion,
                    backendVersion: metadata.backendVersion,
                    steps: steps
                ))
                // 0.4.4 macOS 26 AI:Shortcuts 跑出的发布包也同步进 Spotlight 索引(macOS 15+,后台、失败静默)。
                ReleasePackageSpotlightIndexer.reindex()
            }
            // 是否写了 SHA256SUMS 按**真实结果**报(report.wroteChecksums),不写死「已写」——
            // 校验步可能被预设关掉或失败,谎报会误导用户(P3b 同口径)。
            let doneKey = report.wroteChecksums ? "intent.release.done" : "intent.release.doneNoChecksums"
            return .result(
                value: IntentFile(fileURL: outputURL),
                dialog: IntentDialog("\(L10n.format(doneKey, outputURL.lastPathComponent))")
            )
        } catch {
            TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
            throw SimpleZipIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: - 直接开关设置(0.4.4 #31)

/// 经 Siri / Spotlight **不打开 app** 直接开 / 关一个安全布尔设置。
///
/// 红线:参数类型是 `ToggleableSettingEntity`(只含 `isToggleable == true` 的目录项)——Siri / Shortcuts
/// 的参数选择面根本列不出安全 / 破坏类设置。perform 里再用 `SettingToggleRegistry.accessor` 复核一次;
/// 拿不到访问器(非白名单)就明确拒绝、绝不改任何值。口令 / 删除确认 / GPG 启用 / 路径策略永远改不到。
struct ChangeSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Change a Setting"
    static let description = IntentDescription(
        "Turns a SimpleZip setting on or off without opening the app. Only safe, convenience toggles can be changed this way — settings that affect deleting files, encryption or archive path safety are never voice-controllable."
    )

    @Parameter(title: "Setting")
    var setting: ToggleableSettingEntity

    @Parameter(title: "State", default: .toggle)
    var state: SettingToggleState

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$state) \(\.$setting)")
    }

    // 稳定返回契约(发版后不得改类型/语义):ReturnsValue<Bool> = 切换后的新状态;
    // dialog 用大白话确认「X 现在已开 / 关」。
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        // 复核闸:目录项存在且 isToggleable,且 registry 有访问器 —— 任一不满足就拒绝,绝不写任何值。
        guard let item = SettingsCatalog.item(id: setting.id), item.isToggleable,
              let accessor = SettingToggleRegistry.accessor(for: setting.id) else {
            throw SimpleZipIntentError(message: L10n.format("intent.setting.notToggleable", setting.name))
        }
        let newValue: Bool
        switch state {
        case .on: newValue = true
        case .off: newValue = false
        case .toggle: newValue = !accessor.get()
        }
        accessor.set(newValue)
        let stateWord = L10n.text(newValue ? "intent.setting.on" : "intent.setting.off")
        return .result(
            value: newValue,
            dialog: IntentDialog("\(L10n.format("intent.setting.result", setting.name, stateWord))")
        )
    }
}

// MARK: - Siri / Spotlight 建议(app target 自己的 provider:只含留在 app 里的 Tier-2 intent)

/// App Shortcuts:把**留在 app 进程**的 intent(改设置 / 查含某文件的归档 / 发布打包 —— 它们需要 app 的共享
/// 状态:偏好域 / 已打开归档索引 / 发布账本 + Spotlight + 重度流水线,沙箱扩展访问不到)注册成建议。
/// 其余「干活」intent(解压 / 创建 / 测试 / 校验 / 比较 / 搜索 / 检查 / 分析空间 / 体检 / 救援)已迁入
/// **App Intents 扩展**(`SimpleZipExtensionAppShortcuts`),在轻量沙箱扩展进程里跑、不拉起完整 app。
/// `shortTitle` / `systemImageName` 初始化器要 macOS 14;macOS 13 上 intent 本身照常可用,只是不预注册建议。
@available(macOS 14.0, *)
struct SimpleZipAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateReleasePackageIntent(),
            phrases: ["Create a release package with \(.applicationName)", "Package a release with \(.applicationName)"],
            shortTitle: "Create Release Package",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: FindArchiveContainingFileIntent(),
            phrases: [
                "Find which archive contains a file with \(.applicationName)",
                "Find an archive containing a file with \(.applicationName)"
            ],
            shortTitle: "Find Archive Containing File",
            systemImageName: "rectangle.and.text.magnifyingglass"
        )
        AppShortcut(
            intent: ChangeSettingIntent(),
            phrases: [
                "Change a \(.applicationName) setting",
                "Turn on a \(.applicationName) setting",
                "Turn off a \(.applicationName) setting",
                "Toggle a \(.applicationName) setting"
            ],
            shortTitle: "Change a Setting",
            systemImageName: "switch.2"
        )
        // #31 的 macOS 26 交互式 snippet(SettingSwitchSnippet)刻意不进这里:AppShortcutsBuilder 不支持
        // `if #available` 分支(会产出 [AppShortcut] 而非变参),而整个 provider 是 macOS 14 下限。
        // SnippetIntent 默认 isDiscoverable=true,系统会在 macOS 26 Spotlight / 快捷指令里自行收录它;
        // Siri 语音「开关设置」的短语已由上面的 ChangeSettingIntent 覆盖,无需在此重复。
    }
}
