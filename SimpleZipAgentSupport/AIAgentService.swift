//
//  AIAgentService.swift
//  SimpleZipAgentSupport(由 SimpleZipAIAgent + SimpleZipAIXPCService 两个 target 共同编译)
//
//  独立 AI 进程改造 · 阶段1 · agent 生成引擎的「进程无关」核心。
//  从 AIAgentMain.swift 抽出 —— 因为现在有**两条投递通道**共用同一套生成逻辑:
//    ① LaunchAgent(SMAppService,后台,Login Items 可见、受「允许后台」门控)—— 入口 AIAgentMain.swift。
//    ② 内嵌 XPC Service(Contents/XPCServices/,前台按需,App 连接即拉起、随 App 活、不在 Login Items、
//       不受「允许后台」门控)—— 入口 AIXPCServiceMain.swift。
//  为什么要两条:实测「Login Items → 允许在后台」开关其实是 BTM 对 LaunchAgent 的 disposition,关掉后
//  launchd 拒绝它**一切**启动(连前台 on-demand 唤醒也拒)→ 前台 AI 也起不来。XPC Service 由 App 私有持有、
//  不进 Login Items、不受该开关 gate,正是前台按需推理的稳妥通道;LaunchAgent 仍负责 App 关闭后的后台索引。
//
//  两个入口各自搭自己的 listener,但 exportedObject、全局串行闸、@Generable 结构化生成全用本文件这一份 ——
//  保证「不管从哪条通道进来,都过同一个全局串行闸」。端上模型是共享资源,重叠的 respond() 会让框架迭代
//  session transcript 时越界 trap;正常情况下 App 开 → XPC Service 活 / App 关 → LaunchAgent 活,两进程
//  不同时跑,模型也不会双载。本文件**没有 @main、没有 listener 搭建** —— 那是各通道入口文件各自的职责。
//
//  红线不变:agent 只产出受约束字段供 App 确定性应用,绝不执行删除 / 放行 / 修复。
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// agent 进程内持有 App 同步来的 AIAgentConfiguration。前台/后台生成据此门控(红线:主开关关 = 不生成)。
/// actor 保证跨连接并发安全(LaunchAgent / XPC Service 两通道都可能写)。
actor AIAgentConfigurationStore {
    static let shared = AIAgentConfigurationStore()
    private var current: AIAgentConfiguration?

    init() {
        // 进程启动即从持久化文件读 App 上次写的配置 —— App 关着时被 launchd 拉起的后台 agent 也能拿到红线主开关状态。
        current = AIAgentConfiguration.loadPersisted()
    }

    func apply(_ config: AIAgentConfiguration) { current = config }
    var snapshot: AIAgentConfiguration? { current }

    /// 前台 AI 是否放行。**未收到配置前默认放行**(向后兼容 --probe / --query 命令行自检 —— 那时 App 没同步过);
    /// 只有 App 明确同步了「主 / 子开关关」才拦截。
    var foregroundAllowed: Bool { current?.foregroundAIAllowed ?? true }
}

/// 接受连接、把接口 / 实现挂上去。两条通道(LaunchAgent / XPC Service)的 listener delegate 共用这一个。
/// Step 0 不做对端校验(后续接 SMAppService / XPC Service 互信时再加
/// `xpc_connection_set_peer_code_signing_requirement` 同签名身份校验)。
final class AIAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.exportedObject = AIAgentService()
        conn.resume()
        return true
    }
}

/// XPC 服务实现。Step 0 只有探针。两条通道共用同一份实现 → 同一个全局串行闸。
final class AIAgentService: NSObject, SimpleZipAIAgentXPC {
    /// 轻量存活探测:进程被拉起 + 连接建立即立刻回 true,**绝不碰模型**(给运行状态健康检查做连通性,瞬回不卡)。
    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    /// 端上模型可用性(给主 app 缓存 isReady/unavailableReason —— 主二进制不再 import FoundationModels)。
    /// 只读 `SystemLanguageModel.availability`(**非推理、瞬回**),回 `(available, reasonCode)`;App 据 code 映 L10n。
    func modelAvailability(reply: @escaping (Bool, String) -> Void) {
        guard #available(macOS 26.0, *) else { reply(false, "osTooOld"); return }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            reply(true, "")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: reply(false, "deviceNotEligible")
            case .appleIntelligenceNotEnabled: reply(false, "notEnabled")
            default: reply(false, "modelNotReady")
            }
        }
        #else
        reply(false, "modelNotReady")
        #endif
    }

    func probeModel(reply: @escaping (String) -> Void) {
        Task {
            let result = await AIAgentService.probeText()
            agentLog("probeModel → \(result)")
            reply(result)
        }
    }

    func extractArchiveKeyword(fromRequest request: String, reply: @escaping (String) -> Void) {
        Task {
            let result = await AIAgentService.queryText(request)
            agentLog("extractArchiveKeyword(\(request)) → \(result)")
            reply(result)
        }
    }

    func syncConfiguration(_ payload: Data, reply: @escaping (Int) -> Void) {
        Task {
            guard let config = AIAgentConfiguration.decoded(from: payload) else {
                agentLog("syncConfiguration: 解码失败(payload \(payload.count) bytes)→ 拒绝")
                reply(-1)
                return
            }
            await AIAgentConfigurationStore.shared.apply(config)
            agentLog("syncConfiguration: schemaVer=\(config.schemaVersion) aiMain=\(config.aiAssistantEnabled) sug=\(config.aiSuggestionEnabled) idx=\(config.indexingEnabled) → applied")
            reply(AIAgentConfiguration.currentSchemaVersion)
        }
    }

    func generate(kind: String, inputJSON: Data, languageName: String, reply: @escaping (Data, Bool) -> Void) {
        Task {
            func fail(_ message: String) { reply(Data(message.utf8), false) }
            guard #available(macOS 26.0, *) else { fail("macOS < 26 — FoundationModels 不可用。"); return }
            // 红线:App 同步过「主/子开关关」则拒绝一切前台生成(前台也不豁免);未同步过默认放行(命令行自检兼容)。
            guard await AIAgentConfigurationStore.shared.foregroundAllowed else {
                fail("AI 已禁用(主开关 / 建议开关关闭)—— agent 按配置不生成。")
                return
            }
            #if canImport(FoundationModels)
            do {
                let output = try await AIPassEngine.run(kind: kind, inputJSON: inputJSON, languageName: languageName)
                await AIPassStatsRecorder.shared.record(kind: kind, ok: true)
                agentLog("generate(\(kind)) → \(output.count) bytes")
                reply(output, true)
            } catch {
                await AIPassStatsRecorder.shared.record(kind: kind, ok: false)
                agentLog("generate(\(kind)) FAILED: \(error)")
                fail("生成失败(\(kind)): \(error)")
            }
            #else
            fail("agent target 无法 import FoundationModels(SDK 不含)。")
            #endif
        }
    }

    /// DevTools 监视:回引擎进程自启动以来每个 pass kind 的调用统计([AIPassStatEntry] 的 JSON)。不碰模型、瞬回。
    func passStats(reply: @escaping (Data) -> Void) {
        #if canImport(FoundationModels)
        Task {
            let entries = await AIPassStatsRecorder.shared.snapshot()
            reply((try? JSONEncoder().encode(entries)) ?? Data())
        }
        #else
        reply(Data())
        #endif
    }

    /// 在本(独立)进程跑一次端上模型最小生成,回人话结果。`--probe` 与 XPC `probeModel` 共用。
    static func probeText() async -> String {
        guard #available(macOS 26.0, *) else {
            return "macOS < 26 — 本进程 OS 版本不够,FoundationModels 不可用。"
        }
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            // 1. 自由文本最小生成 —— 地基那一问:模型能否在这个非 App 的独立进程里跑(Step 0 已验证)。
            let freeform: String
            do {
                let session = LanguageModelSession(
                    instructions: "You are a terse echo. Reply with exactly one short word.")
                freeform = try await session.respond(to: "Say: ready").content
            } catch {
                return "FAILURE — 自由文本 session.respond 在 agent 进程抛错: \(error)"
            }
            // 2. **结构化 @Generable 生成** —— 真正的重路径:过 agent 自有串行闸 + 受约束字段输出 + 重试,
            //    复刻 App 端 AIReportAssistant.generateStructured 的形态。证实「带 schema 的结构化生成」也能在
            //    agent 进程跑(不只是自由文本),这是把真实生成 pass 迁进 agent 前的关键 de-risk。
            let structured = await AgentGeneration.structuredProbe()
            return "SUCCESS — 模型在 agent(独立)进程跑通。自由文本样本: \(freeform);\(structured)"
        case .unavailable(let reason):
            return "模型在 agent 进程不可用 — reason: \(reason)"
        }
        #else
        return "agent target 无法 import FoundationModels(SDK 不含)。"
        #endif
    }

    /// 参数化真实生成的人话封装(命令行 `--query` 与将来 XPC 转发都可调)。总是存在,内部按 OS/SDK 守卫。
    /// 与写死的 `probeText` 不同,它处理**任意传入请求** —— agent 真实生成能力的最小可调用面。
    static func queryText(_ request: String) async -> String {
        guard #available(macOS 26.0, *) else {
            return "macOS < 26 — FoundationModels 不可用。"
        }
        // 红线:App 若已同步「AI 主 / 子开关关」则 agent 不生成(前台也不豁免)。未同步过默认放行(命令行自检场景)。
        guard await AIAgentConfigurationStore.shared.foregroundAllowed else {
            return "AI 已禁用(主开关 / 建议开关关闭)—— agent 按配置不生成。"
        }
        #if canImport(FoundationModels)
        do {
            return try await AgentGeneration.extractArchiveKeyword(from: request)
        } catch {
            return "QUERY FAILED: \(error)"
        }
        #else
        return "agent target 无法 import FoundationModels(SDK 不含)。"
        #endif
    }
}

