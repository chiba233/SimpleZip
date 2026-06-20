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
                agentLog("generate(\(kind)) → \(output.count) bytes")
                reply(output, true)
            } catch {
                agentLog("generate(\(kind)) FAILED: \(error)")
                fail("生成失败(\(kind)): \(error)")
            }
            #else
            fail("agent target 无法 import FoundationModels(SDK 不含)。")
            #endif
        }
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
        }
    }

    /// 文件浏览器单文件抽屉建议(结构化)。镜像原 App 端 fileSuggestion 的 prompt + 模型;**token 词表校验留 App 侧**
    /// (那依赖 Core 的动作词表,放 App 才能让 XPC Service 不链 Core)→ 引擎只回**原始** token,App 再过 Core 校验。
    /// `actionVocabularyRule` 由 App 据 Core 词表拼好传入。
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

        \(input.actionVocabularyRule)
        """
        var lines: [String] = ["File name: \(input.fileName)", "Kind: \(input.kind)"]
        if !input.roleTags.isEmpty { lines.append("Role: \(input.roleTags.joined(separator: ", "))") }
        if let languageHint = input.languageHint, !languageHint.isEmpty { lines.append("Format: \(languageHint)") }
        if !input.headings.isEmpty { lines.append("Headings: \(input.headings.prefix(8).joined(separator: " | "))") }
        if !input.fieldNames.isEmpty { lines.append("Top-level fields: \(input.fieldNames.prefix(12).joined(separator: ", "))") }
        let trimmedExcerpt = String(input.excerpt.prefix(1_400)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExcerpt.isEmpty { lines.append("Content excerpt (redacted):\n\(trimmedExcerpt)") }
        if !apps.isEmpty {
            lines.append("Other apps that can open this file (the default double-click app is NOT listed) — refer to an app by its number:")
            for (i, a) in apps.enumerated() { lines.append("\(i + 1)\t\(a.name)") }
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
        let cands = Array(input.entryPaths.prefix(60))
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
        var promptBudget = 6_000
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
        var lines = ["File: \(input.fileName)"]
        if !input.roleTags.isEmpty { lines.append("Role: \(input.roleTags.joined(separator: ", "))") }
        lines.append("Extracted URLs (number<TAB>url) — choose only by number:")
        for (i, url) in cands.enumerated() { lines.append("\(i + 1)\t\(url)") }
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
        var lines = ["Theme: \(input.theme)", "Items (number<TAB>kind<TAB>name<TAB>roleTags):"]
        for (i, c) in cands.enumerated() {
            lines.append(["\(i + 1)", c.kind, c.displayName, c.roleTags.joined(separator: " ")].joined(separator: "\t"))
        }
        let generated = try await AgentGenerationSerializer.shared.generateStructured(
            instructions: instructions, prompt: lines.joined(separator: "\n"),
            as: GeneratedVerification.self, maxAttempts: 8)
        var seen = Set<String>()
        return generated.removeNumbers.compactMap { realID($0, in: cands) }.filter { seen.insert($0).inserted }
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
        for (i, c) in capped.enumerated() {
            lines.append(["\(i + 1)", c.label, "\(c.matches)"].joined(separator: "\t"))
        }
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
        for (i, c) in capped.enumerated() {
            lines.append(["\(i + 1)", c.facts.joined(separator: "+"), "\(c.matches)"].joined(separator: "\t"))
        }
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
        if !input.headings.isEmpty { lines.append("Headings: \(input.headings.prefix(12).joined(separator: " | "))") }
        let trimmed = String(input.excerpt.prefix(3_000)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        var lines = ["Task summary (counts): \(input.summaryFacts.joined(separator: ", "))"]
        if !input.failedFacts.isEmpty {
            lines.append("Top unseen failed tasks (type / source / diagnostic tags):")
            lines.append(contentsOf: input.failedFacts.prefix(8))
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
        var lines = ["Failed task — type: \(input.kind), source: \(input.source), tags: \(input.tags.isEmpty ? "none" : input.tags.joined(separator: "+"))"]
        if let failureMessage = input.failureMessage, !failureMessage.isEmpty {
            lines.append("Redacted failure message: \(failureMessage)")
        }
        if !input.errorLines.isEmpty {
            lines.append("Redacted error lines:")
            lines.append(contentsOf: input.errorLines.prefix(6))
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
        return try await AgentGenerationSerializer.shared.generateText(instructions: combined, prompt: input.prompt)
    }
}

enum AIPassEngineError: Error { case unknownKind(String) }
#endif
