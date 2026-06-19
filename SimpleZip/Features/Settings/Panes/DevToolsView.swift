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
import Combine
import SwiftUI

struct DevToolsView: View {
    let onClose: () -> Void
    /// DevTools 调试开关:开 = 完全豁免交互门控(挂着 DevTools 观察后台 AI 真在跑);关 = 正常计交互(验证交互一动
    /// AI 就停)。关闭 DevTools 强制复位。@State 随 sheet 重建归 false,与 indexer 旗一致。
    @State private var aiInteractionExempt = false

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
    /// AI 建议各 pass 的产物计数(摘要 / 打开方式 / 装App / 活动 / 包内),让「pass 到底有没有生效」可查。
    @State private var aiSuggestionStatus = "…"
    /// #8 跨表面反馈 / 兴趣信号事件计数(「我不喜欢」/ 点击学兴趣),让软降权学习数据可查。
    @State private var aiFeedbackStatus = "…"
    @State private var aiActivityTasksStatus = "…"
    /// 后台是否在跑 + 各档闸实时状态(回答「为啥都是 0」—— 哪一档被卡)。
    @State private var aiGateStatus = "…"
    /// 每个 pass 上次跑的候选数 / 跳过原因(区分「无候选」和「门控没过 / 没跑过」)。
    @State private var aiPassDiagStatus = "…"
    @State private var aiDataSnapshotInFlight = false