/// agent 日志统一打到 stderr(终端 / launchd 都可见)。
func agentLog(_ message: String) {
    FileHandle.standardError.write(Data(("[SimpleZipAIAgent] " + message + "\n").utf8))
}

// MARK: - agent 自有生成引擎(Step 1 第一片:串行闸 + 结构化生成)
//
// 把 App 端 AIReportAssistant 的两块核心**原样**搬进 agent 进程,作为「生成迁 agent」的地基:
//   ① 全局串行闸:on-device 模型是共享资源,重叠的 respond() 会让框架迭代 session transcript 时越界 trap;
//      所有生成排成一条**绝不重叠**的链(unstructured Task 承载,不随调用方取消而中途拆毁 —— 中途拆毁正是崩因)。
//   ② 结构化生成 + 重试:@Generable 受约束输出偶发不符 schema 抛错,同一槽内换新 session 连试几代,全败才抛。
// Step 0 的探针只跑自由文本;这一片让 agent 也能跑**结构化** @Generable 生成 —— 迁真实生成 pass 前的关键验证,
// 用已证实的 `--probe` 直跑通道即可验(不依赖尚未确认的 XPC 通道)。红线不变:agent 只产出受约束字段供 App
// 确定性应用,绝不执行删除 / 放行 / 修复。

#if canImport(FoundationModels)
/// 引擎 pass 调用统计记录器(DevTools 监视用)。只在引擎进程(agent/XPC)活,记每个 pass kind 的 总数/成功/失败/
/// 最近时间·成败。actor 保证并发安全(多连接可能并发调 generate)。不碰模型、无版本门控。
actor AIPassStatsRecorder {
    static let shared = AIPassStatsRecorder()
    private struct Entry { var total = 0; var ok = 0; var failed = 0; var lastAt: Date?; var lastOk: Bool? }
    private var stats: [String: Entry] = [:]
    func record(kind: String, ok: Bool) {
        var e = stats[kind] ?? Entry()
        e.total += 1
        if ok { e.ok += 1 } else { e.failed += 1 }
        e.lastAt = Date()
        e.lastOk = ok
        stats[kind] = e
    }
    func snapshot() -> [AIPassStatEntry] {
        stats.map {
            AIPassStatEntry(kind: $0.key, total: $0.value.total, ok: $0.value.ok, failed: $0.value.failed,
                            lastEpochSeconds: $0.value.lastAt?.timeIntervalSince1970, lastOk: $0.value.lastOk)
        }.sorted { $0.total > $1.total }
    }
}

