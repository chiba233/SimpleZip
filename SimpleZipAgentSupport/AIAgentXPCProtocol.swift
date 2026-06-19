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
@objc public protocol SimpleZipAIAgentXPC {
    /// 在 agent 进程里试跑一次端上模型最小生成,回传人话结果(成功+样本 / 不可用原因 / OS 太老)。
    func probeModel(reply: @escaping (String) -> Void)
}

/// App 与 agent 约定的常量。Mach service 名必须和 LaunchAgent plist 的 `MachServices` key 一致。
/// **按构建配置命名空间隔离**:Debug 用 `.dev.*`,Release 用正式 `.*`,让自签 dev 版与正式版(Developer ID)
/// 可共存、互不撞 SMAppService/launchd(本文件同时编进 app 与 agent → 两边 #if DEBUG 一致,值天然对齐)。
public enum SimpleZipAIAgentXPCNames {
    #if DEBUG
    public static let machService = "yumeka.SimpleZip-in-mac.dev.aiagent"
    #else
    public static let machService = "yumeka.SimpleZip-in-mac.aiagent"
    #endif
}
