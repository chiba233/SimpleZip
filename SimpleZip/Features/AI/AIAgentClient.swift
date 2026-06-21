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

    /// 同 ReplyOnce,但承载 `Result<Data, Error>`(给通用 pass 生成 `generate` 用,连续逊 continuation 恰好 resume 一次)。
    private nonisolated final class SettleOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let body: (Result<Data, Error>) -> Void
        init(_ body: @escaping (Result<Data, Error>) -> Void) { self.body = body }
        func callAsFunction(_ result: Result<Data, Error>) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body(result) }
        }
    }

    /// 同 ReplyOnce,但承载 `Bool`(给轻量存活探测 `pingForegroundBackend` 用,超时 / 回复 / 连接失败三者竞态只结算一次)。
    private nonisolated final class BoolOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let body: (Bool) -> Void
        init(_ body: @escaping (Bool) -> Void) { self.body = body }
        func callAsFunction(_ value: Bool) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body(value) }
        }
    }

    /// 同 BoolOnce,但承载 `(Bool, String)?`(给模型可用性查询 `fetchModelAvailability` 用:超时/回复/连接失败只结算一次)。
    private nonisolated final class AvailabilityOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let body: ((Bool, String)?) -> Void
        init(_ body: @escaping ((Bool, String)?) -> Void) { self.body = body }
        func callAsFunction(_ value: (Bool, String)?) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body(value) }
        }
    }

    /// 把 non-Sendable 的 `NSXPCConnection` 装进 @unchecked Sendable 盒 —— 让超时 / 回调闭包捕获它而不触发 Swift
    /// 并发警告。XPC 连接本就跨线程用(超时在 global queue、回复在 XPC queue),`invalidate` 幂等,封箱传递是安全的。
    private nonisolated final class ConnectionBox: @unchecked Sendable {
        let connection: NSXPCConnection
        init(_ connection: NSXPCConnection) { self.connection = connection }
    }

    /// 通用 AI pass 生成的人话错误(经前台 XPC Service)。
    enum GenerateError: Error, LocalizedError {
        case generationFailed(String)
        case noProxy
        var errorDescription: String? {
            switch self {
            case .generationFailed(let m): return m
            case .noProxy: return "拿不到 XPC proxy"
            }
        }
    }

    /// 给探针的 `ReplyOnce` 挂一个**超时兜底**:到点仍没回 → 回超时人话(ReplyOnce 保证与真回复只结算一次,真回复
    /// 先到就忽略本超时)。dev 后台 LaunchAgent 的 SMAppService 注册 / probeModel 真模型生成可能很慢甚至卡死 → 加超时,
    /// DevTools 状态不再干卡在「正在连…」。真生成在 agent 进程继续(不取消,避免污染 FoundationModels transcript),只本端停等。
    private nonisolated static func scheduleProbeTimeout(_ reply: ReplyOnce, seconds: TimeInterval, label: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            reply("\(label)超时(\(Int(seconds))s 无响应)。dev 环境后台 LaunchAgent 走 SMAppService、从 DerivedData 跑常不稳;前台 XPC Service 通道是稳的。")
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
        scheduleProbeTimeout(reply, seconds: 25, label: "后台 LaunchAgent ")   // 含 SMAppService 注册,给足又不无限卡

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
        // ⚠️ A18:SMAppService unregister/register 是**同步阻塞**调用,等 launchd 响应时会冻住调用线程。
        // 绝不能在主线程跑(DevTools 按钮在主 actor 上),否则 dev 环境 register 卡 launchd 会假死整个 UI、触发
        // watchdog(实测 __sigsuspend_nocancel 主线程 park)。整段挪后台线程,结果经 ReplyOnce → 主线程回。
        DispatchQueue.global(qos: .userInitiated).async {
            let service = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.machService + ".plist")
            let needsRegister: Bool
            #if DEBUG
            // dev 失稳真因(codex 实测,非「DerivedData 跑不了」——toggle 后照样从 DerivedData 拉起):rebuild 后 helper
            // 签名变,但 BTM/SMAppService 缓存的旧记录 + LWCR(launch code requirement)陈旧 → launchd 报 `needs LWCR
            // update` + spawn failed(EX_CONFIG 78)。Login Items 手动开关会换 BTM uuid + 刷新 LWCR 才恢复;代码里
            // unregister 紧接 register 太快会撞「旧记录还没清完」的异步竞争。每个 App 启动首刀 unregister 后**轮询
            // status 到 .notRegistered(最多 ~3s)再 register**,确保旧记录真清掉、register 建一条带当前 LWCR 的新记录。
            if didRegisterDevAgentThisLaunch {
                needsRegister = service.status != .enabled
            } else {
                try? service.unregister()
                for _ in 0..<30 {                                  // 等 unregister 真生效(BTM 记录清除),最多 ~3s
                    if service.status == .notRegistered { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
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
                    dev 下 rebuild 后 BTM 缓存的 LWCR 可能陈旧(needs LWCR update / spawn failed)。可在 系统设置 → 通用 → 登录项 把本 app 的后台项关再开一次以刷新;或确认 helper 与 App 同签名身份(本地 SimpleZip Dev)。前台推理走 XPC Service 不受此影响。
                    """)
                    return
                }
            }
            // 连 Mach 服务 + 调探针。register 后 service 可能尚未 ready → invokeWithRetry 兜首次冷启动 race;
            // 后台首启要等 launchd 准备好刚 register 的 service → 比前台多给几次重试。
            invokeWithRetry(
                label: "后台 LaunchAgent ",
                makeConnection: { NSXPCConnection(machServiceName: SimpleZipAIAgentXPCNames.machService) },
                call: { proxy, done in proxy.probeModel { done("后台 LaunchAgent 探针 → \($0)") } },
                attemptsLeft: 5,
                reply: reply)
        }
    }

    // MARK: 前台 XPC Service 通道

    /// 走**前台 XPC Service 通道**跑一次模型探针:`NSXPCConnection(serviceName:)` 连内嵌 XPC Service ——
    /// App 连接即按需拉起,无 SMAppService 注册、不进 Login Items、**不受「允许在后台」开关 gate**。
    nonisolated static func runForegroundProbe(_ completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }
        scheduleProbeTimeout(reply, seconds: 25, label: "前台 XPC Service ")
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
        scheduleProbeTimeout(reply, seconds: 25, label: "前台 XPC Service 真实查询 ")
        invokeWithRetry(
            label: "前台 XPC Service ",
            makeConnection: { NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName) },
            call: { proxy, done in proxy.extractArchiveKeyword(fromRequest: request) { done("前台 XPC Service 真实查询 → \($0)") } },
            attemptsLeft: 3,
            reply: reply)
    }

    /// **DevTools 监视:被动查引擎 pass 调用统计**。经前台 XPC Service 调 `passStats`(不碰模型、瞬回),把引擎进程自
    /// 启动以来每种 pass 的 总数/成功/失败/最近时间·成败 格式化成可读人话回主线程常驻(可选中复制)。对照「真实查询」
    /// 是主动跑一个 pass,这条是被动观测「引擎到底跑过哪些 pass、成不成」—— 像 DevTools 其它管线那样的监视器。
    nonisolated static func queryPassStats(_ completion: @escaping @MainActor (String) -> Void) {
        let reply = ReplyOnce { message in Task { @MainActor in completion(message) } }
        scheduleProbeTimeout(reply, seconds: 5, label: "引擎 pass 统计 ")
        invokeWithRetry(
            label: "引擎 pass 统计 ",
            makeConnection: { NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName) },
            call: { proxy, done in proxy.passStats { done(Self.formatPassStats($0)) } },
            attemptsLeft: 3,
            reply: reply)
    }

    /// 把 `passStats` 回的 [AIPassStatEntry] JSON 格式化成可读人话(空则提示本进程还没跑过 pass)。
    private nonisolated static func formatPassStats(_ data: Data) -> String {
        guard let entries = try? JSONDecoder().decode([AIPassStatEntry].self, from: data), !entries.isEmpty else {
            return "引擎 pass 统计:暂无记录(本次前台 XPC Service 进程还没跑过任何 pass —— 触发一次 AI 功能后再查)。"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let totalCalls = entries.reduce(0) { $0 + $1.total }
        var lines = ["引擎 pass 统计(本次前台 XPC Service 进程自启动:\(entries.count) 种 pass、\(totalCalls) 次调用):"]
        for e in entries {
            var line = "· \(e.kind):\(e.total) 次(✅\(e.ok) / 🔴\(e.failed))"
            if let secs = e.lastEpochSeconds {
                line += " · 最近 \(fmt.string(from: Date(timeIntervalSince1970: secs)))"
                if let ok = e.lastOk { line += ok ? " ✅" : " 🔴" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 配置同步(坑 9:payload 带 schemaVersion)

    /// 从当前 App 状态构造配置 payload(主 actor 读 AppPreferences + 索引 store 的 AI 开关)。
    @MainActor static func currentConfiguration() -> AIAgentConfiguration {
        AIAgentConfiguration(
            aiAssistantEnabled: AppPreferences.aiAssistantEnabled,
            aiSuggestionEnabled: AppPreferences.aiSuggestionEnabled,
            indexingEnabled: AIBackgroundIndexStore.shared.indexingEnabled,
            contentPrereadEnabled: AIBackgroundIndexStore.shared.contentPrereadEnabled,
            activityLevel: AppPreferences.aiBackgroundActivityLevel.rawValue,
            silentBackgroundIndexEnabled: AppPreferences.aiBackgroundSilentIndexEnabled,
            backgroundIndexIntervalHours: AppPreferences.aiBackgroundIndexInterval.hours,
            maxBackgroundRunSeconds: AppPreferences.aiBackgroundMaxRunSeconds,
            languageName: AIReportAssistant.uiLanguageName)
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

    // MARK: 轻量存活探测(运行状态健康检查:测前台 XPC Service 连通性,**不跑模型**、有超时、瞬回)

    /// 连前台 XPC Service 调 `ping`(瞬回、不碰模型)→ 后端连得上回 true。**有超时**(默认 2.5s),连不上 / 超时回 false,
    /// 绝不卡(对照 probeModel 会跑 2-34s 真生成 → 状态检测「卡在检测中」的根因)。单次尝试 + 超时,不做重试风暴。
    nonisolated static func pingForegroundBackend(timeout: TimeInterval = 2.5) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let settle = BoolOnce { cont.resume(returning: $0) }
            let box = ConnectionBox(NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName))
            box.connection.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
            box.connection.resume()
            // 超时兜底:ping 该瞬回,但万一进程拉起慢 / 卡住,到点即判连不上(invalidate + false),不无限等。
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.connection.invalidate(); settle(false)
            }
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { _ in
                box.connection.invalidate(); settle(false)
            } as? SimpleZipAIAgentXPC
            guard let proxy else { box.connection.invalidate(); settle(false); return }
            proxy.ping { ok in box.connection.invalidate(); settle(ok) }
        }
    }

    /// 经前台 XPC Service 查**端上模型可用性**(给 `AIReportAssistant.isReady` / `unavailableReason` 缓存用 —— 主二进制
    /// 不再 import FoundationModels,可用性由引擎进程读 `SystemLanguageModel.availability` 回报)。回 `(available, reasonCode)`;
    /// 连不上 / 超时回 `nil`(调用方据此**不动缓存**、沿用上次已知值,不误判不可用)。**不碰模型**(只读可用性,瞬回)。
    nonisolated static func fetchModelAvailability(timeout: TimeInterval = 3.0) async -> (available: Bool, reasonCode: String)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String)?, Never>) in
            let settle = AvailabilityOnce { cont.resume(returning: $0) }
            let box = ConnectionBox(NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName))
            box.connection.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
            box.connection.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.connection.invalidate(); settle(nil)
            }
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { _ in
                box.connection.invalidate(); settle(nil)
            } as? SimpleZipAIAgentXPC
            guard let proxy else { box.connection.invalidate(); settle(nil); return }
            proxy.modelAvailability { available, reasonCode in
                box.connection.invalidate(); settle((available, reasonCode))
            }
        }
    }

    // MARK: 后台索引服务(周期 LaunchAgent)运行状态:注册态 + 注册/反注册 + 修复 —— 都不跑模型、不需 sudo

    /// 后台**周期索引 LaunchAgent**(`indexAgentPlistName`,跑 `--background-index`)的注册健康态。这是用户「静默
    /// 后台索引」真正的后台 worker(App 关闭时 launchd 按计划拉起跑一轮);**包装 `SMAppService.Status`** 让运行状态
    /// 检查不必 import ServiceManagement,且把「用户主动禁用」单独标出(`requiresApproval`)—— 那一档绝不能被自动重开。
    enum BackgroundAgentRegistration {
        /// 已注册并启用(launchd 会在 App 关闭时按计划拉起它跑后台索引)。
        case enabled
        /// 未注册:首次启用前、首次安装(此前无 BTM 记录),或改了 bundle id / plist label / 签名身份后旧记录已被清。
        case notRegistered
        /// 🔴 用户在 系统设置 → 通用 → 登录项 里把后台项关了。**绝不偷偷重新打开** —— 只引导用户去系统设置。
        case requiresApproval
        /// plist 在 app bundle 里找不到(构建问题),或系统报未知状态。
        case notFound
    }

    /// 读周期索引 LaunchAgent 的注册健康态。`SMAppService.status` 会查询 launchd / BTM,可能不瞬时 ——
    /// **off-main**(A18)读,经 continuation 回。
    nonisolated static func backgroundAgentRegistration() async -> BackgroundAgentRegistration {
        await withCheckedContinuation { (cont: CheckedContinuation<BackgroundAgentRegistration, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.indexAgentPlistName).status
                let mapped: BackgroundAgentRegistration
                switch status {
                case .enabled: mapped = .enabled
                case .notRegistered: mapped = .notRegistered
                case .requiresApproval: mapped = .requiresApproval
                case .notFound: mapped = .notFound
                @unknown default: mapped = .notFound
                }
                cont.resume(returning: mapped)
            }
        }
    }

    /// 周期索引 LaunchAgent 的 注册 / 反注册 / 修复结果(给「静默后台索引」开关、运行状态「修复」按钮、启动自检共用)。
    enum RepairOutcome {
        /// 操作成功(注册 / 反注册 / 重注册到位)。
        case repaired
        /// 🔴 用户已在登录项禁用 —— 没动它(不偷偷重开),需用户去系统设置手动开。
        case requiresApproval
        /// 操作失败(带人话原因)。
        case failed(String)
    }

    /// **按「静默后台索引」开关 注册 / 反注册 周期索引 LaunchAgent**(设置页 onChange 调)。开 → 注册(已是 enabled
    /// 即 no-op;`.requiresApproval` 直接返回、**不强注册**);关 → 反注册。register / unregister 同步阻塞 launchd
    /// (A18)→ 整段后台队列跑、经 continuation 回。**不需 sudo**(用户级 LaunchAgent)。
    @discardableResult
    nonisolated static func setBackgroundIndexEnabled(_ enabled: Bool) async -> RepairOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<RepairOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let service = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.indexAgentPlistName)
                if enabled {
                    if service.status == .requiresApproval { cont.resume(returning: .requiresApproval); return }
                    if service.status == .enabled { cont.resume(returning: .repaired); return }
                    do { try service.register(); cont.resume(returning: .repaired) }
                    catch { cont.resume(returning: .failed(error.localizedDescription)) }
                } else {
                    try? service.unregister()
                    cont.resume(returning: .repaired)
                }
            }
        }
    }

    /// **App 启动时确保周期索引 LaunchAgent 处于该有的状态**(仅在「静默后台索引」开启时调,见 AppDelegate):
    ///   - `.notRegistered`(首次 / 记录丢失)→ 注册;
    ///   - `.enabled` 但 **app 版本变了**(更新后 helper 二进制变 → 系统的启动校验可能陈旧 → launchd spawn 失败)→
    ///     重注册刷新(治用户点名的「发布包也罕见出现 stale BTM/LWCR」),并记下当前版本;
    ///   - `.requiresApproval`(用户在登录项关了)/ `.notFound`(构建问题)→ **不动**(尊重 / 无从修)。
    /// 版本号记 UserDefaults.standard(注册是按 app 版本的二进制绑定)。内部各调用已 off-main。
    nonisolated static func ensureBackgroundIndexRegistered(appVersion: String) async {
        let versionKey = "SimpleZip.ai.bgIndexAgent.registeredAppVersion"
        switch await backgroundAgentRegistration() {
        case .requiresApproval, .notFound:
            return
        case .notRegistered:
            if case .repaired = await setBackgroundIndexEnabled(true) {
                UserDefaults.standard.set(appVersion, forKey: versionKey)
            }
        case .enabled:
            if UserDefaults.standard.string(forKey: versionKey) != appVersion {
                _ = await repairBackgroundAgentRegistration()
                UserDefaults.standard.set(appVersion, forKey: versionKey)
            }
        }
    }

    /// **修复周期索引 LaunchAgent 注册**(运行状态「修复」按钮共用):清陈旧 BTM 记录后重新注册,刷新系统对它的启动
    /// 校验 —— 治会让 launchd 拒绝拉起(spawn failed)的陈旧:改 app / helper bundle id 或 plist label、换签名团队、
    /// 发布包罕见陈旧记录。**不跑模型、不需 sudo**(用户级 LaunchAgent)。
    /// 🔴 **绝不偷偷重启用用户已禁用的后台项**:进入时若 `.requiresApproval`(用户自己关了),直接返回、**不 unregister /
    /// register**。A18:同步阻塞 → 后台队列跑、经 continuation 回。
    nonisolated static func repairBackgroundAgentRegistration() async -> RepairOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<RepairOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let service = SMAppService.agent(plistName: SimpleZipAIAgentXPCNames.indexAgentPlistName)
                // 🔴 用户主动禁用 → 不偷偷重开。
                if service.status == .requiresApproval { cont.resume(returning: .requiresApproval); return }
                // 清陈旧注册(可能指向旧 bundle id / label / 签名身份)→ 轮询等真生效(BTM 记录清除,最多 ~3s)→
                // 重新注册,建一条带当前启动校验的新记录。
                try? service.unregister()
                for _ in 0..<30 {
                    if service.status == .notRegistered { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // unregister 后理论上不应变成 requiresApproval;若真发生也不强推(belt-and-suspenders)。
                if service.status == .requiresApproval { cont.resume(returning: .requiresApproval); return }
                do {
                    try service.register()
                    cont.resume(returning: .repaired)
                } catch {
                    cont.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// 打开 系统设置 → 通用 → 登录项(让用户自己重新启用被禁用的后台项)。封装在此,让运行状态检查不必 import
    /// ServiceManagement。
    @MainActor static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: 阶段3 通用 AI pass 生成(前台 XPC Service:整条 pass 在引擎进程跑,主二进制零模型推理)

    /// 类型化便捷封装:把 Codable 输入 DTO 经 XPC 发给引擎跑某个 pass,回 Codable 输出 DTO。界面语言在主 actor 读
    /// (引擎进程无 App locale)。失败抛 `GenerateError`(AI 禁用 / 模型失败 / 连接失败)→ 调用点 `try?` 退确定性兜底。
    @MainActor static func generatePass<In: Encodable, Out: Decodable>(
        kind: AIPassKind, input: In, as outputType: Out.Type
    ) async throws -> Out {
        let inputJSON = try JSONEncoder().encode(input)
        let languageName = AIReportAssistant.uiLanguageName
        let outputJSON = try await generate(kind: kind.rawValue, inputJSON: inputJSON, languageName: languageName)
        return try JSONDecoder().decode(Out.self, from: outputJSON)
    }

    /// **DevTools 监视:通用 `generate(kind:)` pass 契约自检**。对照写死的 `runForegroundQuery`(只测旧专用
    /// `extractArchiveKeyword` 方法),这里经**迁移后所有 pass 共用的通用契约**跑两种代表性 pass —— 散文
    /// (`reportText`)+ 结构化(`archiveFileKeyword`)—— 验证「报告解释 / 文件·归档建议 / NL 查询全部走同一条
    /// XPC 通用通路」。逐 pass 报 ok / 输出片段,人话汇总回主线程常驻(可选中复制)。失败不崩,显示错误人话。
    @MainActor static func runEnginePassSelfTest(_ completion: @escaping @MainActor (String) -> Void) {
        let lang = AIReportAssistant.uiLanguageName
        Task { @MainActor in
            var lines: [String] = ["前台 XPC Service · 通用 generate(kind:) 契约自检(界面语言:\(lang)):"]
            // ① 散文 pass(generateText 路径):reportText —— 所有报告解释 AI 的共用中心 pass。
            do {
                let text = try await generatePass(
                    kind: .reportText,
                    input: ReportTextInput(
                        instructions: "You are a terse assistant. Reply with ONE short sentence confirming a self-test ping was received.",
                        prompt: "Self-test ping from SimpleZip DevTools."),
                    as: AIPassTextOutput.self).text
                lines.append("✅ reportText(散文 pass)→ \(text.prefix(160))")
            } catch {
                lines.append("🔴 reportText 失败:\(error.localizedDescription)")
            }
            // ② 结构化 pass(generateStructured 路径):archiveFileKeyword —— @Generable 受约束输出。
            do {
                let keyword = try await generatePass(
                    kind: .archiveFileKeyword,
                    input: "I think my budget spreadsheet is zipped up somewhere",
                    as: String.self)
                lines.append("✅ archiveFileKeyword(结构化 pass)→ \"\(keyword)\"")
            } catch {
                lines.append("🔴 archiveFileKeyword 失败:\(error.localizedDescription)")
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    /// 经**前台 XPC Service 通道**调通用 `generate(kind:inputJSON:languageName:)`,async 桥接 + 冷启动重试。
    /// ok=true → 返回输出 DTO 的 JSON;ok=false → 抛 `GenerateError.generationFailed`(payload 是人话错误)。
    nonisolated static func generate(kind: String, inputJSON: Data, languageName: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            generateAttempt(kind: kind, inputJSON: inputJSON, languageName: languageName,
                            attemptsLeft: 3, settle: SettleOnce { cont.resume(with: $0) })
        }
    }

    private nonisolated static func generateAttempt(
        kind: String, inputJSON: Data, languageName: String, attemptsLeft: Int, settle: SettleOnce
    ) {
        let conn = NSXPCConnection(serviceName: SimpleZipAIAgentXPCNames.xpcServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: SimpleZipAIAgentXPC.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            conn.invalidate()
            if attemptsLeft > 1 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    generateAttempt(kind: kind, inputJSON: inputJSON, languageName: languageName,
                                    attemptsLeft: attemptsLeft - 1, settle: settle)
                }
            } else {
                settle(.failure(GenerateError.generationFailed("前台 XPC Service 连接出错(已重试):\(error.localizedDescription)")))
            }
        } as? SimpleZipAIAgentXPC
        guard let proxy else {
            conn.invalidate()
            settle(.failure(GenerateError.noProxy))
            return
        }
        proxy.generate(kind: kind, inputJSON: inputJSON, languageName: languageName) { output, ok in
            conn.invalidate()
            settle(ok ? .success(output)
                      : .failure(GenerateError.generationFailed(String(decoding: output, as: UTF8.self))))
        }
    }
}
