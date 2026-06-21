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
    /// 后台 agent 运行遥测:launchd 拉起 --background-index 的累计次数 / 上次 / 结果(确认后台是否真跑过)。
    @State private var agentRunStatus = "…"
    /// AI 建议各 pass 的产物计数(摘要 / 打开方式 / 装App / 活动 / 包内),让「pass 到底有没有生效」可查。
    @State private var aiSuggestionStatus = "…"
    /// #8 跨表面反馈 / 兴趣信号事件计数(「我不喜欢」/ 点击学兴趣),让软降权学习数据可查。
    @State private var aiFeedbackStatus = "…"
    @State private var aiActivityTasksStatus = "…"
    /// 工具栏习惯统计(建议七):按选择上下文桶记的工具栏 + 右键菜单动作点击次数(验「右键学习有没有进数据」)。
    @State private var toolbarUsageStatus = "…"
    /// 后台是否在跑 + 各档闸实时状态(回答「为啥都是 0」—— 哪一档被卡)。
    @State private var aiGateStatus = "…"
    /// 每个 pass 上次跑的候选数 / 跳过原因(区分「无候选」和「门控没过 / 没跑过」)。
    @State private var aiPassDiagStatus = "…"
    /// agent 探针/查询的**常驻**当前状态(用户明确要别 flash 一闪而过)。最近一次任意 agent 通道调用的结果常驻在此。
    @State private var agentProbeStatus = "未运行 —— 点下面任一 agent 探针/查询按钮试一次。"
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
                        infoRow("bolt.horizontal.circle", "后台 agent 运行(launchd 拉起计数)", agentRunStatus)
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
                        diagRow("slider.horizontal.3", "工具栏习惯(建议七)", toolbarUsageStatus)
                        actionRow(
                            "doc.on.clipboard",
                            L10n.text("devtools.action.copyAIIndexData"),
                            L10n.text("devtools.action.copyAIIndexData.detail")
                        ) {
                            copyAIIndexData()
                        }
                        actionRow(
                            "doc.on.clipboard",
                            "复制工具栏习惯统计",
                            "导出全部「选择上下文桶 → 动作 → 点击次数」(工具栏 + 右键菜单都记)。验证右键选项的点击有没有进习惯数据 —— 单选按后缀分桶(mode|1|ext)、复选统一桶(mode|multi)。"
                        ) {
                            copyToolbarUsageData()
                        }
                        actionRow(
                            "trash",
                            "清空 AI 派生数据",
                            "调用 clearDerivedData():清 AI 索引本体(AIFileMemoryIndex)+ 下游预烘焙缓存(文件组/整理/工作台 chip·解读·失败·聚集)+ 反馈与自动检查队列;不删真实文件、不碰 Spotlight、不删显式「不感兴趣」偏好。"
                        ) {
                            AIBackgroundIndexStore.shared.clearDerivedData()
                            loadAIDataSnapshot()
                            flash("已清空 AI 派生数据")
                        }
                        // 独立 AI 进程改造:两条投递通道各验一次「端上模型能否在非 App 的独立进程里跑」。
                        // ① 后台 LaunchAgent 通道:SMAppService 注册 + 连 Mach XPC;在 Login Items 可见、受「允许在后台」门控。
                        actionRow(
                            "bolt.horizontal.circle",
                            "测试 AI agent 探针(后台 LaunchAgent 通道)",
                            "注册 LaunchAgent(SMAppService)+ 连 Mach XPC,在 agent 进程里试跑一次端上模型,结果显示在下方(也打到 agent stderr,Console 过滤 SimpleZipAIAgent 看完整)。这条通道在 Login Items 可见、受「允许在后台」开关门控:关掉它后台索引连同此探针都会被 launchd 拒。注册可能需 SimpleZip Dev 签名 + App 从 /Applications 跑。"
                        ) {
                            agentProbeStatus = "正在连后台 LaunchAgent 跑探针…(每个 App 启动只首刀重注册,之后直接连)"
                            AIAgentClient.runBackgroundProbe { result in
                                agentProbeStatus = result
                            }
                        }
                        // ② 前台 XPC Service 通道:连内嵌 .xpc(serviceName);App 连接即按需拉起、不进 Login Items、
                        //    不受「允许在后台」门控 —— 验证「即便用户关掉后台权限,前台 AI 仍能起」。
                        actionRow(
                            "bolt.badge.automatic",
                            "测试 AI agent 探针(前台 XPC Service 通道)",
                            "连内嵌 XPC Service(Contents/XPCServices/SimpleZipAIXPCService.xpc),在它里面试跑一次端上模型。这条通道由 App 连接即按需拉起、随 App 生命周期、不进 Login Items、不受「允许在后台」开关 gate —— 即便用户关掉后台权限,前台 AI 也能起。结果显示在下方(stderr 同样过滤 SimpleZipAIAgent)。"
                        ) {
                            agentProbeStatus = "正在连前台 XPC Service 跑探针…"
                            AIAgentClient.runForegroundProbe { result in
                                agentProbeStatus = result
                            }
                        }
                        // ③ 前台 XPC Service 真实查询:经同一通道发**真实**自然语言请求,验证 App→agent 真实生成数据流。
                        actionRow(
                            "text.magnifyingglass",
                            "测试 agent 真实查询(前台 XPC Service)",
                            "经前台 XPC Service 把一句写死的自然语言请求(『我想找个压缩在某处的预算表格』)发给 agent,agent 跑真实结构化生成回搜索关键词,结果显示在下方。比上面的写死探针更进一步:验证 App→agent 的真实查询数据流(『真生成迁 agent』的关键一步)。"
                        ) {
                            agentProbeStatus = "正在经前台 XPC Service 跑真实查询…"
                            AIAgentClient.runForegroundQuery("我想找个压缩在某处的预算表格") { result in
                                agentProbeStatus = result
                            }
                        }
                        // ③b 通用 generate(kind:) 契约自检:对照写死的『真实查询』(只测旧专用 extractArchiveKeyword 方法),
                        //    这条经**迁移后所有 pass 共用的通用 XPC 契约**跑散文(reportText)+ 结构化(archiveFileKeyword)两种代表性 pass。
                        actionRow(
                            "checklist",
                            "自检 XPC pass 引擎(通用 generate 契约 · 散文 + 结构化)",
                            "对照上面写死的『真实查询』(只测旧专用 extractArchiveKeyword 方法),这条经迁移后所有 pass 共用的通用 generate(kind:) 契约跑两种代表性 pass —— reportText(散文,报告解释 AI 的中心 pass)+ archiveFileKeyword(结构化,@Generable 受约束输出)。一键验证『报告 / 文件·归档建议 / NL 查询全部走同一条 XPC 通用通路』,逐 pass 报成功与输出片段。"
                        ) {
                            agentProbeStatus = "正在自检 XPC pass 引擎(通用 generate 契约)…散文 + 结构化两个 pass 串行跑,各需一次端上生成,稍候。"
                            AIAgentClient.runEnginePassSelfTest { result in
                                agentProbeStatus = result
                            }
                        }
                        // ③c 被动监视:查引擎进程自启动以来跑过哪些 pass、多少次、成不成(像其它管线一样的监视器,不碰模型)。
                        actionRow(
                            "chart.bar.doc.horizontal",
                            "查引擎 pass 统计(被动监视 · 跑过哪些 / 多少次 / 成不成)",
                            "经前台 XPC Service 调 passStats(不碰模型、瞬回),列出引擎进程自启动以来每种 pass 的调用次数、成功 / 失败数、最近一次时间与成败。对照上面主动自检,这条是被动观测引擎真实跑过什么 —— 触发几次 AI 功能(失败解释 / 文件建议 / 报告解读…)后来查,看它们是否真走了 XPC 引擎。"
                        ) {
                            agentProbeStatus = "正在查引擎 pass 统计…"
                            AIAgentClient.queryPassStats { result in
                                agentProbeStatus = result
                            }
                        }
                        // ③d 后台调度规划观测(AIBackgroundPlanner,确定性、app 内、不走 XPC):看据当前 runtime + 已收集信号会规划哪些后台 job。
                        actionRow(
                            "list.bullet.indent",
                            "查后台调度规划(AIBackgroundPlanner · 确定性)",
                            "用当前运行时(电源/空闲/活跃度档)+ 已收集的 interaction 信号 + 索引健康,调 AIBackgroundPlanner 规划一组 tier-gated 后台 job(该补什么数据 / 预热哪个 surface,绝不越当前档位天花板)。确定性、瞬回、不碰模型。v1 只观测规划结果,逐 job 执行是后续步骤。"
                        ) {
                            let plan = AIBackgroundIndexer.shared.planBackgroundJobs()
                            if plan.jobs.isEmpty {
                                agentProbeStatus = "后台调度规划:档位天花板 = \(plan.allowedTier.rawValue);当前无 job(数据不足 / 档位不够 —— 触发些 AI 功能积累信号、或在空闲充电时再看)。"
                            } else {
                                var lines = ["后台调度规划:档位天花板 = \(plan.allowedTier.rawValue),\(plan.jobs.count) 个 job(优先级降序):"]
                                for j in plan.jobs {
                                    lines.append("· \(j.kind.rawValue) · p\(j.priority) · [\(j.requiredTier.rawValue)] · \(j.reasonTokens.joined(separator: ", "))")
                                }
                                agentProbeStatus = lines.joined(separator: "\n")
                            }
                        }
                        // ③e 工作区证据缺口观测(AIWorkspaceEvidenceGap,确定性、app 内):看 planner 执行(Phase 1+2a)的**输入** ——
                        //    哪些工作区成员缺哈希 / 小归档没测,这些缺口驱动后台 hash/test 补全 job。
                        actionRow(
                            "checkmark.seal",
                            "查工作区证据缺口(AIWorkspaceEvidenceGap · 确定性)",
                            "读 AIWorkspaceStore.currentEvidenceGaps:遍历各工作区成员、查派生索引里算没算过哈希 / 测没测过完整性,确定性判出「缺证据」缺口(missingHash / missingArchiveHealth)。这是 planner 执行 Phase 1+2a 的输入 —— 后台空闲会据此补哈希 / 补测。瞬回、不碰模型 / 不碰 reload。"
                        ) {
                            let gaps = AIWorkspaceStore.shared.currentEvidenceGaps
                            if gaps.isEmpty {
                                agentProbeStatus = "工作区证据缺口:0 条(所有工作区成员都已算过哈希 + 小归档都已测,或当前无工作区成员 —— 打开 / 索引些归档积累成员后再看)。"
                            } else {
                                let byKind = Dictionary(grouping: gaps, by: { $0.kind.rawValue })
                                var lines = ["工作区证据缺口:\(gaps.count) 条,涉及 \(Set(gaps.map(\.workspaceID)).count) 个工作区:"]
                                for kind in byKind.keys.sorted() {
                                    let group = byKind[kind] ?? []
                                    let refs = group.reduce(0) { $0 + $1.affectedSourceRefs.count }
                                    lines.append("· \(kind):\(group.count) 条 · 共 \(refs) 个成员待补")
                                }
                                agentProbeStatus = lines.joined(separator: "\n")
                            }
                        }
                        // ③f pending 检查队列观测(AIPendingCheckStore):planner 执行链的**下游** —— dispatcher 入队的 hash/test 检查在此排队、插电执行。
                        actionRow(
                            "tray.full",
                            "查 pending 检查队列(AIPendingCheckStore)",
                            "读 AIPendingCheckStore.counts:后台调度 dispatcher(executePlannedJobsIfDue)与模型挑的只读检查都入这条队列,插电时逐条执行(hash/test/inspect/security)→ 写内联结果。看待执行 / 已完成数,验证 planner 执行链下游(gap → plan → 入队 → 执行)真在跑。瞬回、不碰模型。"
                        ) {
                            let c = AIPendingCheckStore.shared.counts
                            if c.pending == 0 && c.done == 0 {
                                agentProbeStatus = "pending 检查队列:空(没有积累的检查 —— 触发 AI 索引、或在空闲充电时让「调度执行」入队后再看)。"
                            } else {
                                agentProbeStatus = "pending 检查队列:待执行 \(c.pending) 条、已完成 \(c.done) 条(插电时按活跃度间隔逐条执行,结果写文件抽屉内联)。"
                            }
                        }
                        // ③g 交互 / 兴趣摘要观测(AIFeedbackStore → 确定性聚合):planner 除证据缺口外的另两个输入 —— 验证 archive-open interest 与跨表面交互信号真收集到没。
                        actionRow(
                            "chart.bar.doc.horizontal",
                            "查交互 / 兴趣摘要(planner 输入)",
                            "读 AIFeedbackStore 折叠出的 interactionCounterSummary(跨表面点击 / 打开信号计数)+ interestSummary(归档打开累积的位置亲和 / 交互亲和)。这是 planner 除证据缺口外的另两个输入 —— 验证 archive-open interest 与交互信号真在收集、喂进后台调度。瞬回、不碰模型 / 不碰 reload。"
                        ) {
                            let ic = AIFeedbackStore.shared.interactionCounterSummary
                            let it = AIFeedbackStore.shared.interestSummary
                            if ic.counters.isEmpty && it.locationAffinities.isEmpty && it.interactionAffinities.isEmpty {
                                agentProbeStatus = "交互 / 兴趣摘要:暂无(还没积累信号 —— 打开些归档 / 点些 AI 建议后再看)。"
                            } else {
                                var lines = ["交互信号:\(ic.counters.count) 类计数"]
                                for c in ic.counters.prefix(4) {
                                    lines.append("· \(c.surface)/\(c.interaction)/\(c.targetKind) × \(c.count)")
                                }
                                lines.append("兴趣摘要:位置亲和 \(it.locationAffinities.count) 类、交互亲和 \(it.interactionAffinities.count) 类、反应偏好 \(it.reactionPreferences.count) 类")
                                for la in it.locationAffinities.prefix(3) {
                                    lines.append("· 位置 \(la.locationKind) 打开 ×\(la.openCount)")
                                }
                                agentProbeStatus = lines.joined(separator: "\n")
                            }
                        }
                        // ④ 配置同步:把当前 App 的 AI 设置推给 agent(坑 9 schemaVersion 协商)。把 AI 主/子开关关掉后点这,
                        //    再点上面的真实查询,应被 agent 红线门控拦截(返回「AI 已禁用」)→ 验证 App→agent 配置同步 + 门控。
                        actionRow(
                            "arrow.triangle.2.circlepath",
                            "同步 AI 配置到 agent",
                            "把当前 App 的 AI 开关(主 / 建议 / 索引 / 预读 + 活跃度档)编码成 payload,经前台 XPC Service 推给 agent;agent 解码存储并回报支持的 schemaVersion。之后 agent 的真实查询会按这份配置门控:AI 主开关或建议开关关掉 → agent 不生成。结果显示在下方状态卡片。"
                        ) {
                            agentProbeStatus = "正在同步 AI 配置到 agent…"
                            AIAgentClient.syncConfiguration(AIAgentClient.currentConfiguration()) { result in
                                agentProbeStatus = result
                            }
                        }
                        // agent 探针/查询/配置同步的**常驻**当前状态(用户明确要:别 flash 一闪而过)。上面几个按钮的最近结果常驻在此、可选中复制。
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(.secondary)
                                Text("agent 探针 · 当前状态")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(agentProbeStatus)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        // AI 建议明细:每个计数类别(摘要/打开方式/网页/.../哈希/压缩/转换/内联结果)的**完整文件清单**
                        // + 门控 / 预算 / 各管线诊断 —— 一次性复制出来逐条 debug「这个类别到底有哪些文件、为啥是 0」。
                        actionRow(
                            "list.bullet.clipboard",
                            "复制 AI 建议明细(全分类 + 每文件 + 管线)",
                            "把上面每个计数展开成完整清单:每类列出命中的真实文件路径 + 短摘要 + 动作 / 内联结果,附门控 / 预算 / 管线诊断。"
                        ) {
                            copyAISuggestionDetail()
                        }
                        // 工作台四 pass(筛选排序 / 需要处理解读 / 失败解释 / 真建议)的完整后台缓存 —— 排查
                        // 「DevTools 说有产物、工作台 UI 却没显示」到底差在哪(指纹不匹配 / category 错位 / 文案空)。
                        actionRow(
                            "rectangle.3.group.bubble",
                            "复制工作台 AI 数据(四 pass 完整缓存)",
                            "导出筛选排序 / 需要处理解读 / 失败解释 / 真建议四个 pass 的完整后台缓存(指纹 + 文案 + chip 命名 + filter),逐条排查为何 UI 没显示。"
                        ) {
                            copyWorkbenchAIDetail()
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

                    // 更新助手测试:独立 section(不塞进「AI 可用数据」box)—— 选单挑卡直接弹更新助手 + 重置已看标记。
                    DialogSection("更新助手测试(调试)") {
                        updateAssistantTestRow()
                        actionRow(
                            "arrow.counterclockwise.circle",
                            "重置更新助手「已看」标记",
                            "清空全部卡的已看 + 迁移标记 —— 下次启动老用户(已完成欢迎助手)会重新收到更新助手。"
                        ) {
                            AppPreferences.resetUpdateCardsSeen()
                            flash("已重置更新助手标记(下次启动生效)")
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

    /// 更新助手测试行:右侧一个**选单**挑「哪张卡」(或全部)直接弹更新助手——不必真升级。
    @ViewBuilder
    private func updateAssistantTestRow() -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("触发更新助手(选卡测试)")
                    .font(.callout.weight(.medium))
                Text("从右侧选单挑一张 / 全部新卡,直接弹更新助手 —— 不必真升级。走完会把所选卡标记已看(再测用下面的重置)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                ForEach(UpdateCard.allCases) { card in
                    Button("「\(card.rawValue)」卡") { triggerUpdateAssistant([card.rawValue]) }
                }
                if UpdateCard.allCases.count > 1 {
                    Divider()
                    Button("全部新卡") { triggerUpdateAssistant(UpdateCard.allCases.map(\.rawValue)) }
                }
            } label: {
                Label("选择卡片", systemImage: "sparkles.rectangle.stack")
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func triggerUpdateAssistant(_ rawValues: [String]) {
        NotificationCenter.default.post(
            name: .devToolsTriggerUpdateAssistant, object: nil, userInfo: ["cards": rawValues])
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
            // 建议七:工具栏习惯统计(工具栏 + 右键菜单点击,按选择上下文桶聚合;验右键学习有没有进数据)。
            toolbarUsageStatus = Self.formatToolbarUsage(ToolbarActionUsageStore.shared.debugAllCounts())
            // 后台 agent 运行遥测:launchd 是否真把 --background-index 拉起过(累计次数 / 上次 / 结果)。
            let tel = AIAgentRunTelemetry.read()
            agentRunStatus = tel.runCount == 0
                ? "从未被拉起(launchd 还没唤醒过后台索引;或静默后台索引未开)"
                : "拉起 \(tel.runCount) 次 · 上次 \(rel(tel.lastWake)) · 结果:\(tel.lastOutcome ?? "—")"
        }
    }

    /// 工具栏习惯统计摘要:总览 + 点击最多的前几个桶(每桶列动作×次数)。
    private static func formatToolbarUsage(_ counts: [String: [String: Int]]) -> String {
        guard !counts.isEmpty else { return "暂无(还没点过工具栏 / 右键的上下文动作)" }
        let total = counts.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let lines = counts
            .sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
            .prefix(8)
            .map { bucket, actions -> String in
                let top = actions.sorted { $0.value > $1.value }
                    .map { "\($0.key)×\($0.value)" }
                    .joined(separator: " ")
                return "\(bucket): \(top)"
            }
        return (["\(counts.count) 桶 · \(total) 次点击"] + lines).joined(separator: "\n")
    }

    private func copyToolbarUsageData() {
        let counts = ToolbarActionUsageStore.shared.debugAllCounts()
        var report = "# 工具栏习惯统计(建议七)\n\n"
        if counts.isEmpty {
            report += "(空 —— 还没记录任何工具栏 / 右键上下文动作)\n"
        } else {
            for (bucket, actions) in counts.sorted(by: { $0.key < $1.key }) {
                report += "## \(bucket)\n"
                for (action, n) in actions.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
                    report += "- \(action): \(n)\n"
                }
                report += "\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        flash("已复制工具栏习惯统计")
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
                workbenchClusterChipsCount: backgroundStore.workbenchClusterChipsByCategory.values.reduce(0) { $0 + $1.chips.count },
                toolbarRankingCount: backgroundStore.toolbarRanking.byFile.count + backgroundStore.toolbarRanking.byType.count,
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

    /// 工作台四 pass 完整缓存复制(隐藏调试区,中文硬编码):筛选排序 / 需要处理解读 / 失败解释 / 真建议的
    /// 后台缓存原文(指纹 + 文案 + chip 命名 + filter)。排查「DevTools 有产物、工作台 UI 没显示」差在哪。
    private func copyWorkbenchAIDetail() {
        Task { @MainActor in
            let store = AIBackgroundIndexStore.shared
            var out: [String] = ["# 工作台 AI 四 pass 缓存  生成于 \(Date())"]
            out.append("\n## 筛选排序(chip ranking,by category)  共 \(store.workbenchChipRankingByCategory.count) 分类")
            for (cat, r) in store.workbenchChipRankingByCategory.sorted(by: { $0.key < $1.key }) {
                out.append("[\(cat)] fp=\(r.fingerprint)\n  ordered=\(r.orderedIDs.joined(separator: ", "))")
            }
            out.append("\n## 需要处理解读(by category)  共 \(store.workbenchNeedsAttentionByCategory.count) 分类")
            for (cat, e) in store.workbenchNeedsAttentionByCategory.sorted(by: { $0.key < $1.key }) {
                out.append("[\(cat)] fp=\(e.fingerprint)\n  \(e.text)")
            }
            out.append("\n## 失败解释(by task id)  共 \(store.workbenchFailureExplanationByTask.count) 条")
            for (id, e) in store.workbenchFailureExplanationByTask.sorted(by: { $0.key < $1.key }) {
                out.append("[\(id)] fp=\(e.fingerprint)\n  \(e.text)")
            }
            out.append("\n## 真建议(cluster chips,by category)  共 \(store.workbenchClusterChipsByCategory.count) 分类")
            for (cat, c) in store.workbenchClusterChipsByCategory.sorted(by: { $0.key < $1.key }) {
                out.append("[\(cat)] fp=\(c.fingerprint)  \(c.chips.count) chip")
                for chip in c.chips {
                    out.append("  · \(chip.displayName) [matches=\(chip.matchCount)] \(String(describing: chip.filter))")
                }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out.joined(separator: "\n"), forType: .string)
            flash("已复制工作台 AI 四 pass 缓存")
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
                workbenchFailureExplanation: store.workbenchFailureExplanationByTask.count,
                workbenchClusterChips: store.workbenchClusterChipsByCategory.values.reduce(0) { $0 + $1.chips.count },
                toolbarRanking: store.toolbarRanking.byFile.count + store.toolbarRanking.byType.count)
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

        // 工具栏动作 AI 排序(建议七 Phase2):文件级 + 类型级烘焙的有序动作 id —— debug 工具栏推荐看这。
        let tb = store.toolbarRanking
        out.append("\n### 工具栏序 [toolbarRanking] (文件级 \(tb.byFile.count) · 类型级 \(tb.byType.count))")
        if tb.byFile.isEmpty && tb.byType.isEmpty {
            out.append("（无）")
        } else {
            for (path, ids) in tb.byFile.sorted(by: { $0.key < $1.key }).prefix(500) {
                out.append("文件 \(path) → \(ids.joined(separator: " > "))")
            }
            for (ext, ids) in tb.byType.sorted(by: { $0.key < $1.key }) {
                out.append("类型 .\(ext) → \(ids.joined(separator: " > "))")
            }
        }

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
        let workbenchClusterChipsCount: Int
        let toolbarRankingCount: Int
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
                workbenchFailureExplanation: workbenchFailureExplanationCount,
                workbenchClusterChips: workbenchClusterChipsCount)
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
