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
        // `--config-selftest`:构造配置 → encode → decode → 比对后退出。命令行验 payload round-trip(坑 9 序列化
        // 正确),纯 Foundation、不依赖模型 / XPC,同步跑完即 exit。
        if CommandLine.arguments.contains("--config-selftest") {
            let original = AIAgentConfiguration(
                aiAssistantEnabled: true, aiSuggestionEnabled: false,
                indexingEnabled: true, contentPrereadEnabled: true, activityLevel: "balanced",
                silentBackgroundIndexEnabled: true,
                backgroundIndexIntervalHours: 24, maxBackgroundRunSeconds: 300)
            let data = original.encoded()
            if let back = AIAgentConfiguration.decoded(from: data), back == original {
                print("CONFIG SELFTEST OK: round-trip 一致,foregroundAIAllowed=\(back.foregroundAIAllowed),\(data.count) bytes")
            } else {
                print("CONFIG SELFTEST FAILED: round-trip 不一致")
            }
            exit(0)
        }
        // `--background-index`:**后台索引一轮**(launchd 周期拉起 agent 跑这个的本体;也供命令行直接验证数据通路)。
        // 读 App 同步的配置 + scope 白名单 → AIBackgroundIndexRun.scan(与 App 前台共用 Core 编排)→ 写回派生索引文件。
        // 纯同步元数据扫描(不调模型)→ 跑完直接 exit,无需 run loop。门控不过(opt-in 默认关等)则廉价 no-op 退出。
        // 用法:.../Contents/MacOS/SimpleZipAIAgent --background-index
        if CommandLine.arguments.contains("--background-index") {
            // --force:绕间隔自节流 + app/agent 前台锁让位(测试用;门控 / 红线仍生效)。
            let force = CommandLine.arguments.contains("--force")
            // async:烘焙要直调端上模型(异步)。A18:绝不阻塞主线程等,Task 跑完直接 exit,主线程跑 run loop 泵队列。
            Task {
                let summary = await AIAgentBackgroundIndex.runOnce(force: force, log: { line in
                    agentLog(line)   // stderr 滚动(Console / 终端可见)
                    print(line)      // stdout 滚动(命令行直接可见「正在 index / 烘焙 什么」)
                })
                // 每次被拉起都记一笔运行遥测(真扫 / 烘焙 / 跳过都算),供 App·DevTools 确认后台 agent 真跑过。
                AIAgentRunTelemetry.recordWake(outcome: summary.note, at: Date())
                agentLog("BACKGROUND INDEX → scopes=\(summary.scopesScanned) records=\(summary.recordsWritten) 烘焙=\(summary.bakedSummaries)+\(summary.bakedURLs) · \(summary.note)")
                print("scopes=\(summary.scopesScanned) records=\(summary.recordsWritten) baked=\(summary.bakedSummaries)+\(summary.bakedURLs) note=\(summary.note)")
                exit(0)
            }
            RunLoop.main.run()
        }
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
        // `--query <text>`:参数化**真实**生成 —— 把自然语言请求 → 归档搜索关键词后退出。命令行直接验证 agent 的
        // 真实(非写死)结构化生成能力,不依赖 XPC/GUI。用法:.../SimpleZipAIAgent --query "我记得有个预算表压缩在哪了"
        if let qIndex = CommandLine.arguments.firstIndex(of: "--query"), qIndex + 1 < CommandLine.arguments.count {
            let request = CommandLine.arguments[qIndex + 1]
            Task {
                let keyword = await AIAgentService.queryText(request)
                agentLog("DIRECT QUERY(\(request)) → \(keyword)")
                print(keyword)
                exit(0)
            }
            RunLoop.main.run()
        }
        // `--test-backend <归档路径>`:在 agent(独立)进程里跑一次 `ArchiveService.list`(真起 7zz),验证
        // **后端能在 agent 进程跑通**(A19:嵌入 helper 时 Bundle.main 解析到 app bundle → 找得到 Resources/Tools/7zz)。
        // 这是用户点名的坑(测试 / 哈希 / 列归档要跑后端)。用法:.../SimpleZipAIAgent --test-backend /path/to/x.zip
        if let tIndex = CommandLine.arguments.firstIndex(of: "--test-backend"), tIndex + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[tIndex + 1]
            Task {
                do {
                    let items = try await ArchiveService.list(URL(fileURLWithPath: path))
                    let line = "BACKEND OK · 7zz 在 agent 进程列出 \(items.count) 条:\(path)"
                    agentLog(line); print(line)
                } catch {
                    let line = "BACKEND FAIL · \(error)"
                    agentLog(line); print(line)
                }
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
