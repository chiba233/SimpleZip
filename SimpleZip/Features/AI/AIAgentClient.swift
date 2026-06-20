//
//  AIAgentClient.swift
//  SimpleZip
//
//  独立 AI 进程改造 · 阶段1 · App 侧连 AI 子进程的最小客户端 —— **两条投递通道**:
//    ① 后台 LaunchAgent 通道(runBackgroundProbe):SMAppService 注册 LaunchAgent + 连约定 Mach 服务。
//       App 关也能被 launchd 周期拉起做后台索引;在 Login Items 可见、受「允许在后台」开关门控。
//    ② 前台 XPC Service 通道(runForegroundProbe / runForegroundQuery):连内嵌 XPC Service(serviceName =
//       其 CFBundleIdentifier),App 连接即按需拉起、随 App 生命周期、不进 Login Items、不受该开关 gate。
//  实测:用户在 Login Items 关掉「允许在后台」会让 LaunchAgent 一切启动被拒(连前台 on-demand 唤醒也拒),
//  所以前台推理走 XPC Service 通道兜底,后台索引仍走 LaunchAgent。跑通后再扩成完整 client facade(配置同步 /
//  数据投影 / 诊断,坑 9 payload 带 schemaVersion)。后台定时索引的开 / 关 + 频率由 Settings → AI 驱动。
//
//  ⚠️ 冷启动 race(实测:首次「通信出错」、重试就好):首次连接时 LaunchAgent `register` 后 service 还没 ready /
//  XPC Service 进程刚被 launchd 拉起,连接级 errorHandler 会先触发。统一走 `invokeWithRetry` —— 连接级失败短
//  延迟后重连重试几次,`ReplyOnce` 保证最终 completion 恰好回一次(避免 errorHandler 与远程 reply 的竞态重复)。
//

import Foundation
import ServiceManagement

enum AIAgentClient {
    #if DEBUG
    /// DEBUG:每个 App 启动只重注册一次 dev LaunchAgent(自愈 rebuild 后的 LWCR 失配);之后同进程内不再每次重注册,
    /// 避免每次点探针都吃 register 的异步准备延迟 —— 那正是「经常要重试才拉起」的来源。nonisolated(unsafe):仅
    /// DevTools 主线程串行访问。
    nonisolated(unsafe) private static var didRegisterDevAgentThisLaunch = false
    #endif

