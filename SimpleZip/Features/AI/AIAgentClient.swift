//
//  AIAgentClient.swift
//  SimpleZip
//
//  独立 AI 进程改造 · 阶段1 Step 0c · App 侧连 SimpleZipAIAgent(Mach XPC)的最小客户端。
//  注册 LaunchAgent(SMAppService)+ 连约定的 Mach 服务 + 调探针。目前仅 DevTools 用来验证
//  「端上 FoundationModels 能否在独立 agent 进程里跑」—— 独立 AI 进程改造的地基。
//  跑通后,后续 Step 才把它扩成完整 client facade(配置同步 / 数据投影 / 诊断,坑 9 带 schemaVersion);
//  后台定时索引的开 / 关 + 频率由 Settings → AI 驱动,不在这写死。
//

import Foundation
import ServiceManagement

enum AIAgentClient {
    /// 注册 agent + 在 agent 进程跑一次模型探针;结果(人话)在主线程回传(供 DevTools 显示)。
    nonisolated static func runProbe(_ completion: @escaping @MainActor (String) -> Void) {
        func reply(_ message: String) { Task { @MainActor in completion(message) } }

        guard #available(macOS 13.0, *) else {
            reply("macOS < 13,SMAppService 不可用。")
            return
        }
        // 1. 注册 LaunchAgent(已 enabled 则跳过)。register() 可能要求 helper 与 App 同签名身份、
        //    且 App 不在 DerivedData 而在 /Applications —— 失败把人话原因回传,不崩。
        let service = SMAppService.agent(plistName: "yumeka.SimpleZip-in-mac.aiagent.plist")
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                reply("""
                注册 LaunchAgent 失败:\(error.localizedDescription)
                常见原因:helper 与 App 签名身份不一致(本地需 SimpleZip Dev、非 ad-hoc)/ App 在 DerivedData 跑而非 /Applications。
                """)
                return
            }
        }
        // 2. 连 Mach 服务 + 调探针(reply 块异步回来,转主线程)。
        let conn = NSXPCConnection(machServiceName: SimpleZipAIAgentXPCNames.machService)
        conn.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            reply("XPC 连接出错:\(error.localizedDescription)")
        } as? SimpleZipAIAgentXPC
        guard let proxy else {
            reply("拿不到 XPC proxy。")
            conn.invalidate()
            return
        }
        proxy.probeModel { result in
            reply("agent 探针 → \(result)")
            conn.invalidate()
        }
    }
}
