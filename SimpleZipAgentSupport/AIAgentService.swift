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
        case .activityReminder:
            let input = try JSONDecoder().decode(ActivityReminderInput.self, from: inputJSON)
            let text = try await activityReminder(input, languageName: languageName)
            return try JSONEncoder().encode(AIPassTextOutput(text: text))
        }
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
}

enum AIPassEngineError: Error { case unknownKind(String) }
#endif
