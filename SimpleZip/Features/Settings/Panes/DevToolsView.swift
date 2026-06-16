//
//  DevToolsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/12.
//
//  0.4.2 隐藏开发者工具：「设置 → 关于」⌘+点击版本胶囊进入。
//  四区：环境（版本 / 后端）、关键路径（Finder 直达）、调试动作（重置欢迎助手 / 模拟异常退出 /
//  复制环境报告）、UserDefaults 快照（备份白名单键的当前值,只读 + 可整体复制）。
//  动作都是**本机调试向**：不碰归档数据、不碰钥匙串内容,最坏后果是下次启动多弹一个向导/恢复提示。
//

import AppKit
import SwiftUI

struct DevToolsView: View {
    let onClose: () -> Void

    @State private var sevenZipVersion = "…"
    @State private var rarVersion = "…"
    @State private var actionFeedback: String?
    // 0.4.3 #12:自检样本结果(运行时现造恶意样本对真实后端断言)。
    @State private var sampleResults: [SelfTestSampleRunner.SampleResult] = []
    @State private var isRunningSamples = false
    // 0.4.4 #6:格式兼容性实验室(用户选小文件夹,对真实后端逐格式实测保真度)。
    @State private var formatLabResults: [FormatLabRunner.FormatResult] = []
    @State private var isRunningFormatLab = false
    // 0.4.5 #80/#89:AI 可用数据快照(只读)—— 助手、归档记忆、Spotlight、后台预索引、动态工作区、活动任务源。
    @State private var aiAssistantStatus = "…"
    @State private var aiArchiveMemoryStatus = "…"
    @State private var aiSpotlightStatus = "…"
    @State private var aiBackgroundIndexStatus = "…"
    @State private var aiWorkspaceStatus = "…"
    @State private var aiActivityTasksStatus = "…"

