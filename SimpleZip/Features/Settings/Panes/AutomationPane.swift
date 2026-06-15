//
//  AutomationPane.swift
//  SimpleZip
//
//  0.4.4 #1:自动化中心 —— 四条自动化通道(CLI / Shortcuts·Siri / URL Scheme / Finder 服务)
//  的状态、入口与按来源统计,一页看全。CLI 安装区从「通用」页整体搬来(单一归属,不留两处入口);
//  Finder 服务的逐项开关仍在「通用」页管理,这里只读总览。
//

import AppKit
import SwiftUI

struct AutomationPane: View {
    @State private var cliStatus: CommandLineToolInstaller.Status = .missing
    @State private var cliManualCommand: String?
    @State private var cliMessage: String?
    /// #1 唯一新偏好:自动化通道(CLI / Shortcuts)允许用预设密码。默认 true 保持现行为;
    /// 关掉后无人值守流程只试空密码,绝不静默动用预设。
    @AppStorage(AppPreferences.Key.automationAllowPresetPassword) private var allowPresetPassword = true
    /// 0.4.4 macOS 26 AI:是否把发布包 / 任务捐献进 Spotlight。默认 true = 便利;关 = 更私密(并清空已索引)。
    @AppStorage(AppPreferences.Key.spotlightIndexingEnabled) private var spotlightIndexing = true
    /// 0.4.4 macOS 26 AI:AI 报告助手主开关。关 → 所有 AI 入口隐藏。
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiAssistant = true
    /// #34/#36:归档内容缓存控制(开关 / 归档数上限 / 过期天数)。关 → 停止缓存并清空。
    @AppStorage(AppPreferences.Key.archiveListingCacheEnabled) private var archiveCacheEnabled = true
    @AppStorage(AppPreferences.Key.archiveListingCacheMaxArchives) private var archiveCacheMax = AppPreferences.archiveListingCacheMaxArchives
    @AppStorage(AppPreferences.Key.archiveListingCacheTTLDays) private var archiveCacheTTL = AppPreferences.archiveListingCacheTTLDays
    /// 当前缓存占用(条数 + 字节)—— 仅展示,onAppear 与每次改动后刷新。
    @State private var archiveCacheCount = 0
    @State private var archiveCacheBytes = 0
    /// #73:Spotlight 索引数据(发布包 / 任务 / 归档 / 文件 / 设置各多少会被索引)+ 「强制重新索引」反馈。
    @State private var spotlightStats: SpotlightReindex.Stats?
    @State private var spotlightReindexMessage: String?

    @ObservedObject private var taskCenter = TaskCenter.shared

    /// #42:发布路径健康检查结果(工作区预设目录 + 账本产物路径)。按需点「检查」才跑,不自动扫。
    @State private var pathHealthEntries: [PathHealthCheck.Entry] = []
    @State private var pathHealthChecked = false