@available(macOS 26.0, *)
actor AgentGenerationSerializer {
    static let shared = AgentGenerationSerializer()

    /// 链尾:下一个生成要等它结束才开始(只关心「结束」不关心结果类型,抹成 Void)。
    private var tail: Task<Void, Never>?

    /// 把 operation 排到链尾,与其它生成绝不重叠。承载它的 unstructured Task 不继承调用方取消,
    /// 故 respond() 一定跑到底,框架不被中途拆毁。
    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let prior = tail
        let work = Task { () -> Result<T, Error> in
            _ = await prior?.value          // 等上一个生成彻底结束,杜绝重叠
            do { return .success(try await operation()) }
            catch { return .failure(error) }
        }
        tail = Task { _ = await work.value }  // 新链尾(Void 化)
        return try await work.value.get()
    }

    /// 结构化生成薄封装:过串行闸,同一槽内连试 maxAttempts 代(每代换新 session),全败才抛。
    func generateStructured<T: Generable & Sendable>(
        instructions: String, prompt: String, as type: T.Type, maxAttempts: Int = 2
    ) async throws -> T {
        try await run {
            var lastError: Error?
            for _ in 0..<max(1, maxAttempts) {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    return try await session.respond(to: prompt, generating: type).content
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? AgentGenerationError.exhausted
        }
    }

    /// 纯文本生成薄封装:过串行闸,单次 `respond` 跑到底(镜像 App 端 AIReportAssistant.generate 的形态 ——
    /// 绝不套可取消超时:超时取消会丢下没真停的 respond 污染 FoundationModels transcript → 下个串行调用 trap)。
    func generateText(instructions: String, prompt: String) async throws -> String {
        try await run {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
    }
}

enum AgentGenerationError: Error { case exhausted }

/// agent 结构化探针用的最小 @Generable 规格(镜像 App 端 ArchiveFileQuerySpec:单个 String + @Guide)。
@available(macOS 26.0, *)
@Generable
struct AgentProbeSpec: Sendable {
    @Guide(description: "The single most useful file-name keyword to search archives for, extracted from the user's request. A bare word or short phrase, no punctuation, no path.")
    var keyword: String
}

/// 阶段3 结构化 pass 的 @Generable 类型(从 App 端 AIVirtualFolderModelPlanner 搬来,只在 agent+XPC 编 ——
/// FoundationModels 类型不进 app、也不跨 XPC,留引擎内部)。「文件有活动」一句话提醒。
@available(macOS 26.0, *)
@Generable
struct GeneratedActivityReminder: Sendable {
    @Guide(description: "ONE short, natural sentence reminding the owner of the recent action they took on this file and roughly when, so they know it has recent activity and can jump to it. Use ONLY the action and timeframe you were given; never invent extra detail. In the required language.")
    var reminder: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedChipRanking: Sendable {
    @Guide(description: "The chip NUMBERS (the leftmost column of the chip list) in priority order — MOST USEFUL FIRST. Include ONLY the chips genuinely worth showing to the user; drop redundant, near-duplicate or low-value ones. Prefer chips that surface actionable failures the user likely cares about. Use only numbers that appear in the list; never invent one.")
    var orderedNumbers: [String]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedClusterNaming: Sendable {
    @Guide(description: "The clusters worth showing, each as \"<number>: <name>\" — <number> is the cluster's number from the list, <name> is a SHORT, concrete natural-language label a user recognizes (in the UI language), e.g. \"Finder extractions that failed\". Include ONLY clusters genuinely worth showing; drop redundant or low-value ones. Use only numbers from the list; never invent one. At most 6 entries.")
    var labeledClusters: [String]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedArchiveEntryPicks: Sendable {
    @Guide(description: "The item NUMBERS of a FEW files inside this archive the user would most likely want to pull out or preview on their own — ONLY where a file CLEARLY stands out (e.g. a README, the main document, a config, an installer, the one obviously-important file). MOST archives need NONE; an empty list is the correct, common answer. Use only numbers that appear in the list; never invent one.")
    var pickedNumbers: [String]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedArchiveKindGuess: Sendable {
    @Guide(description: "ONE short, concrete sentence describing what kind of archive this appears to be, based only on the listed paths and folder structure. Use the required language. Do not name or copy a specific product unless it is explicitly present in the archive name or entries.")
    var summary: String
    @Guide(description: "A FEW action tokens worth proactively suggesting for THIS archive, or empty. Allowed tokens only: 'test', 'security', 'inspect', 'hash', 'convert'. test and security are safe read-only checks for ANY archive; inspect and hash are for release packages / distributables; convert only when the format is clearly suboptimal. Use each token verbatim; never invent one.")
    var actions: [String]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedURLSuggestion: Sendable {
    @Guide(description: "The NUMBER of the one URL that is genuinely worth showing as an 'open webpage' suggestion for this file. Use 0 when none is clearly useful. Choose only from the numbered URL list; never invent, rewrite, or output a URL.")
    var urlNumber: Int
}

@available(macOS 26.0, *)
@Generable
struct GeneratedDiskImageSuggestion: Sendable {
    @Guide(description: "ONE short, concrete sentence telling the owner what this disk image is: that it is the installer for the app(s) given to you, to be dragged into Applications to install. Use the app name(s) you were given; never invent or assume an app name. In the required language.")
    var summary: String
    @Guide(description: "True if you should actively suggest the user install the app from this disk image (drag it into Applications). For a normal app-installer disk image this is usually true; false only if it clearly is not something to install.")
    var suggestInstall: Bool
}

@available(macOS 26.0, *)
@Generable
struct GeneratedFileSuggestion: Sendable {
    @Guide(description: "ONE short, concrete sentence saying what THIS specific file actually is or is about — its real subject or purpose, the way the owner would describe it. Be specific to the content; do NOT just restate the file name, and do NOT write a generic line like 'a text document'. In the required language.")
    var summary: String
    @Guide(description: "A FEW action tokens from the allowed-actions list, ONLY where an action is clearly the right next step for THIS file (e.g. a finished deliverable someone would share can warrant 'hash'; a large document to send can warrant 'compress'). Empty is correct when nothing clearly fits. Use each token verbatim; never invent one.")
    var actions: [String]
    @Guide(description: "If a list of alternative apps is given, the NUMBER of the ONE app that is CLEARLY a better fit for THIS file than the system default (e.g. a code editor for source/config/logs, a spreadsheet app for CSV/TSV data, a dedicated viewer). Use 0 when no list is given, or when no listed app is clearly better — 0 is the correct default for most files.")
    var openWithAppNumber: Int
}

/// 阶段3 workspace pass 的 @Generable(从 App 端 AIVirtualFolderModelPlanner 搬来,只在 agent+XPC 编)。
/// 动态核查产出:明显不扣题、该从文件夹移除的条目序号(保守 —— 拿不准就不列)。扁平单字段,可靠。
@available(macOS 26.0, *)
@Generable
struct GeneratedVerification: Sendable {
    @Guide(description: "The item NUMBERS that CLEARLY do not belong to this folder's theme and should be removed. Only include items you are confident don't fit; when in doubt, leave it OUT of this list (keep it). Empty is fine — most items usually fit.")
    var removeNumbers: [String]
}

/// 模型给单个条目挑的一条 AI 建议(扁平 2 字段,避嵌套数组拖垮可靠性)。
@available(macOS 26.0, *)
@Generable
struct GeneratedNodeSuggestion: Sendable {
    @Guide(description: "The item NUMBER (the leftmost column of the items list) this suggestion is for.")
    var targetID: String
    @Guide(description: "ONE action token from the allowed-actions list (e.g. hash, compress, test, inspect, convert). Use a token whose 'applies to' kinds include this item's kind.")
    var action: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedSuggestionSet: Sendable {
    @Guide(description: "A FEW per-item action suggestions — only where there is a clear, specific reason for that item. Most items get NONE. Empty if nothing stands out.")
    var suggestions: [GeneratedNodeSuggestion]
}

/// 文件浏览器「文件折叠组」的一组(成员序号 + 一个批量动作)。
@available(macOS 26.0, *)
@Generable
struct GeneratedFileGroupSuggestion: Sendable {
    @Guide(description: "The item NUMBERS (leftmost column) of the files that belong in THIS group — files the user would clearly want to apply the SAME batch action to together. At least 2 numbers.")
    var fileNumbers: [String]
    @Guide(description: "ONE action token from the allowed-actions list to apply to the whole group (e.g. compress, hash, test). Use a token whose 'applies to' kinds fit these files.")
    var action: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedFolderGroupSet: Sendable {
    @Guide(description: "A FEW groups of files in this folder that would CLEARLY benefit from the same batch action — ONLY where it is obviously useful. MOST folders need NONE; empty is the correct default. Never force unrelated files into a group.")
    var groups: [GeneratedFileGroupSuggestion]
}

/// 文件夹「整理进新文件夹」建议产出(扁平 3 字段)。
@available(macOS 26.0, *)
@Generable
struct GeneratedOrganizeSuggestion: Sendable {
    @Guide(description: "True ONLY if a CLEAR subset of these files obviously belongs together and tidying just that subset into one new sub-folder would plainly help (e.g. a pile of screenshots, a set of invoices, the photos from one trip). False if the folder is already tidy, the files are unrelated, or any grouping would be arbitrary — most folders should be false. Be strict.")
    var worthOrganizing: Bool
    @Guide(description: "A short, human folder name for the cluster, by what the files ARE or their shared topic (e.g. 'Screenshots', 'Invoices', 'Trip Photos'). 1-3 words, in the required language. No path, no slashes, no meta words like 'folder', 'files', 'AI' or 'group'.")
    var folderName: String
    @Guide(description: "The item NUMBERS (leftmost column) of the files that clearly share the theme and should move into the new folder — at least 3. Use only numbers that appear in the list; never invent one. Include ONLY files that truly fit; leave the rest out.")
    var fileNumbers: [String]
}

/// 模型产出的单个虚拟目录组(扁平一层,可靠性优先 —— 递归 @Generable 易抖)。最简字段(小模型对门控生成单次失败率极高)。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderGroup: Sendable {
    @Guide(description: "A short human folder name for this group, by what the items ARE or their shared topic (e.g. a couple of words like 'source code', 'figures', 'drafts'). No path, no slashes, 1-3 words.")
    var title: String
    @Guide(description: "The item NUMBERS (the leftmost column of the items list, e.g. \"3\", \"7\") that belong in this group. Use only numbers that actually appear in the list; never invent one.")
    var candidateIDs: [String]
    @Guide(description: "True ONLY for the one (at most two) group the user should see expanded first — the most important / most worth their attention right now. Leave the rest false (collapsed). Most groups should be false; never mark everything true.")
    var expandFirst: Bool
}

/// 模型产出的整份虚拟目录 plan。门控只产「值不值得 + 命名 + 分组」三件(嵌套 suggestions 数组会拉高失败率)。
@available(macOS 26.0, *)
@Generable
struct GeneratedAIFolderPlan: Sendable {
    @Guide(description: "True only if these items genuinely form ONE coherent, useful theme that deserves its own folder — a clear shared purpose, project or topic a person would recognize. False if they merely share a generic word, are an unrelated grab-bag, or are too thin to be worth surfacing. Be strict: quality over quantity.")
    var worthSurfacing: Bool
    @Guide(description: "An optional clearer name for the whole folder/workspace. Empty to keep the current title.")
    var workspaceTitle: String
    @Guide(description: "Between 2 and 6 groups organizing the items that truly belong by meaning. Put each kept item in exactly one group; prefer a small number of clear, well-named groups over many tiny ones.")
    var groups: [GeneratedAIFolderGroup]
}

/// #63 归档清单 NL 查询的 @Generable(从 App 端 ArchiveFileQuerySpec 搬来)。
@available(macOS 26.0, *)
@Generable
struct GeneratedArchiveFileQuery: Sendable {
    @Guide(description: "The single most useful file-name keyword to search archives for, extracted from the user's request. A bare word or short phrase, no punctuation, no path. Empty if the request names no file.")
    var keyword: String
}

/// #64 设置 NL 搜索的 @Generable(从 App 端 SettingIntent/SettingsQuerySpec 搬来)。意图枚举 + 命中设置 id。
@available(macOS 26.0, *)
@Generable
enum GeneratedSettingIntent: String, Equatable { case navigate, enable, disable }

@available(macOS 26.0, *)
@Generable
struct GeneratedSettingsQuery: Sendable {
    @Guide(description: "The id of the single best-matching setting from the provided catalog, copied verbatim. Empty string if nothing in the catalog matches the request.")
    var settingID: String
    @Guide(description: "What the user wants done with that setting: navigate to find it, enable it, or disable it. Use navigate unless the user clearly asks to turn it on or off.")
    var intent: GeneratedSettingIntent
}

@available(macOS 26.0, *)
enum AgentGeneration {
    /// 参数化**真实**结构化生成:把用户自然语言请求 → 归档搜索关键词(镜像 App 端 ArchiveFileQuerySpec 的用途)。
    /// 接受**任意传入请求**(非写死),是「真生成迁 agent」的能力基础 —— 命令行 `--query` 与将来 XPC 转发都走它。
    static func extractArchiveKeyword(from request: String) async throws -> String {
        let spec = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: """
            The user is looking for a file they remember is inside some archive. Extract the single most \
            useful file-name keyword to search for. Return just the keyword, no punctuation or path.
            """,
            prompt: request,
            as: AgentProbeSpec.self)
        return spec.keyword
    }

    /// 在 agent 进程跑一次**结构化** @Generable 生成(过串行闸 + 重试),回人话结果片段。复用 extractArchiveKeyword
    /// 的真实路径、只是喂一个写死样本请求 —— `--probe` 地基自检用。
    static func structuredProbe() async -> String {
        do {
            let keyword = try await extractArchiveKeyword(from: "I think my budget spreadsheet is zipped up somewhere")
            return "结构化生成 OK,keyword=\"\(keyword)\""
        } catch {
            return "结构化生成失败: \(error)"
        }
    }
}

/// 阶段3:**AI pass 引擎**(只编进 agent+XPC,不进 app)。每个 pass 把「拼 prompt + 调模型 + 解析」一整条放这儿 ——
/// App 前台经 XPC `generate(kind:)` 调、agent 后台直接调,同一份逻辑。确定性脱敏 / 打分在调用方(App/agent)用 Core 先做好,
/// pass 只吃已脱敏的基本类型输入。`languageName` 由调用方传入(引擎进程无 App locale)。按 kind 派发,新增 pass = 加一 case。
@available(macOS 26.0, *)
enum AIPassEngine {
    /// 通用派发:按 kind 解码输入 DTO → 跑对应 pass → 编码输出 DTO。未知 kind / 解码失败抛错(XPC 层回 ok=false)。
    static func run(kind: String, inputJSON: Data, languageName: String) async throws -> Data {
        guard let passKind = AIPassKind(rawValue: kind) else { throw AIPassEngineError.unknownKind(kind) }
        switch passKind {
        case .taskFailureShortExplanation:
            let input = try JSONDecoder().decode(TaskFailureExplanationInput.self, from: inputJSON)
            let text = try await taskFailureShortExplanation(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        case .activityWorkbenchExplanation:
            let input = try JSONDecoder().decode(ActivityWorkbenchExplanationInput.self, from: inputJSON)
            let text = try await activityWorkbenchExplanation(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        case .longFileSummary:
            let input = try JSONDecoder().decode(LongFileSummaryInput.self, from: inputJSON)
            let text = try await longFileSummary(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        case .reportText:
            let input = try JSONDecoder().decode(ReportTextInput.self, from: inputJSON)
            let text = try await reportText(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        case .activityReminder:
            let input = try JSONDecoder().decode(ActivityReminderInput.self, from: inputJSON)
            let text = try await activityReminder(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        case .rankWorkbenchFilterChips:
            let input = try JSONDecoder().decode(WorkbenchChipRankingInput.self, from: inputJSON)
            let numbers = try await rankWorkbenchFilterChips(input)
            return try JSONEncoder().encode(AIPassIntListOutput(numbers: numbers))
        case .nameWorkbenchClusters:
            let input = try JSONDecoder().decode(WorkbenchClusterNamingInput.self, from: inputJSON)
            let entries = try await nameWorkbenchClusters(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassClusterNamingOutput(entries: entries))
        case .archiveEntryPicks:
            let input = try JSONDecoder().decode(ArchiveEntryPicksInput.self, from: inputJSON)
            let numbers = try await archiveEntryPicks(input)
            return try JSONEncoder().encode(AIPassIntListOutput(numbers: numbers))
        case .archiveKindGuess:
            let input = try JSONDecoder().decode(ArchiveKindGuessInput.self, from: inputJSON)
            let out = try await archiveKindGuess(input, languageName: languageName)
            return try JSONEncoder().encode(out)
        case .urlOpenSuggestion:
            let input = try JSONDecoder().decode(URLOpenSuggestionInput.self, from: inputJSON)
            let number = try await urlOpenSuggestion(input)
            return try JSONEncoder().encode(AIPassIntOutput(number: number))
        case .diskImageInstallSuggestion:
            let input = try JSONDecoder().decode(DiskImageSuggestionInput.self, from: inputJSON)
            let out = try await diskImageInstallSuggestion(input, languageName: languageName)
            return try JSONEncoder().encode(out)
        case .fileSuggestion:
            let input = try JSONDecoder().decode(FileSuggestionInput.self, from: inputJSON)
            let out = try await fileSuggestion(input, languageName: languageName)
            return try JSONEncoder().encode(out)
        case .workspaceVerifyMisfits:
            let input = try JSONDecoder().decode(WorkspaceVerifyMisfitsInput.self, from: inputJSON)
            let ids = try await workspaceVerifyMisfits(input)
            return try JSONEncoder().encode(ids)
        case .workspaceNodeSuggestions:
            let items = try JSONDecoder().decode([AIVirtualNodePromptCandidate].self, from: inputJSON)
            let plans = try await workspaceNodeSuggestions(items)
            return try JSONEncoder().encode(plans)
        case .workspaceFolderGroups:
            let items = try JSONDecoder().decode([AIVirtualNodePromptCandidate].self, from: inputJSON)
            let out = try await workspaceFolderGroups(items)
            return try JSONEncoder().encode(out)
        case .workspaceOrganize:
            let items = try JSONDecoder().decode([AIVirtualNodePromptCandidate].self, from: inputJSON)
            let out = try await workspaceOrganize(items, languageName: languageName)
            return try JSONEncoder().encode(out)
        case .workspacePlan:
            let input = try JSONDecoder().decode(AIVirtualFolderPlanInput.self, from: inputJSON)
            let plan = try await workspacePlan(input, languageName: languageName)
            return try JSONEncoder().encode(plan)
        case .workspaceReview:
            let input = try JSONDecoder().decode(AIVirtualFolderPlanInput.self, from: inputJSON)
            let review = try await workspaceReview(input, languageName: languageName)
            return try JSONEncoder().encode(review)
        case .archiveFileKeyword:
            let query = try JSONDecoder().decode(String.self, from: inputJSON)
            let keyword = try await archiveFileKeyword(query)
            return try JSONEncoder().encode(keyword)
        case .settingsQuery:
            let input = try JSONDecoder().decode(SettingsQueryInput.self, from: inputJSON)
            let out = try await settingsQuery(input)
            return try JSONEncoder().encode(out)
        }
    }

    /// 文件浏览器单文件抽屉建议(结构化)。镜像原 App 端 fileSuggestion 的 prompt + 模型。动作词表由引擎据 Core
    /// 自己拼(XPC Service 已链 Core,和其它 workspace pass 一致);引擎只回**原始** token,**token 词表校验 +
    /// AIFileSuggestedAction 拼装留 App 侧**(依赖 Core 的 kind 适用 / openWith 合成,结果拼装在 App 更顺)。
    private static func fileSuggestion(_ input: FileSuggestionInput,
                                       languageName: String) async throws -> AIPassFileSuggestionOutput {
        let apps = Array(input.candidateOpenApps.prefix(8))
        let discouraged = Array(Set(input.discouragedTokens.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted().prefix(12)
        let openWithRule = apps.isEmpty ? "" : """


        You are also given a list of OTHER apps installed that can open this file — the user's DEFAULT \
        double-click app is intentionally NOT in the list. Set openWithAppNumber to the number of an app ONLY \
        when it is CLEARLY a better fit for THIS file than the default; otherwise set it to 0. Default to 0 — \
        most files should just use their default app, so recommending a different app must be clearly worth it.
        """
        let feedbackHint = discouraged.isEmpty ? "" : """


        The user has repeatedly ignored these suggestion types here; only include them if clearly valuable: \
        \(discouraged.joined(separator: ", ")).
        """
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(languageName). Never use any other language for it, not even partially.

        You are describing ONE file to the person who owns it, inside a file manager. You are given the file's name, \
        its role, a few structural signals, and a redacted excerpt of its actual content. From the CONTENT, write \
        ONE concrete, specific sentence about what this file really is or is about — the kind of thing a person \
        would say to remind themselves what it is. Do not restate the file name, do not be generic, do not mention \
        that text was redacted. If the excerpt is too thin to say anything specific, summarize from the name and \
        role as best you can, still in one concrete sentence.

        Then suggest a FEW next actions, but ONLY where an action is clearly the right next step for THIS file. \
        Never suggest an action just because it is possible; if nothing clearly fits, empty is correct. \
        ROLE HINTS (apply only when the file genuinely looks like one): if the role is 'release-notes', 'report', \
        'task-summary', or 'task' and the file reads like a finished deliverable someone would share, 'hash' is worth \
        suggesting. 'compress' is rarely the right step for a single document — suggest it ONLY when the file is \
        clearly large AND its content or context shows it is meant to be packaged up and sent to someone, not merely \
        because it is a document.\(openWithRule)\(feedbackHint)

        \(actionVocabularyRule)
        """
        var lines: [String] = ["File name: \(input.fileName)", "Kind: \(input.kind)"]
        if !input.roleTags.isEmpty { lines.append("Role: \(input.roleTags.joined(separator: ", "))") }
        if let languageHint = input.languageHint, !languageHint.isEmpty { lines.append("Format: \(languageHint)") }
        // 兜底:每条结构信号裁短 + 摘录封顶,避免单文件 prompt 超 4096-token(CJK 内容尤甚)。
        if !input.headings.isEmpty { lines.append("Headings: \(input.headings.prefix(8).map { clamp($0, 80) }.joined(separator: " | "))") }
        if !input.fieldNames.isEmpty { lines.append("Top-level fields: \(input.fieldNames.prefix(12).map { clamp($0, 48) }.joined(separator: ", "))") }
        let trimmedExcerpt = String(input.excerpt.prefix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExcerpt.isEmpty { lines.append("Content excerpt (redacted):\n\(trimmedExcerpt)") }
        if !apps.isEmpty {
            lines.append("Other apps that can open this file (the default double-click app is NOT listed) — refer to an app by its number:")
            for (i, a) in apps.enumerated() { lines.append("\(i + 1)\t\(clamp(a.name, 80))") }
        }
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedFileSuggestion.self, maxAttempts: 3)
        return AIPassFileSuggestionOutput(
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: generated.actions,
            openWithAppNumber: generated.openWithAppNumber)
    }

    /// 压缩包「你可能需要的文件」(结构化)。镜像原 App 端 archiveEntryPicks → 1 基序号(去重/合法/封顶 4)。
    private static func archiveEntryPicks(_ input: ArchiveEntryPicksInput) async throws -> [Int] {
        guard !input.entryPaths.isEmpty else { return [] }
        // FoundationModels 上下文 4096 token:按字符保守裁剪(每条 ≤160、最多 60 条、总预算 3000 字符),
        // 大归档的长路径列表不再爆 token(原来只 prefix(60)、不限每条长度 → 实测 5654 token 超限)。
        // 路径保尾部(文件名 / 末层更有判别力);编号语义仍对齐 input.entryPaths 的前缀,App 端用编号回查原路径。
        var cands: [String] = []
        var budget = 3_000
        for p in input.entryPaths.prefix(60) {
            let short = p.count > 160 ? "…" + String(p.suffix(159)) : p
            if budget - short.count - 4 < 0 { break }
            cands.append(short)
            budget -= short.count + 4
        }
        guard !cands.isEmpty else { return [] }
        let instructions = """
        Below are the files inside ONE archive the user has. Pick a FEW (by number) that the user would most likely \
        want to pull out or preview on their own — ONLY where a file CLEARLY stands out (a README / the main document \
        / a config / an installer / the one obviously-important file). MOST archives need NONE; an empty list is the \
        correct, common answer. Never invent a number; refer to files only by their number.
        """
        var lines = ["Archive: \(input.archiveName)", "Files (number<TAB>path) — refer to files by their number:"]
        for (i, p) in cands.enumerated() { lines.append("\(i + 1)\t\(p)") }
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedArchiveEntryPicks.self, maxAttempts: 3)
        var seen = Set<Int>()
        return Array(generated.pickedNumbers
            .compactMap { firstInt(in: $0) }
            .filter { $0 >= 1 && $0 <= cands.count && seen.insert($0).inserted }
            .prefix(4))
    }

    /// 归档「这是什么包」定性(结构化)。镜像原 App 端 archiveKindGuess(条目数+字符双预算防越界 trap;工具 token 过白名单)。
    private static func archiveKindGuess(_ input: ArchiveKindGuessInput,
                                         languageName: String) async throws -> AIPassArchiveKindOutput {
        guard !input.entries.isEmpty else { return AIPassArchiveKindOutput(summary: "", toolTokens: []) }
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(languageName). Never use any other language for it, not even partially.

        You are looking at the file and folder names inside ONE archive. Based only on those names and their folder \
        structure, write ONE short, concrete sentence describing what kind of archive this appears to be. Do not \
        claim certainty; say it appears to be something. Do not invent contents that are not supported by the paths. \
        Avoid naming a specific product or app unless that name is explicitly present in the archive name or entries.

        Then suggest proactive action tokens for this archive (verbatim, from this exact list). test and security are \
        SAFE, read-only checks that work on EVERY supported archive format. inspect and hash apply to release packages / \
        distributables (an app, a disk image, an installer, executables, a bin/ or dist/ tree, a versioned release). \
        convert — ONLY when the current format is clearly suboptimal for the likely next step. Return an empty list \
        only for a trivial, throwaway archive where even a quick safe check would add nothing. Allowed tokens: \
        test, security, inspect, hash, convert. Use each token verbatim; never invent one.
        """
        var lines = ["Archive: \(input.archiveName)", "Entries (number<TAB>type<TAB>path):"]
        // 字符预算保守对齐 4096 token 上下文(扣 instructions + 结构化 schema + 输出余量);
        // 原 6000 字符实测整条 content 达 4357 token、超 4096 上限 → 收紧到 3000。
        var promptBudget = 3_000
        for (i, entry) in input.entries.enumerated() {
            if i >= 200 || promptBudget <= 0 { break }
            let kind = entry.isDirectory ? "directory" : "file"
            let name = String(entry.name.prefix(160))
            lines.append("\(i + 1)\t\(kind)\t\(name)")
            promptBudget -= name.count + 12
        }
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedArchiveKindGuess.self, maxAttempts: 3)
        let allowed: Set<String> = ["inspect", "test", "hash", "convert", "security"]
        var seen = Set<String>()
        let tokens = generated.actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowed.contains($0) && seen.insert($0).inserted }
        return AIPassArchiveKindOutput(
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines), toolTokens: tokens)
    }

    /// 文本 URL「打开网页」(结构化)。镜像原 App 端 urlOpenSuggestion → 选中的 **0 基**下标;无 / 越界 → -1。
    private static func urlOpenSuggestion(_ input: URLOpenSuggestionInput) async throws -> Int {
        guard !input.urls.isEmpty else { return -1 }
        let cands = Array(input.urls.prefix(12))
        let instructions = """
        You are deciding whether a file manager should show an "open webpage" suggestion for ONE text file. The App \
        has already extracted REAL URLs from the file. Choose the ONE URL that is clearly useful for the owner to \
        open from this file — for example an official project page, release page, documentation, issue, download, \
        or other central reference. Use 0 if the URLs look incidental, tracking-like, too generic, or not worth \
        surfacing. Be strict: most files need no URL suggestion. Choose only by NUMBER from the list. Never invent, \
        rewrite, normalize, or output any URL. Do not mention or recommend any specific browser or app.
        """
        var lines = ["File: \(clamp(input.fileName, 160))"]
        if !input.roleTags.isEmpty { lines.append("Role: \(clamp(input.roleTags.joined(separator: ", "), 80))") }
        lines.append("Extracted URLs (number<TAB>url) — choose only by number:")
        lines.append(contentsOf: budgetedLines(cands.enumerated().map { i, url in "\(i + 1)\t\(clamp(url, 300))" }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedURLSuggestion.self, maxAttempts: 3)
        guard generated.urlNumber >= 1, generated.urlNumber <= cands.count else { return -1 }
        return generated.urlNumber - 1
    }

    /// 磁盘镜像「安装到应用程序」(结构化)。镜像原 App 端 diskImageInstallSuggestion → 一句定性 + 是否建议安装。
    private static func diskImageInstallSuggestion(_ input: DiskImageSuggestionInput,
                                                   languageName: String) async throws -> AIPassDiskImageOutput {
        let instructions = """
        LANGUAGE — MANDATORY: write the summary in \(languageName). Never use any other language for it, not even partially.

        The user has a disk image (.dmg) that contains the macOS app(s) listed below. Write ONE concrete, specific \
        sentence telling them what this is — the kind of reminder a person would give themselves (e.g. the installer \
        for that app, to be dragged into Applications). Do not be generic. Then decide suggestInstall: true if \
        actively suggesting they install the app (drag it into Applications) is a useful next step, false if not.
        """
        let prompt = "Disk image: \(input.dmgName)\nApp(s) inside: \(input.appNames.prefix(4).joined(separator: ", "))"
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: prompt,
            as: GeneratedDiskImageSuggestion.self, maxAttempts: 3)
        return AIPassDiskImageOutput(
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines), suggest: generated.suggestInstall)
    }

    /// 取字符串里第一个整数(模型偶尔回 "3." / "#3" / "3: 名字" 这类,容错抽编号)。
    private static func firstInt(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// 把模型返回的「序号 token」翻译回真实 candidateID(workspace pass 共用;小模型照抄长 opaque id 极易错 →
    /// 喂短序号再翻译)。容忍 "3"/"#3"/"item 3"/"3."。越界 / 非数字 → nil。`candidates` 须与喂 prompt 时同序(同 prefix)。
    private static func realID(_ token: String, in candidates: [AIVirtualNodePromptCandidate]) -> String? {
        guard let n = firstInt(in: token), n >= 1, n <= candidates.count else { return nil }
        return candidates[n - 1].candidateID
    }

    // MARK: - Prompt 预算兜底(对齐 FoundationModels 4096-token 上下文,CJK aware)
    //
    // 所有「喂列表 / 大文本给模型」的 pass 都必须裁,否则大输入(长文件名列表、整本设置目录、长摘录)会静默超
    // 4096 token 上下文 → 整条 pass 报错返回空(用户侧像「AI 老不出东西」)。镜像已落地的 archiveKindGuess /
    // archiveEntryPicks 兜底,统一抽成下面三个 helper。FoundationModels 不暴露 token 计数,故用保守字符预算:
    // 实测最坏内容(文件名 / 路径)≈ 0.73 token/char → 3000 char ≈ 2190 token + 固定开销(instructions+schema+
    // 输出)≈ 757 < 4096;CJK 1 token/char → 3000 < 4096。列表类用字符预算最稳;散文类(reportText)用 token 估算。

    /// 单字段截断到 limit 字符(超长末尾加 …)。把进 prompt 的名字 / 标签 / 标题裁短,防单条爆预算。
    private static func clamp(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(max(1, limit - 1))) + "…" : s
    }

    /// 取条目行前缀,累计字符不超 budget —— 列表类 prompt 的总预算兜底。**序号与原数组对齐不受影响**:尾部超预算的
    /// 条目不渲染 = 模型看不到 = 不会引用,realID 按序号回查仍安全(未渲染条目的序号模型不会产出)。
    private static func budgetedLines(_ lines: [String], budget: Int = 3_000) -> [String] {
        var out: [String] = []
        var left = budget
        for l in lines {
            if left - l.count < 0 { break }
            out.append(l)
            left -= l.count
        }
        return out
    }

    /// CJK 类标量(粗判,用于散文 token 估算):CJK 标点 / 假名 / 谚文 / CJK 统一表意 / 兼容表意 / 全角半角。
    private static func isCJKLike(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// 粗估散文 token 数(CJK ~1 / 其余 ~0.3,prose-tuned)。给 reportText 自适应预算用(instructions 大 → prompt
    /// 预算相应缩)。仅兜底估算、不求精确。
    private static func estimatedProseTokens(_ s: String) -> Int {
        var t = 0.0
        for u in s.unicodeScalars { t += isCJKLike(u) ? 1.0 : 0.3 }
        return Int(t.rounded(.up))
    }

    /// 把**散文** prompt 裁到估算 token 不超 maxTokens(从尾部裁、保留开头)。给 reportText 这种 App 拼好的不透明长文
    /// 兜底:散文按 CJK ~1 token/char、其余 ~0.3 token/char 估(prose-tuned,英文报告极少触发;CJK 长文才裁)。
    /// 单次 O(n) 累加,够长才返回带 … 的截断;否则原样返回。
    private static func clampProse(_ s: String, maxTokens: Int) -> String {
        var tokens = 0.0
        var result = ""
        result.reserveCapacity(s.count)
        for ch in s {
            for u in ch.unicodeScalars { tokens += isCJKLike(u) ? 1.0 : 0.3 }
            if tokens > Double(maxTokens) { return result + "…" }
            result.append(ch)
        }
        return s
    }

    /// AI 文件夹/建议「核查不扣题成员」(结构化)。镜像原 App 端 AIVirtualFolderModelPlanner.verifyMisfits ——
    /// 给主题 + 当前成员,让模型保守挑出明显不扣题的(拿不准就留),回**要移除的真实 candidateID**(去重)。
    /// 输出是序号(非给人看文本)故不注语言。App 据此从虚拟文件夹剔除,绝不碰磁盘。
    private static func workspaceVerifyMisfits(_ input: WorkspaceVerifyMisfitsInput) async throws -> [String] {
        guard !input.items.isEmpty else { return [] }
        let cands = Array(input.items.prefix(40))
        let instructions = """
        A folder collects items around ONE theme. Below is its theme and its current items (one per line: \
        "number<TAB>kind<TAB>name<TAB>roleTags"). List ONLY the NUMBERS of items that CLEARLY AND OBVIOUSLY do not \
        belong to this theme — items whose kind, name, AND roleTags all point away from the theme topic. Be \
        conservative: when in doubt, KEEP the item (do not list it). An empty list is correct most of the time — \
        most items usually fit. Never output a path; never remove an item just because its name is ambiguous.
        """
        var lines = ["Theme: \(clamp(input.theme, 200))", "Items (number<TAB>kind<TAB>name<TAB>roleTags):"]
        lines.append(contentsOf: budgetedLines(cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160), clamp(c.roleTags.joined(separator: " "), 80)].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedVerification.self, maxAttempts: 8)
        var seen = Set<String>()
        return generated.removeNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
    }

    /// 可建议动作词表(workspace 建议 pass 共用)。用 Core 的 AIVirtualNodeActionDeriver(XPC Service 已链 Core);
    /// **绝不让模型拼路径** —— 路径由 App 按 token + 目标条目回查。
    private static var actionVocabularyRule: String {
        let lines = AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.map {
            "  - \($0.id) (applies to: \($0.appliesToKinds.joined(separator: " / "))): \($0.userVisibleLabel)"
        }
        return "Allowed action tokens (use the token verbatim):\n" + lines.joined(separator: "\n")
    }

    /// AI 文件夹/建议「单条目动作建议」(结构化)。镜像原 App 端 suggestions —— 给已整理好的文件夹条目挑值得的动作,
    /// 模型按序号引用 + 按 token 选动作;引擎回译 candidateID + 词表校验 + 同目标同 token 去重 → [AINodeSuggestionPlan]。
    private static func workspaceNodeSuggestions(_ items: [AIVirtualNodePromptCandidate]) async throws -> [AINodeSuggestionPlan] {
        guard !items.isEmpty else { return [] }
        let cands = Array(items.prefix(40))
        let instructions = """
        The items below are already grouped into one folder. Suggest a useful next action for a FEW of them — ONLY \
        where there is a clear, specific reason for THAT SPECIFIC ITEM (e.g. an untested release archive → "test"; \
        a large stray folder → "compress"; an unverified signed container → "verify"). MOST items get NONE — empty \
        is the correct default. Never suggest an action just because it is possible; suggest only when it is clearly \
        the right next step for THIS item right now. Prioritize items that most obviously need attention. Refer to \
        items by their NUMBER, never output a path.

        \(actionVocabularyRule)
        """
        var lines = ["Items (number<TAB>kind<TAB>name) — refer to items by their number:"]
        lines.append(contentsOf: budgetedLines(cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160)].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedSuggestionSet.self, maxAttempts: 8)
        var seen = Set<String>()
        return generated.suggestions.compactMap { s -> AINodeSuggestionPlan? in
            let token = s.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.contains(where: { $0.id == token }),
                  let target = realID(s.targetID, in: cands),
                  seen.insert(target + "|" + token).inserted
            else { return nil }
            return AINodeSuggestionPlan(targetCandidateID: target, actionToken: token)
        }
    }

    /// 文件浏览器「文件折叠组建议」(结构化)。镜像原 App 端 folderGroupSuggestions —— 模型圈几组「一组文件 + 一个批量
    /// 动作」;引擎回译成员 candidateID(≥2)+ 词表校验 + 同成员同动作去重 → WorkspaceFolderGroupOutput。
    private static func workspaceFolderGroups(_ items: [AIVirtualNodePromptCandidate]) async throws -> WorkspaceFolderGroupOutput {
        guard items.count >= 2 else { return WorkspaceFolderGroupOutput(groups: []) }
        let cands = Array(items.prefix(60))
        let instructions = """
        The items below are the files in ONE folder the user is looking at. Propose a FEW GROUPS of files that the \
        user would clearly want to apply the SAME batch action to together — e.g. several archives → "test"; many \
        distributable / release files → "hash"; a pile of large stray files → "compress". ONLY propose a group when \
        it is obviously useful; MOST folders need NONE — an empty list is the correct, common answer. Each group \
        needs at least 2 files. Never invent a number, never output a path; refer to files by their NUMBER only.

        \(actionVocabularyRule)
        """
        var lines = ["Files (number<TAB>kind<TAB>name<TAB>roleTags) — refer to files by their number:"]
        lines.append(contentsOf: budgetedLines(cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160), clamp(c.roleTags.joined(separator: " "), 80)].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedFolderGroupSet.self, maxAttempts: 3)
        var usedSignatures = Set<String>()
        let groups = generated.groups.compactMap { g -> WorkspaceFolderGroupOutput.Group? in
            let token = g.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AIVirtualNodeActionDeriver.allowedSuggestionDescriptors.contains(where: { $0.id == token }) else { return nil }
            var seen = Set<String>()
            let ids = g.fileNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
            guard ids.count >= 2 else { return nil }
            let signature = token + "|" + ids.sorted().joined(separator: ",")
            guard usedSignatures.insert(signature).inserted else { return nil }
            return WorkspaceFolderGroupOutput.Group(memberIDs: ids, actionToken: token)
        }
        return WorkspaceFolderGroupOutput(groups: groups)
    }

    /// 文件夹「整理进新文件夹」建议(结构化)。镜像原 App 端 organizeSuggestion —— 模型判断是否有一簇同类文件值得归进
    /// 一个新子文件夹 + 起主题名 + 圈成员(≥3);不值得 → nil。folderName 给人看 → 注 languageName。
    private static func workspaceOrganize(_ items: [AIVirtualNodePromptCandidate],
                                          languageName: String) async throws -> WorkspaceOrganizeOutput? {
        guard items.count >= 3 else { return nil }
        let cands = Array(items.prefix(80))
        let instructions = """
        The items below are the files currently in ONE folder the user is looking at. If — and ONLY if — a clear \
        SUBSET of them obviously belongs together under a single new sub-folder (e.g. a pile of screenshots, a set \
        of invoices, the photos from one trip), propose tidying just that subset into a new folder you name. This \
        is real, obvious housekeeping the user would thank you for — NOT inventing an organization scheme. MOST \
        folders are already fine: when nothing clearly stands out, set worthOrganizing to false. Never force \
        unrelated files together. Name the folder by the real shared topic in \(languageName); \
        never use meta words like "folder", "files", "AI" or "group". Refer to files by their NUMBER only; never \
        output a path.
        """
        var lines = ["Files (number<TAB>kind<TAB>name<TAB>roleTags) — refer to files by their number:"]
        lines.append(contentsOf: budgetedLines(cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160), clamp(c.roleTags.joined(separator: " "), 80)].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedOrganizeSuggestion.self, maxAttempts: 3)
        guard generated.worthOrganizing else { return nil }
        let name = generated.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var seen = Set<String>()
        let ids = generated.fileNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
        guard ids.count >= 3 else { return nil }
        return WorkspaceOrganizeOutput(folderName: name, memberIDs: ids)
    }

    /// 命名 + 语言规则(plan/review 共用)。语言放最前 + 强制:给人看的 workspaceTitle / 分组名必须用界面语言,
    /// 禁止把 AI / 文件夹 / 集合 等元词塞进名字。语言名由调用方传入(引擎进程无 App locale)。
    private static func namingRule(_ languageName: String) -> String {
        """
        LANGUAGE — MANDATORY: write the workspaceTitle and EVERY group title in \(languageName). Never use any other \
        language for them, not even partially. Name everything by its REAL subject — the actual topic, project, or \
        what the items are — exactly as a person would name it in \(languageName). NEVER put meta words like "AI", \
        "assistant", "folder", "collection", "group", "files", "directory", "workspace" or "smart" into any title \
        unless that word is literally part of the real subject. The item numbers are plain integers — use them \
        exactly as given, never translate or alter them.
        """
    }

    /// 把用户对工作区的累积调教(固定 / 排除 / 喜欢 / 不喜欢 / 分组命名)展开成 prompt 提示行(自循环喂回模型)。
    /// 携带名字 / 来源目录 / 角色 / 用户起的组名 —— 路径不是隐私红线(见隐私口径);空则返回空。
    private static func hintLines(_ hints: AIWorkspaceLearningHints?) -> [String] {
        guard let h = hints, !h.isEmpty else { return [] }
        var lines: [String] = []
        if !h.removedItemNames.isEmpty {
            lines.append("Items the user REMOVED from here (name and location — do NOT bring back items like these): "
                + h.removedItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.keptItemNames.isEmpty {
            lines.append("Items the user explicitly KEEPS here (name and location — favor selecting items like these): "
                + h.keptItemNames.prefix(24).joined(separator: ", "))
        }
        if !h.userGroupTitles.isEmpty {
            lines.append("Group names the user has chosen here (reuse and honor these names/themes when grouping): "
                + h.userGroupTitles.prefix(12).joined(separator: ", "))
        }
        if !h.rejectedRoleTags.isEmpty {
            lines.append("Kinds of item the user dislikes here: " + h.rejectedRoleTags.prefix(12).joined(separator: ", "))
        }
        if !h.preferredRoleTags.isEmpty {
            lines.append("Kinds of item the user likes here: " + h.preferredRoleTags.prefix(12).joined(separator: ", "))
        }
        return lines
    }

    /// 模型输出按**序号**引用条目 → 翻译回真实 candidateID,组装成 AIFolderReview(plan/review 共用)。
    /// `candidates` 必须与喂 prompt 时同序(同 prefix)。
    private static func assemble(_ generated: GeneratedAIFolderPlan,
                                 candidates: [AIVirtualNodePromptCandidate]) -> AIFolderReview {
        let title = generated.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = generated.groups.enumerated().map { index, g in
            AIVirtualFolderGroupPlan(
                id: "model-\(index)",
                title: g.title,
                candidateIDs: g.candidateIDs.compactMap { realID($0, in: candidates) },
                prominent: g.expandFirst)
        }
        let plan = AIVirtualFolderPlan(workspaceTitle: title.isEmpty ? nil : title, groups: groups)
        return AIFolderReview(worthSurfacing: generated.worthSurfacing, plan: plan)
    }

    /// AI 文件夹「生成虚拟目录 plan」(结构化)。镜像原 App 端 plan(for:) —— 据主题 + 候选 + 调教让模型选成员 + 分组 + 命名。
    private static func workspacePlan(_ input: AIVirtualFolderPlanInput, languageName: String) async throws -> AIVirtualFolderPlan {
        let instructions = """
        \(namingRule(languageName))

        You curate and organize a set of related items around a theme. Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. Using the \
        theme and hints, decide which items genuinely BELONG together and SELECT only those — leave out items that \
        don't fit (you are choosing membership, not forced to place everything). Then group the selected items by \
        what they ARE or their shared topic, give each group a short name (1–3 words), and propose a clear name for \
        the whole collection. Aim for 2–4 groups; prefer a small number of clear, well-named groups over many tiny \
        ones. Base everything ONLY on the names, kinds and roleTags given. Refer to each item by its NUMBER (the \
        leftmost column) — never output a file path; simply omit any item that doesn't belong rather than forcing it \
        into a group.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance: favor items like the ones they keep, leave out items like the ones they \
        removed, and reuse the group names/themes they picked. The item numbers are plain integers — use them \
        exactly as given, never translate them.
        """
        let cands = Array(input.candidates.prefix(40))   // 短 prompt 更稳(单次生成失败率随长度飙升)
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(clamp(prompt, 200))") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(clamp(ws.queryTokens.joined(separator: ", "), 200))") }
        lines.append("Current title: \(clamp(ws.title, 120))")
        // 兜底:hint 行(各裁 200)+ 条目行(名裁 160)合计裁进预算,对齐 4096-token(plan 的 instructions+嵌套
        // schema 开销较大 → 比无 hint 的 pass 收紧到 2600)。
        var body = hintLines(input.learningHints).map { clamp($0, 200) }
        body.append("Items (number<TAB>kind<TAB>name<TAB>roleTags) — refer to items by their number:")
        body += cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160), clamp(c.roleTags.joined(separator: " "), 80)].joined(separator: "\t")
        }
        lines.append(contentsOf: budgetedLines(body, budget: 2_600))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedAIFolderPlan.self, maxAttempts: 12)   // 连试 12 代 + 极简 schema + 短 prompt 压报错
        return assemble(generated, candidates: cands).plan
    }

    /// AI 文件夹「后台复核(值不值得 + plan)」(结构化)。镜像原 App 端 review(for:) —— 模型既判断这个候选主题值不值得
    /// 作为文件夹出现(质量优先),又顺带产出它的 plan。worthSurfacing == false → 调用点不升成可见工作区。
    private static func workspaceReview(_ input: AIVirtualFolderPlanInput, languageName: String) async throws -> AIFolderReview {
        let instructions = """
        \(namingRule(languageName))

        You are a STRICT quality judge for a background "AI folder". Each item below is one line: \
        "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the leftmost column. These items \
        were grouped only because they share a name token or a common task/archive — but a shared token is USUALLY \
        COINCIDENTAL (many unrelated files share a common word like "report", "final", "v2", "data" or a date). \
        Most such groups are NOT worth a folder.

        Set worthSurfacing = true ONLY when ALL of the following hold:
          (a) At least THREE items CLEARLY belong together for a real reason beyond a shared word
          (b) The theme is specific enough that a person would deliberately name and keep this folder
          (c) The items form a recognizable project, topic, dataset, or deliverable — not a loose grab-bag

        Set worthSurfacing = false when: fewer than three items truly relate; they merely share a generic/common \
        word; the theme is vague or weak; or it is a coincidental match. Be strict and skeptical: rejecting a \
        borderline theme is always safer than approving it.

        If you DO approve (worthSurfacing = true): curate the items — keep those that fit, drop the ones that only \
        coincidentally matched; group by meaning with short names (1–3 words); propose a clear name for the folder. \
        If you REJECT (worthSurfacing = false): set groups to [] and workspaceTitle to "".

        Refer to items by their NUMBER (the leftmost column) — never invent a number, output a file path, or \
        translate names. The item numbers are plain integers — use them exactly as given. Reply only with the \
        structured plan, including worthSurfacing.

        If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group names they chose, \
        treat these as strong guidance: a theme the user has actively curated is more worth surfacing, and you \
        should honor what they keep, leave out, and how they name groups.
        """
        let cands = Array(input.candidates.prefix(40))   // 短 prompt 更稳(单次生成失败率随长度飙升)
        var lines: [String] = []
        let ws = input.workspace
        if let prompt = ws.prompt, !prompt.isEmpty { lines.append("Folder theme: \(clamp(prompt, 200))") }
        if !ws.queryTokens.isEmpty { lines.append("Theme hints: \(clamp(ws.queryTokens.joined(separator: ", "), 200))") }
        lines.append("Candidate title: \(clamp(ws.title, 120))")
        // 兜底:hint 行 + 条目行合计裁进预算(同 plan,收紧到 2600)。
        var body = hintLines(input.learningHints).map { clamp($0, 200) }
        body.append("Items (number<TAB>kind<TAB>name<TAB>roleTags) — refer to items by their number:")
        body += cands.enumerated().map { i, c in
            ["\(i + 1)", c.kind, clamp(c.displayName, 160), clamp(c.roleTags.joined(separator: " "), 80)].joined(separator: "\t")
        }
        lines.append(contentsOf: budgetedLines(body, budget: 2_600))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedAIFolderPlan.self, maxAttempts: 12)   // 连试 12 代 + 极简 schema + 短 prompt 压报错
        return assemble(generated, candidates: cands)
    }

    /// #63 归档清单「一句话查询」NL → 文件名关键词(镜像原 App archiveFileKeyword)。输出关键词无界面语言依赖。
    private static func archiveFileKeyword(_ query: String) async throws -> String {
        let instructions = """
        The user is looking for a file they remember is inside some archive. Extract the single most useful \
        file-name keyword to search for. Prefer a concrete noun or the likely file name; drop filler words. \
        Return just the keyword, no punctuation or path.
        """
        let spec = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: query, as: GeneratedArchiveFileQuery.self)
        return spec.keyword
    }

    /// #64 设置「一句话搜索」NL → 命中设置 id + 意图(镜像原 App settingsQuerySpec)。输出 intent 的 rawValue 字符串。
    private static func settingsQuery(_ input: SettingsQueryInput) async throws -> SettingsQueryOutput {
        // 兜底:整本设置目录嵌进 instructions —— CJK 本地化的 title/summary ≈ 1 token/char,全量目录可超 4096。
        // 每行裁 160 + 总预算 2800(查询本身很短、占不了多少),保证不超上下文(超预算的尾部设置项暂不进候选)。
        let catalog = budgetedLines(
            input.catalog.split(separator: "\n", omittingEmptySubsequences: false).map { clamp(String($0), 160) },
            budget: 2_800).joined(separator: "\n")
        let instructions = """
        The user describes a setting they want to find or change in an archive app. From the catalog below \
        (one per line as "id<TAB>title<TAB>summary"), pick the single best-matching setting and copy its id \
        verbatim, and decide the intent: navigate (just find it), enable (turn it on) or disable (turn it \
        off). If nothing matches, return an empty id. Output only the two fields.

        Catalog:
        \(catalog)
        """
        let spec = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: input.query, as: GeneratedSettingsQuery.self)
        return SettingsQueryOutput(settingID: spec.settingID, intent: spec.intent.rawValue)
    }

    /// 活动中心「建议筛选」chip 模型排序(结构化)。镜像原 App 端 rankWorkbenchFilterChips。
    private static func rankWorkbenchFilterChips(_ input: WorkbenchChipRankingInput) async throws -> [Int] {
        guard input.candidates.count >= 2 else { return [] }
        let capped = Array(input.candidates.prefix(20))
        let instructions = """
        You are ranking SUGGESTED FILTER chips for a file-archive app's Activity Center (output is not user-facing \
        text — return chip numbers only). Each chip is a safe, predefined filter over the user's task list. Given the \
        chips (number, what they select, how many tasks match), return the chip NUMBERS in priority order — MOST \
        USEFUL FIRST — keeping ONLY the chips genuinely worth showing and dropping redundant or low-value ones. Prefer \
        chips that surface actionable failures the user likely cares about; avoid near-duplicates. Refer to chips by \
        their NUMBER only; never invent a number.
        """
        var lines = ["Chips (number<TAB>selects<TAB>matchCount):"]
        lines.append(contentsOf: budgetedLines(capped.enumerated().map { i, c in
            ["\(i + 1)", clamp(c.label, 160), "\(c.matches)"].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedChipRanking.self, maxAttempts: 3)
        var seen = Set<Int>()
        return generated.orderedNumbers
            .compactMap { firstInt(in: $0) }
            .filter { $0 >= 1 && $0 <= capped.count && seen.insert($0).inserted }
    }

    /// 活动中心「真建议」聚集命名/择优(结构化)。镜像原 App 端 nameWorkbenchClusters。
    private static func nameWorkbenchClusters(_ input: WorkbenchClusterNamingInput,
                                              languageName: String) async throws -> [AIPassClusterNamingOutput.Entry] {
        guard !input.candidates.isEmpty else { return [] }
        let capped = Array(input.candidates.prefix(20))
        let instructions = """
        LANGUAGE — MANDATORY: write the names in \(languageName). You are labeling SUGGESTED FILTERS for a file-archive \
        app's Activity Center. Each candidate is a REAL cluster of tasks the app already found by crossing \
        source / type / diagnostic / time dimensions — some are failure groups, some are common operation groups \
        (e.g. all compress tasks, tasks from Downloads). You do NOT invent clusters, only label the ones given, \
        and the dimensions tell you what each one selects (a "status=failed" dimension means it's a failure group; \
        no status means all states). Pick the few MOST worth showing and give each a SHORT, concrete name the user \
        would recognize. Drop redundant or low-value ones. Refer to clusters by their NUMBER only; never invent a number.
        """
        var lines = ["Clusters (number<TAB>dimensions<TAB>matchCount):"]
        lines.append(contentsOf: budgetedLines(capped.enumerated().map { i, c in
            ["\(i + 1)", clamp(c.facts.joined(separator: "+"), 160), "\(c.matches)"].joined(separator: "\t")
        }))
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedClusterNaming.self, maxAttempts: 3)
        var seen = Set<Int>()
        var out: [AIPassClusterNamingOutput.Entry] = []
        for entry in generated.labeledClusters {
            guard let n = firstInt(in: entry), n >= 1, n <= capped.count, seen.insert(n).inserted else { continue }
            guard let sep = entry.range(of: ":") ?? entry.range(of: "：") else { continue }
            let name = entry[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out.append(AIPassClusterNamingOutput.Entry(index: n, name: name))
        }
        return out
    }

    /// 文件「有活动」提醒(**结构化** @Generable)。镜像原 App 端 AIVirtualFolderModelPlanner.activityReminder ——
    /// 结构化 pass 把 @Generable 类型(GeneratedActivityReminder)一起搬进引擎(只在 agent+XPC,带 FoundationModels)。
    private static func activityReminder(_ input: ActivityReminderInput, languageName: String) async throws -> String {
        let instructions = """
        LANGUAGE — MANDATORY: write the reminder in \(languageName). Never use any other language for it, not even partially.

        Inside a file manager, the owner recently ran an operation that produced ONE file. Write ONE short, natural \
        sentence reminding them of that recent activity — what they did and roughly when — so they can jump to it in \
        the activity history. Use ONLY the action and timeframe you are given; be concise and concrete; do not invent \
        any extra detail and do not restate the file name verbatim.
        """
        let prompt = "File: \(input.fileName)\nRecent action: \(input.actionText)\nWhen: \(input.whenText)"
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: prompt, as: GeneratedActivityReminder.self, maxAttempts: 3)
        return generated.reminder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 文件「查看更长总结」(纯文本)。镜像原 App 端 AIVirtualFolderModelPlanner.longFileSummary。
    private static func longFileSummary(_ input: LongFileSummaryInput, languageName: String) async throws -> String {
        let instructions = """
        LANGUAGE — MANDATORY: write the whole summary in \(languageName). Never use any other language, not even partially.

        You are summarizing ONE file for the person who owns it, in more depth than a single line. From the CONTENT, \
        write a SHORT but substantive summary: one or two sentences on what this file really is, then a few concise \
        lines on its key points or structure. Be concrete and specific to THIS file's actual content — do not be \
        generic, do not restate the file name, do not mention that anything was redacted. If the excerpt is thin, \
        say what you reasonably can from the name and role. Keep it well under 200 words.
        """
        var lines = ["File name: \(input.fileName)"]
        if !input.roleTags.isEmpty { lines.append("Role: \(input.roleTags.joined(separator: ", "))") }
        if let languageHint = input.languageHint, !languageHint.isEmpty { lines.append("Format: \(languageHint)") }
        if !input.headings.isEmpty { lines.append("Headings: \(input.headings.prefix(12).map { clamp($0, 80) }.joined(separator: " | "))") }
        // 摘录封顶 2400(CJK ≈ 2400 token,加标题 + instructions 仍 < 4096;原 3000 在纯 CJK 长文会贴边/超)。
        let trimmed = String(input.excerpt.prefix(2_400)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append("Content excerpt (redacted):\n\(trimmed)") }
        return try await AgentGenerationSerializer.shared
            .generateText(instructions: instructions, prompt: lines.joined(separator: "\n"))
    }

    /// 活动中心「需要处理」AI 解读(纯文本)。镜像原 App 端 AIVirtualFolderModelPlanner.activityWorkbenchExplanation。
    private static func activityWorkbenchExplanation(_ input: ActivityWorkbenchExplanationInput,
                                                     languageName: String) async throws -> String {
        let instructions = """
        LANGUAGE — MANDATORY: write in \(languageName). You are the AI panel inside a file-archive app's Activity Center. \
        Given a summary of the current task list and a few of the most important UNSEEN FAILED tasks (only their \
        type, source, and diagnostic tags — never file names or paths), write ONE short, concrete paragraph saying \
        what is most worth dealing with right now and why. Be specific to the failures given; never invent a task; \
        do not list everything; at most 2-3 sentences. If nothing clearly stands out, say the task list looks healthy.
        """
        var lines = ["Task summary (counts): \(clamp(input.summaryFacts.joined(separator: ", "), 400))"]
        if !input.failedFacts.isEmpty {
            lines.append("Top unseen failed tasks (type / source / diagnostic tags):")
            lines.append(contentsOf: budgetedLines(input.failedFacts.prefix(8).map { clamp($0, 200) }, budget: 2_000))
        }
        return try await AgentGenerationSerializer.shared
            .generateText(instructions: instructions, prompt: lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 活动中心失败任务「失败解释」(纯文本)。镜像原 App 端 AIVirtualFolderModelPlanner.taskFailureShortExplanation 的
    /// prompt(语言由 languageName 传入,不再读 App 的 uiLanguageName)。输入已脱敏、不含原始路径。
    private static func taskFailureShortExplanation(_ input: TaskFailureExplanationInput,
                                                    languageName: String) async throws -> String {
        let instructions = """
        LANGUAGE — MANDATORY: write in \(languageName). You are the AI panel inside a file-archive app's Activity Center. \
        A task FAILED and the user just opened it. Given the task type, source, diagnostic tags and a redacted \
        failure message / error lines (already stripped of file paths), write ONE or TWO short sentences in plain \
        language: what most likely went wrong and what to check or try next. Be specific to the diagnostics given; \
        never invent details; do not repeat the raw error verbatim; at most 2 sentences.
        """
        var lines = ["Failed task — type: \(input.kind), source: \(input.source), tags: \(input.tags.isEmpty ? "none" : clamp(input.tags.joined(separator: "+"), 200))"]
        if let failureMessage = input.failureMessage, !failureMessage.isEmpty {
            lines.append("Redacted failure message: \(clamp(failureMessage, 800))")
        }
        if !input.errorLines.isEmpty {
            lines.append("Redacted error lines:")
            lines.append(contentsOf: budgetedLines(input.errorLines.prefix(6).map { clamp($0, 240) }, budget: 1_600))
        }
        return try await AgentGenerationSerializer.shared
            .generateText(instructions: instructions, prompt: lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 通用「报告解释 / 文档起草」散文生成(纯文本)。所有报告类 AI 的 instructions+prompt 由 App 侧各 `*Prompt`
    /// 构造器拼好(只读事实),引擎只负责**注入回复语言** + 过串行闸调模型 —— 复刻原 App 端 `AIReportAssistant.generate`
    /// 的 `replyLanguageInstruction`(引擎进程无 App locale,语言名由调用方随每次 generate 传入)。不再各写一个 pass,
    /// 散文报告全共用这一条;结构化报告(NL 查询等)另走各自结构化 pass。
    private static func reportText(_ input: ReportTextInput, languageName: String) async throws -> String {
        let combined = input.instructions + "\n\n"
            + "Write your entire reply in \(languageName). Do not restate these instructions; reply only with the note itself."
        // 兜底:reportText 是 App 拼好的不透明散文(报告解释 / 起草),无结构可逐项裁 → 按 token 自适应裁 prompt。
        // 留 ~500 给输出、按 instructions 实际大小缩 prompt 预算,使 instructions + prompt 合计 ≲ 3600 token < 4096。
        // 英文报告 ~0.3 token/char 几乎不触发;CJK 长报告才裁尾。若 instructions 自身就过大(App 侧把事实塞进
        // instructions),这里护不住 —— 那是 App 侧 prompt 构造的事,需在调用点收(见 [[feedback_foundationmodels_token_budget]])。
        let promptBudget = max(600, 3_600 - estimatedProseTokens(combined))
        return try await AgentGenerationSerializer.shared
            .generateText(instructions: combined, prompt: clampProse(input.prompt, maxTokens: promptBudget))
    }
}

enum AIPassEngineError: Error { case unknownKind(String) }
#endif
