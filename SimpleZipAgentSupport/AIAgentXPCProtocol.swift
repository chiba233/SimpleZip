//
//  AIAgentXPCProtocol.swift
//  SimpleZipAIAgent
//
//  独立 AI 进程改造 · 阶段1 · App ↔ agent 的 XPC 接口契约。
//  形态 B:agent 是 SMAppService 注册的 LaunchAgent,vend 一个 Mach XPC 服务;App 用
//  NSXPCConnection(machServiceName:) 连它。launchd 可按计划拉起,App 关也能跑后台索引。
//
//  这是 @objc 协议(NSXPCConnection 硬要求)。@objc 协议按 Objective-C 运行时名跨模块匹配 ——
//  即使 App 把它编进 App 模块、agent 编进自己模块,只要 @objc 名一致就能对接。所有远程方法用
//  reply block 回传(XPC 单向调用 + 异步回调)。Step 0 只有一个探针方法,验证「端上 FoundationModels
//  能否在 agent 进程里跑」;跑通后再加配置 / 数据投影 / 诊断等粗粒度命令(坑 9:payload 带 schemaVersion)。
//

import Foundation

/// App ↔ SimpleZipAIAgent 的 XPC 远程接口。**App 与 agent 两个 target 都要编译到这个文件。**
///
/// `nonisolated`:App target 默认 MainActor 隔离(A18),不标会把协议方法染成 MainActor —— 但 XPC reply
/// 在任意队列回调、且 App 侧客户端 `AIAgentClient.runProbe` 是 nonisolated,在那调 `probeModel` 就报隔离错。
/// XPC 契约本就与 actor 无关,显式 nonisolated 让两个 target 编出来一致(agent target 本就 nonisolated,无害)。
@objc public protocol SimpleZipAIAgentXPC {
    /// **轻量存活探测**:立刻回 true,**不跑模型**。给「运行状态」健康检查测后端连通性用 —— probeModel 会跑真模型生成
    /// (2-34s、可能卡 guardrail),拿它做状态检测会「卡在检测中」;ping 只验「XPC 进程拉得起、连得上」,瞬回。
    nonisolated func ping(reply: @escaping (Bool) -> Void)

    /// **端上模型可用性查询**(给主 app 的 `isReady` / `unavailableReason` 缓存用 —— 主二进制不再 import
    /// FoundationModels,改由引擎进程读 `SystemLanguageModel.availability` 回报)。reply `(available, reasonCode)`:
    /// reasonCode ∈ {`""` 可用, `"deviceNotEligible"`, `"notEnabled"`, `"modelNotReady"`, `"osTooOld"`},App 据 code
    /// 映 L10n。**不碰生成、瞬回**(只读可用性,非推理)。
    nonisolated func modelAvailability(reply: @escaping (Bool, String) -> Void)

    /// 在 agent 进程里试跑一次端上模型最小生成,回传人话结果(成功+样本 / 不可用原因 / OS 太老)。
    nonisolated func probeModel(reply: @escaping (String) -> Void)

    /// 把任意自然语言请求转发给 agent 跑**真实**结构化生成,回归档搜索关键词(或人话错误)。probeModel 是写死
    /// 自检;这个接受**真实输入** —— 「真生成迁 agent」的 XPC 数据流(App→agent 真实请求→agent 生成→回结果)。
    nonisolated func extractArchiveKeyword(fromRequest request: String, reply: @escaping (String) -> Void)

    /// App → agent **配置同步**(坑 9):payload 是 AIAgentConfiguration 的 JSON Data。agent 解码后存储、据此门控
    /// (红线:主开关关 = 不生成),reply 回 agent 支持的 schemaVersion(解码失败回 -1,供 App 协商 / 降级)。
    nonisolated func syncConfiguration(_ payload: Data, reply: @escaping (Int) -> Void)

    /// 阶段3 **通用 AI pass 生成**:把一整条模型 pass(拼 prompt + 调模型 + 解析)放进引擎(只在 agent/XPC 进程)。
    /// `kind` = AIPassKind.rawValue,`inputJSON` = 该 pass 的 Codable 输入 DTO,`languageName` = 界面语言(引擎进程
    /// 无 App locale,由 App 传)。reply `(outputJSON, ok)`:ok=true 时 outputJSON 是输出 DTO;ok=false 时是
    /// UTF-8 人话错误(AI 禁用 / 未知 kind / 模型失败)。红线:主/子开关关 → ok=false「AI 已禁用」。
    nonisolated func generate(kind: String, inputJSON: Data, languageName: String,
                              reply: @escaping (Data, Bool) -> Void)

    /// **DevTools 监视**:回引擎进程自启动以来每个 pass kind 的调用统计 JSON([AIPassStatEntry]:总数 / 成功 / 失败 /
    /// 最近一次时间·成败)。供 DevTools 像观测其它管线一样被动看「引擎跑了哪些 pass、多少次、成不成」。不碰模型、瞬回。
    nonisolated func passStats(reply: @escaping (Data) -> Void)
}

/// App 与 agent / XPC Service 约定的常量。两条投递通道各一个名字:
///   - `machService`:**LaunchAgent 通道**的 Mach service 名,必须和 LaunchAgent plist 的 `MachServices`
///     key 一致;App 用 `NSXPCConnection(machServiceName:)` 连(后台,Login Items 可见、受门控)。
///   - `xpcServiceName`:**前台 XPC Service 通道**的服务名 —— 即内嵌 XPC Service 的 **CFBundleIdentifier**;
///     App 用 `NSXPCConnection(serviceName:)` 连(App 私有按需、随 App 活、不进 Login Items、不受门控)。
/// **按构建配置命名空间隔离**:Debug 用 `.dev.*`,Release 用正式 `.*`,让自签 dev 版与正式版(Developer ID)
/// 可共存、互不撞 SMAppService/launchd/XPC(本文件同时编进 app / agent / XPC Service → 三边 #if DEBUG
/// 一致,值天然对齐)。
public enum SimpleZipAIAgentXPCNames {
    // `nonisolated`:App target 默认 MainActor 隔离会把这些常量染成 MainActor-isolated,而读它们的
    // App 侧客户端是 nonisolated。显式 nonisolated 让常量在三个 target 一致可读。
    #if DEBUG
    public nonisolated static let machService = "yumeka.SimpleZip-in-mac.dev.aiagent"
    public nonisolated static let xpcServiceName = "yumeka.SimpleZip-in-mac.dev.aixpc"
    #else
    public nonisolated static let machService = "yumeka.SimpleZip-in-mac.aiagent"
    public nonisolated static let xpcServiceName = "yumeka.SimpleZip-in-mac.aixpc"
    #endif

    /// **周期后台索引 LaunchAgent** 的 plist 名(`SMAppService.agent(plistName:)` 用)。它跑 `--background-index`
    /// (StartInterval 周期拉起、跑一轮即退),是用户「静默后台索引」真正的后台 worker —— 区别于 `machService` 那个
    /// 按需 Mach listener(只给 DevTools 探针 / App→agent Mach 用)。文件名 = `<machService>.index.plist`,dev/prod
    /// 随 machService 天然隔离(plist 实体见 SimpleZipAgentSupport/*.aiagent.index.plist,Label 同此去掉 .plist)。
    public nonisolated static var indexAgentPlistName: String { machService + ".index.plist" }
}