    var body: some View {
        Form {
            // ① CLI(安装区自「通用」整体搬来)。
            Section(L10n.text("settings.cli.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.cli.title"),
                    description: L10n.text("settings.cli.description"),
                    systemImage: "terminal", iconTint: .indigo
                ) {
                    HStack(spacing: 8) {
                        if cliStatus != .installed {
                            Button {
                                installCLITool()
                            } label: {
                                Label(L10n.text("settings.cli.install"), systemImage: "link")
                            }
                            // 转译位置(隔离未清的 DMG 直跑)装出来的链接指向一次性挂载路径,禁装。
                            .disabled(CommandLineToolInstaller.isRunningTranslocated)
                        }
                        // 链接存在就给卸载(指向当前 app 或指向别处都算)—— 有装必有卸。
                        if cliStatus != .missing {
                            Button {
                                uninstallCLITool()
                            } label: {
                                Label(L10n.text("settings.cli.uninstall"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                Text(cliStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if CommandLineToolInstaller.isRunningTranslocated {
                    Text(L10n.text("settings.cli.translocated"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cliManualCommand {
                    // 没有 /usr/local/bin 写权限时不提权 —— 给出可复制的终端命令,用户自己 sudo。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("settings.cli.manualHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(cliManualCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cliManualCommand, forType: .string)
                                cliMessage = L10n.text("diagnostics.copied")
                            } label: {
                                Label(L10n.text("settings.cli.copyCommand"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                if let cliMessage {
                    Text(cliMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                lastRunRow(for: .cli)
            }
            .onAppear(perform: reloadCLIStatus)
            .settingsAnchor("automation.cli")

            // ② Shortcuts / Siri。0.4.5:不隐藏、改为**显式标不可用** —— ad-hoc 构建(无 Apple TeamIdentifier)下
            // App Intents 被 linkd 以 requiresValidatedBundle 拒、动作注定失败,但系统层仍会在「快捷指令」app 里
            // 列出这些动作(in-app 无法移除),所以照常显示该节、并在无签名时打橙色「不可用」标识;运行状态页也会标黄。
            // CLI / URL Scheme / Finder 服务 / Spotlight 等其余自动化通道不走这条链,照常可用,不受影响。
            Section(L10n.text("settings.automation.shortcuts.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.shortcuts.title"),
                    description: L10n.text("settings.automation.shortcuts.description"),
                    systemImage: "sparkles.rectangle.stack", iconTint: .purple
                ) {
                    Button {
                        if let url = URL(string: "shortcuts://") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(L10n.text("settings.automation.shortcuts.open"), systemImage: "arrow.up.forward.app")
                    }
                }
                .settingsAnchor("automation.shortcuts")
                // 无 Apple 签名 → 动作跑不起来,显式标橙色不可用(系统层动作无法在 app 内移除,只能如实告知)。
                if !AppSigningStatus.supportsShortcuts {
                    Label(L10n.text("settings.automation.shortcuts.unavailable"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("settings.automation.shortcuts.actions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // #70(macOS 26 AI):据使用习惯起草一个 Shortcuts / 自动化点子(草稿,用户自建)。仅 isReady 时出现。
                if AIReportAssistant.isReady {
                    AIAssistButton(
                        label: L10n.text("ai.suggestAutomation"),
                        systemImage: "sparkles",
                        sheetTitle: L10n.text("ai.suggestAutomation.title"),
                        sheetSubtitle: L10n.text("settings.automation.shortcuts.title")
                    ) {
                        guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                        let built = AIReportAssistant.automationSuggestionPrompt(usageSummary: automationUsageSummary())
                        return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                    }
                }
                lastRunRow(for: .intent)
            }

            // ②.5 Spotlight 索引(发布包 / 任务可搜;安全↔便利)。开关切换即时重建或清空索引。
            Section(L10n.text("settings.automation.spotlight.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.spotlight.title"),
                    description: L10n.text("settings.automation.spotlight.description"),
                    systemImage: "magnifyingglass", iconTint: .blue,
                    isOn: $spotlightIndexing
                )
                .onChange(of: spotlightIndexing) { _ in
                    // indexer 内部按 `spotlightIndexingEnabled` 分支:开→重建、关→清空已捐献的索引。
                    ReleasePackageSpotlightIndexer.reindex()
                    ArchiveTaskSpotlightIndexer.reindex()
                    // #35:归档内容 Spotlight 捐献是双门控,这把总开关也管它。
                    CachedArchiveSpotlightIndexer.reindex()
                    ArchiveFileSpotlightIndexer.reindex()
                    // #30:设置项索引也归这把总开关管(开 → 重建、关 → 清空)。
                    SettingsSpotlightIndexer.reindex()
                    // #31:活动中心(设置 / 临时工作区)选项索引同归这把总开关管。
                    ActivitySpotlightIndexer.reindex()
                    refreshSpotlightStats()
                }

                // #73:索引不全 / 不稳定时,「强制重新索引」清空 app 全部捐献再全量重建。
                SettingsActionRow(
                    title: L10n.text("settings.automation.spotlight.reindex.title"),
                    description: L10n.text("settings.automation.spotlight.reindex.description"),
                    systemImage: "arrow.clockwise", iconTint: .blue,
                    buttonTitle: L10n.text("settings.automation.spotlight.reindex.button"),
                    action: {
                        SpotlightReindex.force()
                        spotlightReindexMessage = L10n.text("settings.automation.spotlight.reindex.started")
                    }
                )
                if let spotlightStats {
                    Text(L10n.format("settings.automation.spotlight.stats",
                                     "\(spotlightStats.archives)", "\(spotlightStats.archiveFiles)",
                                     "\(spotlightStats.settings)", "\(spotlightStats.total)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let spotlightReindexMessage {
                    Text(spotlightReindexMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsAnchor("automation.spotlight")
            .onAppear(perform: refreshSpotlightStats)

            // ②.55 #36 归档内容缓存:记住打开过的归档里有哪些文件,供「文件 X 在哪个包」搜索。
            // 开关 / 归档数上限 / 过期天数 / 立即清空;关掉即清空已缓存内容。
            Section(L10n.text("settings.automation.cache.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.cache.enabled.title"),
                    description: L10n.text("settings.automation.cache.enabled.description"),
                    systemImage: "archivebox", iconTint: .blue,
                    isOn: $archiveCacheEnabled
                )
                .onChange(of: archiveCacheEnabled) { isOn in
                    // 关掉 = 停止缓存并清空已记内容(隐私优先)。
                    if !isOn { ArchiveListingCacheStore().clear() }
                    // #35:缓存开关也是归档内容 Spotlight 捐献的门控 —— 关→清空已捐献项,开→按缓存重建。
                    CachedArchiveSpotlightIndexer.reindex()
                    ArchiveFileSpotlightIndexer.reindex()
                    refreshArchiveCacheStats()
                }

                if archiveCacheEnabled {
                    SettingsControlRow(
                        title: L10n.text("settings.automation.cache.maxArchives.title"),
                        description: L10n.text("settings.automation.cache.maxArchives.description"),
                        systemImage: "number", iconTint: .teal
                    ) {
                        HStack(spacing: 8) {
                            Text(L10n.format("settings.automation.cache.maxArchives.value", archiveCacheMax))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .trailing)
                            Stepper("", value: $archiveCacheMax, in: 1...500)
                                .labelsHidden()
                        }
                        .onChange(of: archiveCacheMax) { newValue in
                            AppPreferences.archiveListingCacheMaxArchives = newValue
                            ArchiveListingCacheStore().applyCurrentLimits()
                            CachedArchiveSpotlightIndexer.reindex()
                            ArchiveFileSpotlightIndexer.reindex()
                            refreshArchiveCacheStats()
                        }
                    }

                    SettingsControlRow(
                        title: L10n.text("settings.automation.cache.ttl.title"),
                        description: L10n.text("settings.automation.cache.ttl.description"),
                        systemImage: "clock.arrow.circlepath", iconTint: .indigo
                    ) {
                        HStack(spacing: 8) {
                            Text(archiveCacheTTL == 0
                                ? L10n.text("settings.automation.cache.ttl.never")
                                : L10n.format("settings.automation.cache.ttl.value", archiveCacheTTL))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .trailing)
                            Stepper("", value: $archiveCacheTTL, in: 0...365)
                                .labelsHidden()
                        }
                        .onChange(of: archiveCacheTTL) { newValue in
                            AppPreferences.archiveListingCacheTTLDays = newValue
                            ArchiveListingCacheStore().applyCurrentLimits()
                            CachedArchiveSpotlightIndexer.reindex()
                            ArchiveFileSpotlightIndexer.reindex()
                            refreshArchiveCacheStats()
                        }
                    }

                    SettingsActionRow(
                        title: L10n.text("settings.automation.cache.clear.title"),
                        description: L10n.text("settings.automation.cache.clear.description"),
                        systemImage: "trash", iconTint: .red,
                        buttonTitle: L10n.text("settings.automation.cache.clear.button"),
                        role: .destructive,
                        isDisabled: archiveCacheCount == 0,
                        action: {
                            ArchiveListingCacheStore().clear()
                            CachedArchiveSpotlightIndexer.reindex()
                            ArchiveFileSpotlightIndexer.reindex()
                            refreshArchiveCacheStats()
                        }
                    )

                    Text(archiveCacheCount == 0
                        ? L10n.text("settings.automation.cache.status.empty")
                        : L10n.format("settings.automation.cache.status",
                                      "\(archiveCacheCount)",
                                      ByteCountFormatter.string(fromByteCount: Int64(archiveCacheBytes), countStyle: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear(perform: refreshArchiveCacheStats)
            .settingsAnchor("automation.cache")

            // ②.6 AI 报告助手(macOS 26 本地模型):总结风险 / 解释失败 / 建议标签 / Issue 草稿。
            // 主开关关 → 所有 AI 入口隐藏;开但模型不可用(旧系统 / 没开 Apple Intelligence / 没下完)→ 说明文案。
            Section(L10n.text("settings.automation.ai.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.ai.title"),
                    description: L10n.text("settings.automation.ai.description"),
                    systemImage: "sparkles", iconTint: .purple,
                    isOn: $aiAssistant
                )
                if aiAssistant, !AIReportAssistant.isReady {
                    Text(AIReportAssistant.unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsAnchor("automation.ai")

            // ③ URL Scheme(展示型:现状即「每次都要 app 内确认」,不提供关闭项)。
            Section(L10n.text("settings.automation.urlScheme.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.urlScheme.title"),
                    description: L10n.text("settings.automation.urlScheme.description"),
                    systemImage: "link.circle", iconTint: .cyan
                ) {
                    Text(L10n.text("settings.automation.urlScheme.confirmAlways"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "simplezip://check?path=/…  ·  simplezip://compare?left=/…&right=/…  ·  simplezip://open?path=/…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                lastRunRow(for: .urlScheme)
            }

            // ④ Finder 服务(逐项开关在「通用」页;这里只读总览 + 最近一次)。
            Section(L10n.text("settings.automation.finder.section")) {
                SettingsControlRow(
                    title: L10n.text("settings.automation.finder.title"),
                    description: L10n.text("settings.automation.finder.description"),
                    systemImage: "contextualmenu.and.cursorarrow", iconTint: .orange
                ) {
                    Button {
                        NotificationCenter.default.post(name: .openSettingsPane, object: SettingsPane.general)
                    } label: {
                        Label(L10n.text("settings.automation.finder.manage"), systemImage: "gearshape")
                    }
                }
                lastRunRow(for: .finder)
            }

            // ⑤ 统计:活动中心历史按来源聚合(F1 的字段在此兑现)。
            Section(L10n.text("settings.automation.stats.section")) {
                statsRow(.cli, systemImage: "terminal", tint: .indigo)
                // 快捷指令 / Siri 来源统计:仅有合法签名时显示 —— 无签名时这条链注定跑不起来,
                // 显示一行「0 次」的统计毫无意义(功能不可用已在上面的 Shortcuts 节明示)。
                if AppSigningStatus.supportsShortcuts {
                    statsRow(.intent, systemImage: "sparkles.rectangle.stack", tint: .purple)
                }
                statsRow(.urlScheme, systemImage: "link.circle", tint: .cyan)
                statsRow(.finder, systemImage: "contextualmenu.and.cursorarrow", tint: .orange)
            }

            // ⑥ 安全闸:自动化通道的预设密码使用。
            Section(L10n.text("settings.automation.security.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.allowPresetPassword"),
                    description: L10n.text("settings.automation.allowPresetPassword.description"),
                    systemImage: "key", iconTint: .orange,
                    isOn: $allowPresetPassword
                )
            }
            .settingsAnchor("automation.allowPresetPassword")

            // ⑦ #42:发布路径健康 —— 工作区预设的源/输出目录、账本里的产物路径,跨重启后还在不在。
            Section(L10n.text("settings.automation.pathHealth.section")) {
                SettingsActionRow(
                    title: L10n.text("settings.automation.pathHealth.title"),
                    description: L10n.text("settings.automation.pathHealth.description"),
                    systemImage: "externaldrive.badge.questionmark", iconTint: .teal,
                    buttonTitle: L10n.text("settings.automation.pathHealth.check"),
                    action: checkPathHealth
                )
                .settingsAnchor("automation.pathHealth")
                if pathHealthChecked {
                    let problems = pathHealthEntries.filter { $0.status != .accessible }
                    if problems.isEmpty {
                        Label(
                            L10n.format("settings.automation.pathHealth.allOK", "\(pathHealthEntries.count)"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    } else {
                        ForEach(problems) { entry in
                            pathHealthRow(entry)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        // #29:让深链 / Spotlight 跳转能滚到本页某个设置项并高亮。
        .settingsScrollAnchors()
    }

    // MARK: - #36 归档内容缓存

    /// #73:后台算 Spotlight 索引统计(读缓存 JSON 可能不小,别卡主线程),回主 actor 设 @State。
    private func refreshSpotlightStats() {
        Task {
            let stats = await Task.detached(priority: .utility) { SpotlightReindex.stats() }.value
            spotlightStats = stats
        }
    }

    /// 刷新缓存占用展示(顺手清过期项)。轻量,onAppear 与每次开关 / 步进 / 清空后调。
    private func refreshArchiveCacheStats() {
        let store = ArchiveListingCacheStore()
        store.pruneExpiredInPlace()
        archiveCacheCount = store.count()
        archiveCacheBytes = store.storageByteSize()
    }

    // MARK: - #42 路径健康

    private func pathHealthRow(_ entry: PathHealthCheck.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.status == .missing ? "xmark.circle.fill" : "lock.circle.fill")
                .foregroundStyle(entry.status == .missing ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.source).font(.callout)
                Text(entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
            }
            Spacer(minLength: 8)
            Text(L10n.text("settings.automation.pathHealth.status.\(entry.status.rawValue)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // 存在但不可读 → 能在 Finder 里定位;不存在的没法 reveal(文件没了)。
            if entry.status == .unreadable {
                Button(L10n.text("button.revealInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func checkPathHealth() {
        let items = Self.gatherReleasePaths()
        Task {
            // classify 触磁盘 → 放后台;回主 actor 设 @State。
            let entries = await Task.detached(priority: .utility) { PathHealthCheck.report(items) }.value
            pathHealthEntries = entries
            pathHealthChecked = true
        }
    }

    /// 汇总所有持久化的发布相关路径:每个工作区预设的源 / 输出目录 + 账本每条产物路径。
    private static func gatherReleasePaths() -> [(source: String, path: String)] {
        var items: [(source: String, path: String)] = []
        for preset in ReleaseWorkspacePresetStore().loadAll() {
            if let source = preset.sourceFolderPath, !source.isEmpty {
                items.append((L10n.format("settings.automation.pathHealth.source.presetSource", preset.name), source))
            }
            if let destination = preset.destinationFolderPath, !destination.isEmpty {
                items.append((L10n.format("settings.automation.pathHealth.source.presetOutput", preset.name), destination))
            }
        }
        for entry in ReleaseLedgerStore().loadAll() {
            let label = entry.versionLabel.isEmpty
                ? URL(fileURLWithPath: entry.artifactPath).lastPathComponent
                : entry.versionLabel
            items.append((L10n.format("settings.automation.pathHealth.source.ledgerArtifact", label), entry.artifactPath))
        }
        return items
    }

    // MARK: - 来源统计

    private func tasks(from source: OperationTask.Source) -> [OperationTask] {
        (taskCenter.active + taskCenter.history).filter { $0.source == source }
    }

    /// 「最近一次:<时间>」行(该来源没跑过 = 整行不渲染)。
    @ViewBuilder
    private func lastRunRow(for source: OperationTask.Source) -> some View {
        if let last = tasks(from: source).map({ $0.finishedAt ?? $0.startedAt }).max() {
            Text(L10n.format("settings.automation.lastRun", last.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// #70:把活动历史聚合成「按触发来源 / 按操作类型」的计数摘要喂给 AI(只聚合计数,无文件名/无内容)。
    private func automationUsageSummary() -> String {
        let history = taskCenter.history
        guard !history.isEmpty else { return "No recorded operations yet." }
        var lines: [String] = ["Total recorded operations: \(history.count)."]
        let bySource = Dictionary(grouping: history, by: { $0.source.rawValue }).mapValues { $0.count }
        lines.append("By trigger — " + bySource.sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ".")
        let byKind = Dictionary(grouping: history, by: { $0.kind.rawValue }).mapValues { $0.count }
        lines.append("By operation — " + byKind.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    private func statsRow(_ source: OperationTask.Source, systemImage: String, tint: Color) -> some View {
        let sourceTasks = tasks(from: source)
        let failures = sourceTasks.filter { if case .failed = $0.status { return true } else { return false } }.count
        return SettingsControlRow(
            title: L10n.text("tasks.source.\(source.rawValue)"),
            description: L10n.text("settings.automation.stats.row.description"),
            systemImage: systemImage, iconTint: tint
        ) {
            Text(sourceTasks.isEmpty
                 ? L10n.text("settings.automation.stats.never")
                 : L10n.format("settings.automation.stats.value", "\(sourceTasks.count)", "\(failures)"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - CLI companion(自 GeneralPane 整体搬来)

    private var cliStatusText: String {
        switch cliStatus {
        case .installed:
            return L10n.format("settings.cli.status.installed", CommandLineToolInstaller.linkPath)
        case .missing:
            return L10n.text("settings.cli.status.missing")
        case .foreign(let destination):
            return L10n.format("settings.cli.status.foreign", destination)
        }
    }

    private func reloadCLIStatus() {
        cliStatus = CommandLineToolInstaller.status()
    }

    private func installCLITool() {
        do {
            try CommandLineToolInstaller.install()
            cliManualCommand = nil
            cliMessage = nil
        } catch CommandLineToolInstaller.InstallError.cancelled {
            // 用户在系统授权弹窗点了取消 —— 不是失败,什么都不弹。
        } catch {
            // 授权路径也失败(罕见)→ 给可复制的手动命令兜底。
            cliManualCommand = CommandLineToolInstaller.manualInstallCommand
            cliMessage = nil
        }
        reloadCLIStatus()
    }

    private func uninstallCLITool() {
        do {
            try CommandLineToolInstaller.uninstall()
            cliManualCommand = nil
            cliMessage = nil
        } catch CommandLineToolInstaller.InstallError.cancelled {
            // 取消授权 —— 静默。
        } catch {
            cliManualCommand = CommandLineToolInstaller.manualUninstallCommand
            cliMessage = nil
        }
        reloadCLIStatus()
    }
}