    /// 保证最终 completion 恰好触发一次。重试期间的连接级失败不算「最终回」—— 只有成功结果或重试耗尽才 fire。
    private nonisolated final class ReplyOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let body: (String) -> Void
        init(_ body: @escaping (String) -> Void) { self.body = body }
        func callAsFunction(_ message: String) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body(message) }
        }
    }

    /// 建连接 + 调用一次远程方法,**连接级失败自动重连重试**(冷启动 race)。每次失败短延迟 0.5s 后换新连接重试,
    /// `attemptsLeft` 耗尽才把错误回出。成功 / 最终失败都经 `ReplyOnce`,确保 completion 不重复。
    private nonisolated static func invokeWithRetry(
        label: String,
        makeConnection: @escaping () -> NSXPCConnection,
        call: @escaping (SimpleZipAIAgentXPC, @escaping (String) -> Void) -> Void,
        attemptsLeft: Int,
        reply: ReplyOnce
    ) {
        let conn = makeConnection()
        conn.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            conn.invalidate()
            if attemptsLeft > 1 {
                // 进程刚拉起 / service 没立刻 ready —— 给它一点时间,换新连接重试。
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    invokeWithRetry(label: label, makeConnection: makeConnection, call: call,
                                    attemptsLeft: attemptsLeft - 1, reply: reply)
                }
            } else {
                reply("\(label)连接出错(已重试仍失败):\(error.localizedDescription)")
            }
        } as? SimpleZipAIAgentXPC
        guard let proxy else {
            conn.invalidate()
            reply("\(label)拿不到 XPC proxy。")
            return
        }
        call(proxy) { result in
            reply(result)
            conn.invalidate()
        }
    }

    // MARK: 后台 LaunchAgent 通道

    /// 走**后台 LaunchAgent 通道**跑一次模型探针:注册 LaunchAgent(SMAppService)+ 连约定 Mach 服务 + 调探针;
    /// 结果(人话)在主线程回传(供 DevTools 显示)。这条通道在 Login Items 可见、受「允许在后台」开关门控。
    nonisolated static func runBackgroundProbe(_ completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }

        guard #available(macOS 13.0, *) else {
            reply("macOS < 13,SMAppService 不可用。")
            return
        }
        // 1. 注册 LaunchAgent。register() 可能要求 helper 与 App 同签名身份、且 App 不在 DerivedData 而在
        //    /Applications —— 失败把人话原因回传,不崩。plistName 跟 machService 走构建配置:Debug → .dev.aiagent.plist。
        //
        // ⚠️ dev「重建不重注册」坑(实测 `job state = spawn failed`、`needs LWCR update`):每次 rebuild,agent 二进制 +
        // 签名都变,但旧注册缓存的**代码要求(LWCR)/程序路径**不刷新 → launchd 拿旧 LWCR 校验新二进制失配 → spawn 失败。
        // 光「status != .enabled 才注册」永远只注册第一次。**DEBUG 下先 unregister 清陈旧注册、再强制 register 当前构建**,
        // 让 dev 探针跨 rebuild / 改名自愈;Release 不反复重建,保持「未注册才注册」。
        let service = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.machService + ".plist")
        let needsRegister: Bool
        #if DEBUG
        // 每个 App 启动只 unregister+register 一次(首刀自愈 rebuild 后的 LWCR 失配);之后同进程内直接连,不再每次
        // 点探针都吃 register 的异步准备延迟。rebuild→重启 App 后的首刀仍会重注册(必要的自愈)。
        if didRegisterDevAgentThisLaunch {
            needsRegister = service.status != .enabled
        } else {
            try? service.unregister()
            didRegisterDevAgentThisLaunch = true
            needsRegister = true
        }
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
        // 2. 连 Mach 服务 + 调探针。register 后 service 可能尚未 ready → invokeWithRetry 兜首次冷启动 race。
        // 后台首启可能要等 launchd 准备好刚 register 的 service → 比前台多给几次重试,容忍冷启动准备延迟。
        invokeWithRetry(
            label: "后台 LaunchAgent ",
            makeConnection: { NSXPCConnection(machServiceName: SimpleZipAIAgentXPCNames.machService) },
            call: { proxy, done in proxy.probeModel { done("后台 LaunchAgent 探针 → \($0)") } },
            attemptsLeft: 5,
            reply: reply)
    }

    // MARK: 前台 XPC Service 通道

    /// 走**前台 XPC Service 通道**跑一次模型探针:`NSXPCConnection(serviceName:)` 连内嵌 XPC Service ——
    /// App 连接即按需拉起,无 SMAppService 注册、不进 Login Items、**不受「允许在后台」开关 gate**。
    nonisolated static func runForegroundProbe(_ completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }
        invokeWithRetry(
            label: "前台 XPC Service ",
            makeConnection: { NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName) },
            call: { proxy, done in proxy.probeModel { done("前台 XPC Service 探针 → \($0)") } },
            attemptsLeft: 3,
            reply: reply)
    }

    /// 经**前台 XPC Service 通道**把真实请求转发给 agent 跑结构化生成,回搜索关键词(或人话错误)。
    /// 对照 runForegroundProbe(写死自检),这个发**真实输入** —— 验证 App→agent 的真实查询数据流。
    nonisolated static func runForegroundQuery(_ request: String, completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }
        invokeWithRetry(
            label: "前台 XPC Service ",
            makeConnection: { NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName) },
            call: { proxy, done in proxy.extractArchiveKeyword(fromRequest: request) { done("前台 XPC Service 真实查询 → \($0)") } },
            attemptsLeft: 3,
            reply: reply)
    }

    // MARK: 配置同步(坑 9:payload 带 schemaVersion)

    /// 从当前 App 状态构造配置 payload(主 actor 读 AppPreferences + 索引 store 的 AI 开关)。
    @MainActor static func currentConfiguration() -> AIAgentConfiguration {
        AIAgentConfiguration(
            aiAssistantEnabled: AppPreferences.aiAssistantEnabled,
            aiSuggestionEnabled: AppPreferences.aiSuggestionEnabled,
            indexingEnabled: AIBackgroundIndexStore.shared.indexingEnabled,
            contentPrereadEnabled: AIBackgroundIndexStore.shared.contentPrereadEnabled,
            activityLevel: AppPreferences.aiBackgroundActivityLevel.rawValue)
    }

    /// 把当前配置**持久化到文件**(不碰 agent 进程)。让任何 agent 进程启动都能 loadPersisted 读到 —— App 启动 /
    /// 设置页出现时调,确保 App 关后被 launchd 拉起的后台 agent 也有红线状态。
    @MainActor static func persistConfiguration() {
        currentConfiguration().persist()
    }

    /// **配置同步默认行为**:持久化文件 + 推送给当前活着的 agent(经前台 XPC Service,best-effort)。AI 设置一变就调 ——
    /// 活着的 agent 立即按新配置门控(主/子开关关 → 拒生成),App 关后由持久化文件兜底。不需要用户手动同步。
    @MainActor static func publishConfiguration() {
        let config = currentConfiguration()
        config.persist()
        syncConfiguration(config) { _ in }   // 推送结果忽略:文件已落盘,推送只为即时生效
    }

    /// 经**前台 XPC Service 通道**把配置 payload 同步给 agent,回协商结果(agent 支持的 schemaVersion / 解码拒绝)。
    /// 同步后 agent 据此门控:`aiAssistantEnabled && aiSuggestionEnabled == false` → agent 拒绝前台生成。
    nonisolated static func syncConfiguration(_ config: AIAgentConfiguration,
                                              completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }
        let payload = config.encoded()
        invokeWithRetry(
            label: "前台 XPC Service 配置同步 ",
            makeConnection: { NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName) },
            call: { proxy, done in
                proxy.syncConfiguration(payload) { agentSchemaVersion in
                    if agentSchemaVersion < 0 {
                        done("配置同步失败:agent 解码拒绝(schema 不兼容)")
                    } else {
                        done("配置已同步 → agent schemaVer=\(agentSchemaVersion)(本地 v\(AIAgentConfiguration.currentSchemaVersion));主开关=\(config.aiAssistantEnabled) 建议=\(config.aiSuggestionEnabled) 索引=\(config.indexingEnabled) 预读=\(config.contentPrereadEnabled)")
                    }
                }
            },
            attemptsLeft: 3,
            reply: reply)
    }
}