    private let aiDataRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                        infoRow("bolt.horizontal", "后台运行 / 门控", aiGateStatus)
                        Toggle(isOn: $aiInteractionExempt) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("豁免交互门控(调试)").font(.callout)
                                Text("开 = 挂着 DevTools 也当成空闲,后台 AI 照跑(立即评一轮);关 = 正常计交互,验证「一动就停」。关 DevTools 自动复位。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: aiInteractionExempt) { on in
                            AIBackgroundIndexer.shared.setDevToolsExemption(on)
                        }
                        diagRow("list.bullet.rectangle", "各管线候选诊断", aiPassDiagStatus)
                        diagRow("text.bubble", "AI 建议产物", aiSuggestionStatus)
                        infoRow("hand.thumbsdown", "AI 反馈学习", aiFeedbackStatus)
                        infoRow("clock.badge.checkmark", L10n.text("devtools.aiData.activityTasks"), aiActivityTasksStatus)
                        actionRow(
                            "doc.on.clipboard",
                            L10n.text("devtools.action.copyAIIndexData"),
                            L10n.text("devtools.action.copyAIIndexData.detail")
                        ) {
                            copyAIIndexData()
                        }
                        actionRow(
                            "trash",
                            "清空 AI 文件索引",
                            "调用 clearFileIndex(),清空后台文件预索引、文件组/整理缓存、反馈学习和自动检查队列;不删除真实文件。"
                        ) {
                            AIBackgroundIndexStore.shared.clearFileIndex()
                            loadAIDataSnapshot()
                            flash("已清空 AI 文件索引")
                        }
                        // AI 建议明细:每个计数类别(摘要/打开方式/网页/.../哈希/压缩/转换/内联结果)的**完整文件清单**
                        // + 门控 / 预算 / 各管线诊断 —— 一次性复制出来逐条 debug「这个类别到底有哪些文件、为啥是 0」。
                        actionRow(
                            "list.bullet.clipboard",
                            "复制 AI 建议明细(全分类 + 每文件 + 管线)",
                            "把上面每个计数展开成完整清单:每类列出命中的真实文件路径 + 短摘要 + 动作 / 内联结果,附门控 / 预算 / 管线诊断。"
                        ) {
                            copyAISuggestionDetail()
                        }
                        // Spotlight 全量捐献集复制(每条 item 的标识/标题/关键字)——隐藏调试区,中文硬编码。
                        actionRow(
                            "magnifyingglass.circle",
                            "复制 Spotlight 数据集(完整)",
                            "导出每一条会捐献给 Spotlight 的 item(标识 / 标题 / 描述 / 关键字),逐条排查索引内容。"
                        ) {
                            copySpotlightData()
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
        .onReceive(aiDataRefreshTimer) { _ in
            loadAIDataSnapshot()
        }
        .onDisappear {
            aiInteractionExempt = false
            AIBackgroundIndexer.shared.setDevToolsExemption(false)   // 关 DevTools 强制复位,豁免不外泄
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

    /// infoRow 的不截断版(诊断用 —— 长内容 / 多行全显,不被 lineLimit(2) 砍掉)。
    private func diagRow(_ systemImage: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
        guard !aiDataSnapshotInFlight else { return }
        aiDataSnapshotInFlight = true
        Task { @MainActor in
            defer { aiDataSnapshotInFlight = false }
            let snapshot = await makeAIDataSnapshot()
            aiAssistantStatus = snapshot.assistant.ready
                ? L10n.text("devtools.aiData.assistant.ready")
                : snapshot.assistant.unavailableReason
            aiArchiveMemoryStatus = "\(snapshot.archiveMemory.archiveCount) · "
                + ByteCountFormatter.string(fromByteCount: Int64(snapshot.archiveMemory.storageByteSize), countStyle: .file)
            // Spotlight 各域分解(发布/任务/归档/归档内文件/设置),一眼看出哪个域没进索引。
            let sp = snapshot.spotlight
            aiSpotlightStatus = "发布 \(sp.releases) · 任务 \(sp.tasks) · 归档 \(sp.archives)"
                + " · 归档内文件 \(sp.archiveFiles) · 设置 \(sp.settings) · 合计 \(sp.total)"
            aiBackgroundIndexStatus = L10n.format(
                "devtools.aiData.backgroundIndex.value",
                snapshot.backgroundIndex.activityLevel,
                "\(snapshot.backgroundIndex.scopeCount)",
                "\(snapshot.backgroundIndex.indexedFileCount)",
                "\(snapshot.backgroundIndex.folderProfileCount)"
            )
            // 内容摘要总数 + 内容预读是否开(预读没开则各 pass 都不会跑)。
            + " · 内容摘要 \(snapshot.backgroundIndex.contentSummaryCount)"
            + "(预读\(snapshot.backgroundIndex.contentPrereadEnabled ? "开" : "关"))"
            // AI 建议各 pass 的实际产物计数 —— 一眼看出每个 pass 有没有生效(0 = 还没出 / 没候选 / 没开)。
            let s = snapshot.backgroundIndex
            aiSuggestionStatus = "摘要 \(s.summaryCount) · 打开方式 \(s.openWithCount) · 网页 \(s.urlOpenCount) · 装App \(s.installCount)"
                + " · 活动 \(s.activityCount) · 包内 \(s.archiveEntryCount) · 包定性 \(s.archiveKindCount)"
                + " · 文件组 \(s.folderGroupCount) · 整理 \(s.organizeCount)"
                // 主动工具(归档:检测 / 测试 / 哈希 / 安全;文件:压缩 / 转换)—— security 之前漏了计数,补上这一个。
                + " · 检测 \(s.inspectCount) · 测试 \(s.testCount) · 哈希 \(s.hashCount) · 安全 \(s.securityCount)"
                + " · 压缩 \(s.compressCount) · 转换 \(s.convertCount)"
                // 自动检查执行后**回填抽屉的内联结果**记录数(总数,非逐行为 —— 逐行为会和上面建议计数重复)。逐条明细见「复制建议明细」。
                + " · 内联结果 \(s.inlineResultCount)"
            // #8 跨表面反馈学习:事件计数(原始保留 30 天 / 每类上限 1000)。
            let fb = AIFeedbackStore.shared.counts
            let pc = AIPendingCheckStore.shared.counts
            aiFeedbackStatus = "我不喜欢 \(fb.feedback) · 兴趣信号 \(fb.signals) · 自动检查 待\(pc.pending)/完\(pc.done)"

            // 后台运行 + 各档闸实时状态(直接回答「为啥都是 0」:哪一档 ✗ 就卡在哪)。
            let g = AIBackgroundIndexer.shared.gateDiag()
            func yn(_ b: Bool) -> String { b ? "✓" : "✗" }
            func rel(_ d: Date?) -> String {
                guard let d else { return "从未" }
                let s = Int(Date().timeIntervalSince(d))
                return s < 60 ? "\(s)秒前" : (s < 3_600 ? "\(s / 60)分前" : "\(s / 3_600)时前")
            }
            let charge = g.isCharging.map { $0 ? "是" : "否" } ?? "无电池"
            aiGateStatus = "在跑\(yn(AIBackgroundIndexer.shared.isIndexerRunning)) 上轮\(rel(AIBackgroundIndexer.shared.lastFullRunAt))"
                + (g.devToolsExempt ? " · 交互豁免✓" : "")
                + " | 确定性\(yn(g.canDeterministic)) 模型\(yn(g.canModelWork)) 深档\(yn(g.canDeepContext))"
                + " | 活跃\(g.appIsActive ? "是" : "否") 距交互\(g.devToolsExempt ? "豁免" : "\(g.secondsSinceLastInteraction)s") 充电\(charge)"
                + " 低电\(g.lowBattery ? "是" : "否") 省电\(g.powerSaverMode ? "是" : "否") 档\(g.activityLevel) 模型\(g.modelAvailable ? "就绪" : "无")"
            // 每个 pass 上次跑的候选数(区分「无候选」vs「门控没过 / 没跑过」)。
            let diag = AIBackgroundIndexer.shared.passDiag
            aiPassDiagStatus = AIDevToolsPipelineCatalog.rows(for: s.pipelineProductCounts).map { row in
                if let passName = row.passName, let d = diag[passName] {
                    if row.name == passName {
                        return "\(row.name):候选\(d.candidates) · 缓存产物\(row.cachedProductCount)\(d.skip.map { " " + $0 } ?? "") · \(rel(d.lastRunAt))"
                    }
                    return "\(row.name):缓存产物\(row.cachedProductCount) · 共用\(passName)候选\(d.candidates)\(d.skip.map { " " + $0 } ?? "") · \(rel(d.lastRunAt))"
                }
                let sharedPass = row.passName.flatMap { $0 == row.name ? nil : $0 }
                let shared = sharedPass.map { " · 共用\($0)管线" } ?? ""
                return "\(row.name):缓存产物\(row.cachedProductCount)\(shared) · 本会话没跑(看上面门控)"
            }.joined(separator: "\n")
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
        let allTasks = TaskCenter.shared.active + TaskCenter.shared.history
        let taskRecords = allTasks.map(\.aiTaskRecord)
        let workbench = ActivityAIWorkbenchBuilder.snapshot(records: taskRecords)
        // AI 建议各 pass 的产物计数:看每个 pass 有没有生效。
        let records = index.records
        func countAction(_ token: String) -> Int {
            records.reduce(0) { $0 + (($1.contentSummary?.suggestedActions.contains { $0.token == token } ?? false) ? 1 : 0) }
        }
        let summaryCount = records.reduce(0) { $0 + (($1.contentSummary?.shortSummary?.isEmpty == false) ? 1 : 0) }
        let organizeCount = backgroundStore.organizeByPath.values.reduce(0) { $0 + ($1.memberPaths.isEmpty ? 0 : 1) }

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
                contentPrereadEnabled: backgroundStore.contentPrereadEnabled,
                contentSummaryCount: records.reduce(0) { $0 + ($1.contentSummary != nil ? 1 : 0) },
                summaryCount: summaryCount,
                openWithCount: countAction("openWith"),
                urlOpenCount: countAction("urlOpen"),
                installCount: countAction("dragToApplications"),
                activityCount: countAction("openTask"),
                archiveEntryCount: countAction("revealArchiveEntry"),
                archiveKindCount: countAction("archiveKind"),
                folderGroupCount: backgroundStore.folderGroupsByPath.values.reduce(0) { $0 + $1.count },
                organizeCount: organizeCount,
                // 主动工具 token(归档主动建议 + 文件压缩/哈希等)—— 之前没计数,看不出「到底有没有冒出来」。
                hashCount: countAction("hash"),
                testCount: countAction("test"),
                inspectCount: countAction("inspect"),
                securityCount: countAction("security"),
                compressCount: countAction("compress"),
                convertCount: countAction("convert"),
                inlineResultCount: records.reduce(0) { $0 + (($1.contentSummary?.inlineResults.contains { !$0.value.isEmpty } ?? false) ? 1 : 0) },
                workbenchChipRankingCount: backgroundStore.workbenchChipRankingByCategory.values.reduce(0) { $0 + $1.orderedIDs.count },
                workbenchNeedsAttentionCount: backgroundStore.workbenchNeedsAttentionByCategory.count,
                workbenchFailureExplanationCount: backgroundStore.workbenchFailureExplanationByTask.count,
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
            activityTasks: DevToolsAIDataSnapshot.ActivityTasks(
                active: TaskCenter.shared.active.count,
                history: TaskCenter.shared.history.count,
                workbench: workbench
            )
        )
    }

    /// AI 建议明细全量复制(隐藏调试区,中文硬编码):门控 / 预算 / 各管线诊断 + **每个计数类别的完整文件清单**。
    /// 直接回答「这个类别到底命中了哪些文件 / 为什么是 0」—— 在主 actor 上从索引现读现拼(用户点一下才跑,几毫秒)。
    private func copyAISuggestionDetail() {
        Task { @MainActor in
            let text = buildAISuggestionDetailReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash("已复制 AI 建议明细(全分类)")
        }
    }

    @MainActor
    private func buildAISuggestionDetailReport() -> String {
        let store = AIBackgroundIndexStore.shared
        let indexer = AIBackgroundIndexer.shared
        let records = store.fileIndex.records
        let g = indexer.gateDiag()
        let pc = AIPendingCheckStore.shared.counts
        func rel(_ d: Date?) -> String {
            guard let d else { return "从未" }
            let s = Int(Date().timeIntervalSince(d))
            return s < 60 ? "\(s)秒前" : (s < 3_600 ? "\(s / 60)分前" : "\(s / 3_600)时前")
        }
        func yn(_ b: Bool) -> String { b ? "✓" : "✗" }
        func display(_ r: AIFileMemoryRecord) -> String { r.path ?? r.fileName }
        func has(_ token: String, _ r: AIFileMemoryRecord) -> Bool {
            r.contentSummary?.suggestedActions.contains { $0.token == token } ?? false
        }
        func pipelineProductCounts() -> AIDevToolsPipelineProductCounts {
            AIDevToolsPipelineProductCounts(
                summary: records.reduce(0) { $0 + (($1.contentSummary?.shortSummary?.isEmpty == false) ? 1 : 0) },
                openWith: records.reduce(0) { $0 + (has("openWith", $1) ? 1 : 0) },
                urlOpen: records.reduce(0) { $0 + (has("urlOpen", $1) ? 1 : 0) },
                install: records.reduce(0) { $0 + (has("dragToApplications", $1) ? 1 : 0) },
                activity: records.reduce(0) { $0 + (has("openTask", $1) ? 1 : 0) },
                archiveEntry: records.reduce(0) { $0 + (has("revealArchiveEntry", $1) ? 1 : 0) },
                archiveKind: records.reduce(0) { $0 + (has("archiveKind", $1) ? 1 : 0) },
                folderGroup: store.folderGroupsByPath.values.reduce(0) { $0 + $1.count },
                organize: store.organizeByPath.values.reduce(0) { $0 + ($1.memberPaths.isEmpty ? 0 : 1) },
                inspect: records.reduce(0) { $0 + (has("inspect", $1) ? 1 : 0) },
                test: records.reduce(0) { $0 + (has("test", $1) ? 1 : 0) },
                hash: records.reduce(0) { $0 + (has("hash", $1) ? 1 : 0) },
                security: records.reduce(0) { $0 + (has("security", $1) ? 1 : 0) },
                compress: records.reduce(0) { $0 + (has("compress", $1) ? 1 : 0) },
                convert: records.reduce(0) { $0 + (has("convert", $1) ? 1 : 0) },
                inlineResult: records.reduce(0) { $0 + (($1.contentSummary?.inlineResults.contains { !$0.value.isEmpty } ?? false) ? 1 : 0) },
                workbenchChipRanking: store.workbenchChipRankingByCategory.values.reduce(0) { $0 + $1.orderedIDs.count },
                workbenchNeedsAttention: store.workbenchNeedsAttentionByCategory.count,
                workbenchFailureExplanation: store.workbenchFailureExplanationByTask.count)
        }

        var out: [String] = []
        out.append("# AI 建议明细  生成于 \(Date())")

        out.append("\n## 门控 / 预算 / 索引")
        out.append("在跑\(yn(indexer.isIndexerRunning)) 心跳\(yn(indexer.isHeartbeatRunning)) 上轮\(rel(indexer.lastFullRunAt))")
        out.append("确定性\(yn(g.canDeterministic)) 模型\(yn(g.canModelWork)) 深档\(yn(g.canDeepContext))")
        out.append("活跃\(g.appIsActive ? "是" : "否") 距交互\(g.devToolsExempt ? "豁免" : "\(g.secondsSinceLastInteraction)s") 充电\(g.isCharging.map { $0 ? "是" : "否" } ?? "无电池")"
            + " 低电\(g.lowBattery ? "是" : "否") 省电\(g.powerSaverMode ? "是" : "否") 档\(g.activityLevel) 模型\(g.modelAvailable ? "就绪" : "无")")
        if let b = store.budget {
            out.append("预算: 目录/轮\(b.maxDirectoriesPerRound) 归档/轮\(b.maxArchivesPerRound) 模型建议/轮\(b.maxModelSuggestionsPerRound) 单包条目上限\(b.maxEntriesPerArchive)")
        }
        out.append("索引文件 \(records.count) · 有内容摘要 \(records.lazy.filter { $0.contentSummary != nil }.count) · 预读\(store.contentPrereadEnabled ? "开" : "关")")
        out.append("自动检查队列: 待\(pc.pending) 完\(pc.done)")

        out.append("\n## 各管线诊断(候选 / 产物 / 跳过原因)")
        let diag = indexer.passDiag
        for row in AIDevToolsPipelineCatalog.rows(for: pipelineProductCounts()) {
            if let passName = row.passName, let d = diag[passName] {
                if row.name == passName {
                    out.append("\(row.name): 候选\(d.candidates) 缓存产物\(row.cachedProductCount)\(d.skip.map { " · " + $0 } ?? "") · \(rel(d.lastRunAt))")
                } else {
                    out.append("\(row.name): 缓存产物\(row.cachedProductCount) · 共用\(passName)候选\(d.candidates)\(d.skip.map { " · " + $0 } ?? "") · \(rel(d.lastRunAt))")
                }
            } else {
                let sharedPass = row.passName.flatMap { $0 == row.name ? nil : $0 }
                let shared = sharedPass.map { " · 共用\($0)管线" } ?? ""
                out.append("\(row.name): 缓存产物\(row.cachedProductCount)\(shared) · 本会话没跑(门控未过,见上)")
            }
        }

        // 每个计数类别 → 命中文件完整清单(每类封顶 500 行,够 debug,防剪贴板爆)。
        out.append("\n## 建议产物明细(按类,每行 = 一个真实文件)")
        func section(_ title: String, _ hits: [AIFileMemoryRecord], line: (AIFileMemoryRecord) -> String) {
            out.append("\n### \(title) (\(hits.count))")
            if hits.isEmpty { out.append("（无）"); return }
            for r in hits.prefix(500) { out.append(line(r)) }
            if hits.count > 500 { out.append("…还有 \(hits.count - 500) 条(已截断)") }
        }
        func actionsText(_ r: AIFileMemoryRecord) -> String {
            (r.contentSummary?.suggestedActions ?? []).map { $0.token + ($0.payload.map { "(\($0))" } ?? "") }.joined(separator: ",")
        }

        section("摘要 [shortSummary]", records.filter { $0.contentSummary?.shortSummary?.isEmpty == false }) {
            "\($0.path ?? $0.fileName) · \"\($0.contentSummary?.shortSummary ?? "")\""
        }
        for (title, token) in [("打开方式", "openWith"), ("网页", "urlOpen"), ("装App", "dragToApplications"),
                               ("活动", "openTask"), ("包内", "revealArchiveEntry"), ("包定性", "archiveKind"),
                               ("检测", "inspect"), ("测试", "test"), ("哈希", "hash"), ("安全", "security"),
                               ("压缩", "compress"), ("转换", "convert")] {
            section("\(title) [\(token)]", records.filter { has(token, $0) }) {
                "\(display($0)) · [\(actionsText($0))]\($0.contentSummary?.shortSummary.map { " · \"\($0)\"" } ?? "")"
            }
        }

        // 文件夹组建议(独立缓存,不在 suggestedActions 里)。
        let groupEntries = store.folderGroupsByPath.flatMap { folder, groups in
            groups.map { "\(folder) → [\($0.actionToken)] \($0.title ?? "(无题)") · \($0.memberPaths.count)项" }
        }
        out.append("\n### 文件组 [folderGroupsByPath] (\(groupEntries.count))")
        if groupEntries.isEmpty { out.append("（无）") } else { out.append(contentsOf: groupEntries.prefix(500)) }

        // Task 7 整理建议(独立缓存;空成员 = 已评估无建议哨兵)。
        let organizeEntries = store.organizeByPath.compactMap { folder, group -> String? in
            group.memberPaths.isEmpty ? nil : "\(folder) → 『\(group.title ?? "(无题)")』 · \(group.memberPaths.count)项"
        }
        let organizeEvaluated = store.organizeByPath.count
        out.append("\n### 整理 [organizeByPath] (有建议 \(organizeEntries.count) / 已评估 \(organizeEvaluated))")
        if organizeEntries.isEmpty { out.append("（无）") } else { out.append(contentsOf: organizeEntries.prefix(500)) }

        // 内联结果(pending 执行完写回的 hash/test/security/inspect 白话)。
        var inlineLines: [String] = []
        for r in records {
            guard let ir = r.contentSummary?.inlineResults, !ir.isEmpty else { continue }
            for (k, v) in ir.sorted(by: { $0.key < $1.key }) { inlineLines.append("\(display(r)) · \(k): \(v)") }
        }
        out.append("\n### 内联结果 [inlineResults] (\(inlineLines.count))")
        out.append(contentsOf: inlineLines.isEmpty ? ["（无）"] : Array(inlineLines.prefix(500)))

        return out.joined(separator: "\n")
    }

