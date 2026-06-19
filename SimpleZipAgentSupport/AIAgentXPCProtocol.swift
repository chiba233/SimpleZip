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
    /// 在 agent 进程里试跑一次端上模型最小生成,回传人话结果(成功+样本 / 不可用原因 / OS 太老)。
    nonisolated func probeModel(reply: @escaping (String) -> Void)
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
}
