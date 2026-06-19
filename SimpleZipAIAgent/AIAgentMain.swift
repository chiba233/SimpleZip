//
//  AIAgentMain.swift
//  SimpleZipAIAgent
//
//  独立 AI 进程改造 · 阶段1 Step 0 · agent 进程入口 + 最小 XPC 服务。
//  起一个绑定到约定 Mach service 名的 NSXPCListener,长驻等 App(或 launchd 计划)连接。
//  Step 0 只暴露 probeModel —— 唯一职责是验证「端上 FoundationModels 能否在这个非 App 的独立进程里跑」,
//  这是「agent 持有模型串行闸、前台+后台生成都进 agent」整套设计的地基。跑通 → 模型可迁 agent;
//  跑不通 → 退路:agent 只承载确定性扫描/索引/IO,模型留 App。
//
//  无 AppKit → dispatchMain() 长驻是 XPC listener 的标准做法(A18 对 NSWindow 的顾虑在这里不适用)。
//  目前 helper 还没嵌进 app bundle、没注册 SMAppService —— 那是 Step 0b/0c。本步只让 target 编过、
//  XPC/FoundationModels API 接对。
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct AIAgentMain {
    static func main() {
        // `--probe`:直接在本(独立)进程跑一次模型探针后退出 —— 绕开 SMAppService/launchd/XPC,
        // 单独回答 Step 0 的地基问题「端上模型能否在非 App 的独立进程里跑」。便于命令行直接验证:
        //   .../Contents/MacOS/SimpleZipAIAgent --probe
        if CommandLine.arguments.contains("--probe") {
            // ⚠️ A18:**绝不**用 DispatchSemaphore 阻塞主线程等模型 —— FoundationModels 内部异步 / XPC
            // 回复要靠主 run loop 泵才能送达,阻塞主线程 = run loop 不泵 = respond 永远不回 = 死锁
            // (实测:sema.wait() 版本 0% CPU 卡死)。改成让 Task 跑完直接 exit,主线程跑 run loop 服务队列。
            Task {
                let result = await AIAgentService.probeText()
                agentLog("DIRECT PROBE → \(result)")
                print(result)
                exit(0)
            }
            RunLoop.main.run()
        }
        // 默认:起绑定到约定 Mach service 名的 NSXPCListener,长驻等 App / launchd 连接。
        let delegate = AIAgentListenerDelegate()
        let listener = NSXPCListener(machServiceName: SimpleZipAIAgentXPCNames.machService)
        listener.delegate = delegate
        listener.resume()
        agentLog("listener resumed · mach=\(SimpleZipAIAgentXPCNames.machService) · pid \(ProcessInfo.processInfo.processIdentifier)")
        dispatchMain()
    }
}

/// 接受 App 的 XPC 连接,把接口 / 实现挂上去。Step 0 不做对端校验(Step 2 接 SMAppService 时加
/// `xpc_connection_set_peer_code_signing_requirement` 同签名身份互信)。
final class AIAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.exportedObject = AIAgentService()
        conn.resume()
        return true
    }
}

/// XPC 服务实现。Step 0 只有探针。
final class AIAgentService: NSObject, SimpleZipAIAgentXPC {
    func probeModel(reply: @escaping (String) -> Void) {
        Task {
            let result = await AIAgentService.probeText()
            agentLog("probeModel → \(result)")
            reply(result)
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
}

enum AgentGenerationError: Error { case exhausted }

/// agent 结构化探针用的最小 @Generable 规格(镜像 App 端 ArchiveFileQuerySpec:单个 String + @Guide)。
@available(macOS 26.0, *)
@Generable
struct AgentProbeSpec: Sendable {
    @Guide(description: "The single most useful file-name keyword to search archives for, extracted from the user's request. A bare word or short phrase, no punctuation, no path.")
    var keyword: String
}

@available(macOS 26.0, *)
enum AgentGeneration {
    /// 在 agent 进程跑一次**结构化** @Generable 生成(过串行闸 + 重试),回人话结果片段。
    static func structuredProbe() async -> String {
        do {
            let spec = try await AgentGenerationSerializer.shared.generateStructured(
                instructions: """
                The user is looking for a file they remember is inside some archive. Extract the single most \
                useful file-name keyword to search for. Return just the keyword, no punctuation or path.
                """,
                prompt: "I think my budget spreadsheet is zipped up somewhere",
                as: AgentProbeSpec.self)
            return "结构化生成 OK,keyword=\"\(spec.keyword)\""
        } catch {
            return "结构化生成失败: \(error)"
        }
    }
}
#endif
