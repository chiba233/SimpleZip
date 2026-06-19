//
//  AIAgentClient.swift
//  SimpleZip
//
//  独立 AI 进程改造 · 阶段1 · App 侧连 AI 子进程的最小客户端 —— **两条投递通道**:
//    ① 后台 LaunchAgent 通道(runBackgroundProbe):SMAppService 注册 LaunchAgent + 连约定 Mach 服务。
//       App 关也能被 launchd 周期拉起做后台索引;在 Login Items 可见、受「允许在后台」开关门控。
//    ② 前台 XPC Service 通道(runForegroundProbe):连内嵌 XPC Service(serviceName = 其 CFBundleIdentifier),
//       App 连接即按需拉起、随 App 生命周期、不进 Login Items、不受该开关 gate —— 前台按需推理的稳妥通道。
//  实测:用户在 Login Items 关掉「允许在后台」会让 LaunchAgent 一切启动被拒(连前台 on-demand 唤醒也拒),
//  所以前台推理走 XPC Service 通道兜底,后台索引仍走 LaunchAgent。两个方法目前都只跑 probeModel(供 DevTools
//  分别验证两条通道);跑通后再扩成完整 client facade(配置同步 / 数据投影 / 诊断,坑 9 payload 带 schemaVersion)。
//  后台定时索引的开 / 关 + 频率由 Settings → AI 驱动,不在这写死。
//

import Foundation
import ServiceManagement

enum AIAgentClient {
    // MARK: 后台 LaunchAgent 通道

    /// 走**后台 LaunchAgent 通道**跑一次模型探针:注册 LaunchAgent(SMAppService)+ 连约定 Mach 服务 + 调探针;
    /// 结果(人话)在主线程回传(供 DevTools 显示)。这条通道在 Login Items 可见、受「允许在后台」开关门控。
    nonisolated static func runBackgroundProbe(_ completion: @escaping @MainActor (String) -> Void) {
        func reply(_ message: String) { Task { @MainActor in completion(message) } }

        guard #available(macOS 13.0, *) else {
            reply("macOS < 13,SMAppService 不可用。")
            return
        }
        // 1. 注册 LaunchAgent。register() 可能要求 helper 与 App 同签名身份、且 App 不在 DerivedData 而在
        //    /Applications —— 失败把人话原因回传,不崩。plistName 跟 machService 走构建配置:Debug → .dev.aiagent.plist。
        //
        // ⚠️ dev「重建不重注册」坑(实测 `job state = spawn failed`、`needs LWCR update`):每次 rebuild,agent 二进制 +
        // 签名都变,但旧注册缓存的**代码要求(LWCR)/程序路径**不刷新 → launchd 拿旧 LWCR 校验新二进制失配 → spawn 失败、
        // agent 起不来、XPC 无响应。光「status != .enabled 才注册」永远只注册第一次。**DEBUG 下先 unregister 清陈旧注册、
        // 再强制 register 当前构建**,让 dev 探针跨 rebuild / 改名自愈;Release 不反复重建,保持「未注册才注册」。
        let service = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.machService + ".plist")
        let needsRegister: Bool
        #if DEBUG
        try? service.unregister()
        needsRegister = true
        #else
        needsRegister = service.status != .enabled
        #endif
        if needsRegister {
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
            reply("后台 LaunchAgent XPC 连接出错:\(error.localizedDescription)")
        } as? SimpleZipAIAgentXPC
        guard let proxy else {
            reply("拿不到后台 LaunchAgent XPC proxy。")
            conn.invalidate()
            return
        }
        proxy.probeModel { result in
            reply("后台 LaunchAgent 探针 → \(result)")
            conn.invalidate()
        }
    }

    // MARK: 前台 XPC Service 通道

    /// 走**前台 XPC Service 通道**跑一次模型探针:`NSXPCConnection(serviceName:)` 连内嵌 XPC Service ——
    /// App 连接即按需拉起,无 SMAppService 注册、不进 Login Items、**不受「允许在后台」开关 gate**。
    /// 结果(人话)在主线程回传(供 DevTools 显示)。
    nonisolated static func runForegroundProbe(_ completion: @escaping @MainActor (String) -> Void) {
        func reply(_ message: String) { Task { @MainActor in completion(message) } }

        // serviceName = XPC Service 的 CFBundleIdentifier;App 从自身 bundle 的 Contents/XPCServices/ 里按 id 找 .xpc。
        // 无需注册、无需轮询 status:连接建立即由 launchd 按需拉起该 .xpc,随 App 生命周期。
        let conn = NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            reply("""
            前台 XPC Service 连接出错:\(error.localizedDescription)
            (serviceName=\(SimpleZipAIAgentXPCNames.xpcServiceName);需 .xpc 已嵌入 App/Contents/XPCServices 且签名一致)
            """)
        } as? SimpleZipAIAgentXPC
        guard let proxy else {
            reply("拿不到前台 XPC Service proxy。")
            conn.invalidate()
            return
        }
        proxy.probeModel { result in
            reply("前台 XPC Service 探针 → \(result)")
            conn.invalidate()
        }
    }
}
