//
//  AIXPCServiceMain.swift
//  SimpleZipAIXPCService
//
//  独立 AI 进程改造 · 阶段1 · **前台 XPC Service 通道**的进程入口。
//  这是 App 私有的内嵌 XPC Service(打包在 SimpleZip.app/Contents/XPCServices/SimpleZipAIXPCService.xpc):
//    - App 用 `NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName)` 连它,launchd 即按需拉起;
//    - 生命周期绑 App(Info.plist `XPCService.ServiceType = Application`),App 退出即随之终止;
//    - **不进 Login Items、不受「允许在后台」开关 gate** —— 正是前台按需推理要的稳妥通道。
//  对照 LaunchAgent 通道(AIAgentMain.swift):后者在 Login Items、受门控,负责 App 关闭后的后台索引。
//
//  关键:两条通道的 listener delegate / exportedObject / 生成引擎全用 SimpleZipAgentSupport/AIAgentService.swift
//  那一份(AIAgentListenerDelegate + AIAgentService) → 不管从哪条通道进来,都过**同一个全局串行闸**,
//  端上模型不会被重叠的 respond() 越界 trap。正常情况下 App 开 → 本 XPC Service 活 / App 关 → LaunchAgent 活,
//  两进程不同时跑,模型也不会双载。
//
//  A18:`NSXPCListener.service()` 的 `resume()` 对 service 监听器**不返回**(内部按 Info.plist
//  `RunLoopType = dispatch_main` 进入 run loop 服务连接),这是 XPC Service 入口的标准形态,不是
//  「阻塞主线程等 async」—— 它就是本服务的事件循环。
//

import Foundation

@main
struct AIXPCServiceMain {
    static func main() {
        let listener = NSXPCListener.service()
        let delegate = AIAgentListenerDelegate()
        listener.delegate = delegate
        agentLog("XPC service starting · resume() (does not return) · pid \(ProcessInfo.processInfo.processIdentifier)")
        listener.resume()   // service 监听器:resume() 进入 run loop 不返回
    }
}