    private func copyAIIndexData() {
        Task { @MainActor in
            do {
                let snapshot = makeAIIndexDataSnapshot()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                guard let text = String(data: data, encoding: .utf8) else {
                    flash(L10n.format("devtools.feedback.aiIndexDataFailed", "UTF-8"))
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flash(L10n.text("devtools.feedback.aiIndexDataCopied"))
            } catch {
                flash(L10n.format("devtools.feedback.aiIndexDataFailed", error.localizedDescription))
            }
        }
    }

    /// Spotlight 捐献快照复制(隐藏调试区)。各域计数走后台(读多个 store 的 JSON),回主 actor 设剪贴板。
    /// 注明 AI 建议 / AI 文件索引**不在 Spotlight**(私有派生数据,在「复制 AI 索引数据」里)—— 直接回答「有没有进索引」。
    private func copySpotlightData() {
        Task { @MainActor in
            guard #available(macOS 15.0, *) else {
                flash("需要 macOS 15 才能导出 Spotlight 数据集")
                return
            }
            // 全量 dump:每一条会捐献的 item(与索引同源,含完整真实标识 / 标题 / 关键字)。隐藏调试区,无需脱敏。
            let items = SpotlightReindex.dumpAllItems()
            let countsByDomain = Dictionary(grouping: items, by: { $0.domainLabel }).mapValues(\.count)
            let dump = DevToolsSpotlightDump(
                generatedAt: Date(),
                total: items.count,
                countsByDomain: countsByDomain,
                note: "每条 = 一个会捐献给 Spotlight 的 CSSearchableItem(uniqueIdentifier 是 SpotlightRoute,点击可解回)。"
                    + "AI 建议 / AI 文件索引不在此列,属私有派生数据,见「复制 AI 索引数据」。",
                items: items
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(dump), let text = String(data: data, encoding: .utf8) else {
                flash("复制 Spotlight 索引失败")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash("已复制 Spotlight 数据集(\(items.count) 条)")
        }
    }

    private func makeAIIndexDataSnapshot() -> DevToolsAIIndexDataSnapshot {
        let store = AIBackgroundIndexStore.shared
        return DevToolsAIIndexDataSnapshot(
            generatedAt: Date(),
            backgroundEnabled: store.backgroundEnabled,
            folderPreindexEnabled: store.folderPreindexEnabled,
            archivePrefetchEnabled: store.archivePrefetchEnabled,
            activityLevel: AppPreferences.aiBackgroundActivityLevel.rawValue,
            scopes: store.scopes.map(DevToolsAIIndexDataSnapshot.Scope.init),
            fileIndex: store.fileIndex
        )
    }

    private func flash(_ text: String) {
        withAnimation { actionFeedback = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { actionFeedback = nil }
        }
    }
}

private nonisolated struct DevToolsArchiveCacheProbe {
    let entries: [ArchiveListingCacheEntry]
    let memory: DevToolsAIDataSnapshot.ArchiveMemory
}

/// 「复制 Spotlight 索引数据」的导出体:总数 + 各域计数 + 说明 + **每条 item 的完整快照**(隐藏调试区)。
private nonisolated struct DevToolsSpotlightDump: Encodable {
    let generatedAt: Date
    let total: Int
    let countsByDomain: [String: Int]
    let note: String
    let items: [SpotlightReindex.IndexedItemDump]
}

private nonisolated struct DevToolsAIDataSnapshot: Encodable {
    nonisolated struct Assistant: Encodable {
        let enabled: Bool
        let ready: Bool
        let unavailableReason: String
    }

    nonisolated struct ArchiveMemory: Encodable {
        let archiveCount: Int
        let storageByteSize: Int
        let nonEncryptedFileEntries: Int
        let truncatedArchives: Int
    }

    nonisolated struct Spotlight: Encodable {
        let releases: Int
        let tasks: Int
        let archives: Int
        let archiveFiles: Int
        let settings: Int
        let total: Int
    }

    nonisolated struct BackgroundIndex: Encodable {
        nonisolated struct Budget: Encodable {
            let maxDirectoriesPerRound: Int
            let maxArchivesPerRound: Int
            let maxEntriesPerArchive: Int
        }

        let backgroundEnabled: Bool
        let folderPreindexEnabled: Bool
        let archivePrefetchEnabled: Bool
        let contentPrereadEnabled: Bool
        let contentSummaryCount: Int
        // AI 建议各 pass 的产物计数(看每个 pass 有没有生效)。
        let summaryCount: Int
        let openWithCount: Int
        let urlOpenCount: Int
        let installCount: Int
        let activityCount: Int
        let archiveEntryCount: Int
        let archiveKindCount: Int
        let folderGroupCount: Int
        let organizeCount: Int
        let hashCount: Int
        let testCount: Int
        let inspectCount: Int
        let securityCount: Int
        let compressCount: Int
        let convertCount: Int
        let inlineResultCount: Int
        let workbenchChipRankingCount: Int
        let workbenchNeedsAttentionCount: Int
        let workbenchFailureExplanationCount: Int
        let activityLevel: String
        let scopeCount: Int
        let indexedFileCount: Int
        let folderProfileCount: Int
        let maxIndexedFiles: Int
        let budget: Budget?

        var pipelineProductCounts: AIDevToolsPipelineProductCounts {
            AIDevToolsPipelineProductCounts(
                summary: summaryCount,
                openWith: openWithCount,
                urlOpen: urlOpenCount,
                install: installCount,
                activity: activityCount,
                archiveEntry: archiveEntryCount,
                archiveKind: archiveKindCount,
                folderGroup: folderGroupCount,
                organize: organizeCount,
                inspect: inspectCount,
                test: testCount,
                hash: hashCount,
                security: securityCount,
                compress: compressCount,
                convert: convertCount,
                inlineResult: inlineResultCount,
                workbenchChipRanking: workbenchChipRankingCount,
                workbenchNeedsAttention: workbenchNeedsAttentionCount,
                workbenchFailureExplanation: workbenchFailureExplanationCount)
        }
    }

    nonisolated struct ActivityTasks: Encodable {
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
    let activityTasks: ActivityTasks
}

private nonisolated struct DevToolsAIIndexDataSnapshot: Encodable {
    nonisolated struct Scope: Encodable {
        let id: UUID
        let directoryName: String
        let directoryPathHash: String
        let origin: String
        let recursive: Bool
        let maxDepth: Int
        let includeExternalVolumes: Bool
        let includeNetworkVolumes: Bool
        let createdAt: Date
        let lastScannedAt: Date?

        init(_ scope: AIArchivePrefetchScope) {
            self.id = scope.id
            self.directoryName = (scope.directoryPath as NSString).lastPathComponent
            self.directoryPathHash = AIStableHash.fnv1a32Hex(scope.directoryPath)
            self.origin = scope.origin.rawValue
            self.recursive = scope.recursive
            self.maxDepth = scope.maxDepth
            self.includeExternalVolumes = scope.includeExternalVolumes
            self.includeNetworkVolumes = scope.includeNetworkVolumes
            self.createdAt = scope.createdAt
            self.lastScannedAt = scope.lastScannedAt
        }
    }

    let schema = "simplezip.devtools.aiIndexData.v1"
    let generatedAt: Date
    let backgroundEnabled: Bool
    let folderPreindexEnabled: Bool
    let archivePrefetchEnabled: Bool
    let activityLevel: String
    let scopes: [Scope]
    let fileIndex: AIFileMemoryIndex
}