    private var appVersionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "hammer.fill",
                colors: [.gray, .black],
                title: L10n.text("devtools.title"),
                subtitle: appVersionLine
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 16) {
                    DialogSection(L10n.text("devtools.section.environment")) {
                        infoRow("app", "SimpleZip", appVersionLine)
                        infoRow("desktopcomputer", "macOS", ProcessInfo.processInfo.operatingSystemVersionString)
                        infoRow("archivebox", "7zz", sevenZipVersion)
                        infoRow("doc.zipper", "RAR", rarVersion)
                        infoRow(
                            "key",
                            "GPG",
                            GPGBackend.isAvailable()
                                ? L10n.text("devtools.gpg.available")
                                : L10n.text("devtools.gpg.unavailable")
                        )
                    }

                    DialogSection(L10n.text("devtools.section.paths")) {
                        pathRow(L10n.text("devtools.path.appSupport"), applicationSupportURL)
                        pathRow(L10n.text("devtools.path.keyring"), GPGBackend.simpleZipGPGHomeDirectory())
                        pathRow(L10n.text("devtools.path.temp"), FileManager.default.temporaryDirectory)
                        pathRow(L10n.text("devtools.path.preferences"), preferencesPlistURL)
                    }

                    DialogSection(L10n.text("devtools.section.actions")) {
                        actionRow(
                            "arrow.counterclockwise",
                            L10n.text("devtools.action.resetWelcome"),
                            L10n.text("devtools.action.resetWelcome.detail")
                        ) {
                            UserDefaults.standard.set(false, forKey: AppPreferences.Key.welcomeAssistantCompleted)
                            flash(L10n.text("devtools.feedback.welcomeReset"))
                        }
                        actionRow(
                            "exclamationmark.triangle",
                            L10n.text("devtools.action.simulateCrash"),
                            L10n.text("devtools.action.simulateCrash.detail")
                        ) {
                            UserDefaults.standard.set(false, forKey: "SimpleZip.session.cleanShutdown")
                            flash(L10n.text("devtools.feedback.crashArmed"))
                        }
                        actionRow(
                            "doc.on.clipboard",
                            L10n.text("devtools.action.copyReport"),
                            L10n.text("devtools.action.copyReport.detail")
                        ) {
                            Task { @MainActor in
                                let report = await DiagnosticsCopier.makeGeneralReport()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report, forType: .string)
                                flash(L10n.text("devtools.feedback.reportCopied"))
                            }
                        }
                    }

                    // 0.4.3 #12:自检样本库 —— 现造路径逃逸 / 加密 / 损坏 / 缺分卷等样本,
                    // 对装进 app 的真实后端逐项断言,发版前确认安全逻辑没回归。
                    DialogSection(L10n.text("devtools.section.selfTest")) {
                        HStack {
                            Button {
                                isRunningSamples = true
                                sampleResults = []
                                Task { @MainActor in
                                    sampleResults = await SelfTestSampleRunner.runAll()
                                    isRunningSamples = false
                                }
                            } label: {
                                Label(L10n.text("devtools.selfTest.run"), systemImage: "stethoscope")
                            }
                            .disabled(isRunningSamples)
                            if isRunningSamples {
                                ProgressView().controlSize(.small)
                            } else if !sampleResults.isEmpty {
                                let failed = sampleResults.filter { !$0.passed }.count
                                Text(failed == 0
                                     ? L10n.format("devtools.selfTest.allPassed", "\(sampleResults.count)")
                                     : L10n.format("devtools.selfTest.failures", "\(failed)", "\(sampleResults.count)"))
                                    .font(.caption)
                                    .foregroundStyle(failed == 0 ? Color.green : Color.red)
                            }
                        }
                        ForEach(sampleResults) { result in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.passed ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.name).font(.caption)
                                    Text(result.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    // 0.4.4 #6:格式兼容性实验室 —— 选小文件夹,对 zip/7z/tar/tar.gz 实测
                    // 结构/权限/xattr/symlink/时间戳/注释/可复现(样本复制进临时区加探针,原文件夹只读)。
                    DialogSection(L10n.text("devtools.section.formatLab")) {
                        HStack {
                            Button {
                                runFormatLab()
                            } label: {
                                Label(L10n.text("devtools.formatLab.run"), systemImage: "flask")
                            }
                            .disabled(isRunningFormatLab)
                            if isRunningFormatLab {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text(L10n.text("devtools.formatLab.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !formatLabResults.isEmpty {
                            formatLabMatrix
                        }
                    }

                    // 0.4.5 #80:AI 可用数据(只读)—— 让「喂给 AI 的本机数据」可查。涉密内容不在此列(也从不进 AI)。
                    DialogSection(L10n.text("devtools.section.aiData")) {
                        infoRow("sparkles", L10n.text("devtools.aiData.assistant"), aiAssistantStatus)
                        infoRow("archivebox", L10n.text("devtools.aiData.archiveMemory"), aiArchiveMemoryStatus)
                        infoRow("magnifyingglass", L10n.text("devtools.aiData.spotlight"), aiSpotlightStatus)
                        infoRow("folder.badge.gearshape", L10n.text("devtools.aiData.backgroundIndex"), aiBackgroundIndexStatus)
                        infoRow("rectangle.3.group.bubble", L10n.text("devtools.aiData.workspaces"), aiWorkspaceStatus)
                        infoRow("clock.badge.checkmark", L10n.text("devtools.aiData.activityTasks"), aiActivityTasksStatus)
                        actionRow(
                            "doc.on.clipboard",
                            L10n.text("devtools.action.copyAIWorkspaceFacts"),
                            L10n.text("devtools.action.copyAIWorkspaceFacts.detail")
                        ) {
                            copyAIWorkspaceFacts()
                        }
                    }

                    if let actionFeedback {
                        Label(actionFeedback, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    DialogSection(L10n.text("devtools.section.defaults")) {
                        defaultsSnapshotList
                        Button(L10n.text("devtools.defaults.copyAll")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(defaultsSnapshotText, forType: .string)
                            flash(L10n.text("devtools.feedback.defaultsCopied"))
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Spacer()
                Button(L10n.text("button.close")) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 620)
        .onAppear {
            Task { @MainActor in
                sevenZipVersion = await ArchiveService.sevenZipVersion()
                rarVersion = await ArchiveService.rarVersion()
            }
            loadAIDataSnapshot()
        }
    }

    // MARK: - 行构件

    @ViewBuilder
    private func infoRow(_ systemImage: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pathRow(_ label: String, _ url: URL) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(L10n.text("button.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func actionRow(_ systemImage: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                action()
            } label: {
                Image(systemName: systemImage)
            }
            .controlSize(.small)
        }
    }

    /// UserDefaults 快照(备份白名单口径)。展示截断到 60 字符,复制是全量。
    @ViewBuilder
    private var defaultsSnapshotList: some View {
        let snapshot = AppPreferences.exportableSnapshot().sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(snapshot, id: \.key) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 250, alignment: .leading)
                    Text(String(describing: value).prefix(60))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var defaultsSnapshotText: String {
        AppPreferences.exportableSnapshot()
            .sorted { $0.key < $1.key }
            .map { "\($0.key) = \(String(describing: $0.value))" }
            .joined(separator: "\n")
    }

    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimpleZip", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var preferencesPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(Bundle.main.bundleIdentifier ?? "SimpleZip").plist")
    }

    // MARK: - 0.4.4 #6 格式实验室

    private func runFormatLab() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("devtools.formatLab.pickFolder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isRunningFormatLab = true
        formatLabResults = []
        Task { @MainActor in
            formatLabResults = await FormatLabRunner.run(sampleFolder: folder)
            isRunningFormatLab = false
        }
    }

    /// 格式 × 维度矩阵:每格 ✓ / ✗(hover 看原因) / —(不适用)。
    @ViewBuilder
    private var formatLabMatrix: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(FormatLabRunner.Dimension.allCases) { dimension in
                    Text(L10n.text("devtools.formatLab.dim.\(dimension.rawValue)"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(formatLabResults) { result in
                GridRow {
                    Text(result.format.title)
                        .font(.caption.weight(.medium))
                    if let failure = result.setupFailure {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .gridCellColumns(FormatLabRunner.Dimension.allCases.count)
                    } else {
                        ForEach(FormatLabRunner.Dimension.allCases) { dimension in
                            verdictCell(result.verdicts[dimension])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func verdictCell(_ verdict: FormatLabRunner.Verdict?) -> some View {
        switch verdict {
        case .yes:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .no(let reason):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
                .help(reason)
        case .notApplicable, .none:
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 0.4.5 #80 AI 可用数据快照(只读)

    /// 读取 AI 助手就绪状态 + AI 能召回的本机派生数据规模。缓存 / Spotlight 统计走后台线程
    /// (可能读不小的 JSON),回主 actor 设 @State。只读、不涉密。
    private func loadAIDataSnapshot() {
        Task { @MainActor in
            let snapshot = await makeAIDataSnapshot()
            aiAssistantStatus = snapshot.assistant.ready
                ? L10n.text("devtools.aiData.assistant.ready")
                : snapshot.assistant.unavailableReason
            aiArchiveMemoryStatus = "\(snapshot.archiveMemory.archiveCount) · "
                + ByteCountFormatter.string(fromByteCount: Int64(snapshot.archiveMemory.storageByteSize), countStyle: .file)
            aiSpotlightStatus = "\(snapshot.spotlight.total)"
            aiBackgroundIndexStatus = L10n.format(
                "devtools.aiData.backgroundIndex.value",
                snapshot.backgroundIndex.activityLevel,
                "\(snapshot.backgroundIndex.scopeCount)",
                "\(snapshot.backgroundIndex.indexedFileCount)",
                "\(snapshot.backgroundIndex.folderProfileCount)"
            )
            aiWorkspaceStatus = L10n.format(
                "devtools.aiData.workspaces.value",
                "\(snapshot.workspaces.visible)",
                "\(snapshot.workspaces.total)",
                "\(snapshot.workspaces.recommended)",
                "\(snapshot.workspaces.userCreated)"
            )
            aiActivityTasksStatus = L10n.format(
                "devtools.aiData.activityTasks.value",
                "\(snapshot.activityTasks.active)",
                "\(snapshot.activityTasks.history)",
                "\(snapshot.activityTasks.failed)"
            )
        }
    }

    private func makeAIDataSnapshot() async -> DevToolsAIDataSnapshot {
        let archiveProbe = await Task.detached(priority: .utility) { () -> DevToolsArchiveCacheProbe in
            let store = ArchiveListingCacheStore()
            let entries = store.loadAll()
            return DevToolsArchiveCacheProbe(
                entries: entries,
                memory: DevToolsAIDataSnapshot.ArchiveMemory(
                    archiveCount: entries.count,
                    storageByteSize: store.storageByteSize(),
                    nonEncryptedFileEntries: entries.reduce(0) { $0 + $1.fileEntryCount },
                    truncatedArchives: entries.filter(\.truncated).count
                )
            )
        }.value
        let spotlight = await Task.detached(priority: .utility) { () -> DevToolsAIDataSnapshot.Spotlight in
            let stats = SpotlightReindex.stats()
            let total = stats.releases + stats.tasks + stats.archives + stats.archiveFiles + stats.settings
            return DevToolsAIDataSnapshot.Spotlight(
                releases: stats.releases,
                tasks: stats.tasks,
                archives: stats.archives,
                archiveFiles: stats.archiveFiles,
                settings: stats.settings,
                total: total
            )
        }.value
        let backgroundStore = AIBackgroundIndexStore.shared
        let budget = backgroundStore.budget
        let index = backgroundStore.fileIndex
        let workspaces = AIWorkspaceStore.shared.collection.workspaces
        let allTasks = TaskCenter.shared.active + TaskCenter.shared.history
        let taskRecords = allTasks.map(\.aiTaskRecord)
        let workbench = ActivityAIWorkbenchBuilder.snapshot(records: taskRecords)
        let systemWorkspaceFacts = aiWorkspaceFactsSnapshots(tasks: allTasks, cachedArchives: archiveProbe.entries)

        return DevToolsAIDataSnapshot(
            generatedAt: Date(),
            assistant: DevToolsAIDataSnapshot.Assistant(
                enabled: AppPreferences.aiAssistantEnabled,
                ready: AIReportAssistant.isReady,
                unavailableReason: AIReportAssistant.isReady
                    ? L10n.text("devtools.aiData.assistant.ready")
                    : AIReportAssistant.unavailableReason
            ),
            archiveMemory: archiveProbe.memory,
            spotlight: spotlight,
            backgroundIndex: DevToolsAIDataSnapshot.BackgroundIndex(
                backgroundEnabled: backgroundStore.backgroundEnabled,
                folderPreindexEnabled: backgroundStore.folderPreindexEnabled,
                archivePrefetchEnabled: backgroundStore.archivePrefetchEnabled,
                activityLevel: AppPreferences.aiBackgroundActivityLevel.rawValue,
                scopeCount: backgroundStore.scopes.count,
                indexedFileCount: index.fileCount,
                folderProfileCount: index.folderCount,
                maxIndexedFiles: index.maxFiles,
                budget: budget.map {
                    DevToolsAIDataSnapshot.BackgroundIndex.Budget(
                        maxDirectoriesPerRound: $0.maxDirectoriesPerRound,
                        maxArchivesPerRound: $0.maxArchivesPerRound,
                        maxEntriesPerArchive: $0.maxEntriesPerArchive
                    )
                }
            ),
            workspaces: DevToolsAIDataSnapshot.Workspaces(workspaces),
            activityTasks: DevToolsAIDataSnapshot.ActivityTasks(
                active: TaskCenter.shared.active.count,
                history: TaskCenter.shared.history.count,
                workbench: workbench
            ),
            systemWorkspaceFacts: systemWorkspaceFacts
        )
    }

    private func copyAIWorkspaceFacts() {
        Task { @MainActor in
            do {
                let snapshot = await makeAIDataSnapshot()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                guard let text = String(data: data, encoding: .utf8) else {
                    flash(L10n.format("devtools.feedback.aiWorkspaceFactsFailed", "UTF-8"))
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flash(L10n.text("devtools.feedback.aiWorkspaceFactsCopied"))
            } catch {
                flash(L10n.format("devtools.feedback.aiWorkspaceFactsFailed", error.localizedDescription))
            }
        }
    }

    private func aiWorkspaceFactsSnapshots(
        tasks: [OperationTask],
        cachedArchives: [ArchiveListingCacheEntry]
    ) -> [AISystemWorkspaceFactsSnapshot] {
        let tasks = tasks.map { $0.aiWorkspaceFact }
        let archives = cachedArchives.map { $0.aiWorkspaceFact }
        return AISystemWorkspaceKind.allCases.map {
            AISystemWorkspaceFactsBuilder.snapshot(kind: $0, tasks: tasks, archives: archives)
        }
    }

    private func flash(_ text: String) {
        withAnimation { actionFeedback = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { actionFeedback = nil }
        }
    }
}

private struct DevToolsArchiveCacheProbe {
    let entries: [ArchiveListingCacheEntry]
    let memory: DevToolsAIDataSnapshot.ArchiveMemory
}

private struct DevToolsAIDataSnapshot: Encodable {
    struct Assistant: Encodable {
        let enabled: Bool
        let ready: Bool
        let unavailableReason: String
    }

    struct ArchiveMemory: Encodable {
        let archiveCount: Int
        let storageByteSize: Int
        let nonEncryptedFileEntries: Int
        let truncatedArchives: Int
    }

    struct Spotlight: Encodable {
        let releases: Int
        let tasks: Int
        let archives: Int
        let archiveFiles: Int
        let settings: Int
        let total: Int
    }

    struct BackgroundIndex: Encodable {
        struct Budget: Encodable {
            let maxDirectoriesPerRound: Int
            let maxArchivesPerRound: Int
            let maxEntriesPerArchive: Int
        }

        let backgroundEnabled: Bool
        let folderPreindexEnabled: Bool
        let archivePrefetchEnabled: Bool
        let activityLevel: String
        let scopeCount: Int
        let indexedFileCount: Int
        let folderProfileCount: Int
        let maxIndexedFiles: Int
        let budget: Budget?
    }

    struct Workspaces: Encodable {
        let visible: Int
        let total: Int
        let recommended: Int
        let userCreated: Int
        let hidden: Int
        let dismissed: Int
        let pinned: Int
        let described: Int

        init(_ workspaces: [AIWorkspace]) {
            self.visible = workspaces.filter { $0.visibility == .visible }.count
            self.total = workspaces.count
            self.recommended = workspaces.filter { $0.origin == .recommended }.count
            self.userCreated = workspaces.filter { $0.origin == .userCreated }.count
            self.hidden = workspaces.filter { $0.visibility == .hidden }.count
            self.dismissed = workspaces.filter { $0.visibility == .dismissed }.count
            self.pinned = workspaces.filter(\.pinned).count
            self.described = workspaces.filter { $0.userDescription != nil }.count
        }
    }

    struct ActivityTasks: Encodable {
        let active: Int
        let history: Int
        let failed: Int
        let running: Int
        let succeeded: Int
        let skipped: Int
        let cancelled: Int
        let workbench: ActivityAIWorkbenchSnapshot

        init(active: Int, history: Int, workbench: ActivityAIWorkbenchSnapshot) {
            self.active = active
            self.history = history
            self.failed = workbench.summary.failedSeen + workbench.summary.failedUnseen
            self.running = workbench.summary.running
            self.succeeded = workbench.summary.succeeded
            self.skipped = workbench.summary.skipped
            self.cancelled = workbench.summary.cancelled
            self.workbench = workbench
        }
    }

    let schema = "simplezip.devtools.aiData.v1"
    let generatedAt: Date
    let assistant: Assistant
    let archiveMemory: ArchiveMemory
    let spotlight: Spotlight
    let backgroundIndex: BackgroundIndex
    let workspaces: Workspaces
    let activityTasks: ActivityTasks
    let systemWorkspaceFacts: [AISystemWorkspaceFactsSnapshot]
}
