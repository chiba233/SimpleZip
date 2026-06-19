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
            let sema = DispatchSemaphore(value: 0)
            Task {
                let result = await AIAgentService.probeText()
                agentLog("DIRECT PROBE → \(result)")
                print(result)
                sema.signal()
            }
            sema.wait()
            return
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
            do {
                let session = LanguageModelSession(
                    instructions: "You are a terse echo. Reply with exactly one short word.")
                let reply = try await session.respond(to: "Say: ready").content
                return "SUCCESS — 模型在 agent(独立)进程里跑通了。样本: \(reply)"
            } catch {
                return "FAILURE — session.respond 在 agent 进程抛错: \(error)"
            }
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
