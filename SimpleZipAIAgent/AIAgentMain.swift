//
//  AIAgentMain.swift
//  SimpleZipAIAgent
//
//  独立 AI 进程改造 · 阶段1 · **LaunchAgent 通道**的进程入口。
//  这是 SMAppService 注册的 LaunchAgent helper(后台,Login Items 可见、受「允许后台」门控):起一个绑定到
//  约定 Mach service 名的 NSXPCListener,长驻等 App / launchd 计划连接。App 关闭后仍可被 launchd 周期拉起
//  做后台索引 —— 这正是它该有的语义。
//
//  生成引擎(AIAgentService / 全局串行闸 / @Generable 结构化生成 / agentLog)已抽到
//  SimpleZipAgentSupport/AIAgentService.swift,与**前台 XPC Service 通道**共用同一份(同一个全局串行闸)。
//  本文件只负责「LaunchAgent 这条通道」的 listener 搭建与 `--probe` 直跑;前台 XPC Service 的入口在
//  AIXPCServiceMain.swift。
//
//  无 AppKit → dispatchMain() 长驻是 XPC listener 的标准做法(A18 对 NSWindow 的顾虑在这里不适用)。
//

import Foundation

@main
struct AIAgentMain {
    static func main() {
        // `--probe`:直接在本(独立)进程跑一次模型探针后退出 —— 绕开 SMAppService/launchd/XPC,
        // 单独回答地基问题「端上模型能否在非 App 的独立进程里跑」。便于命令行直接验证:
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
