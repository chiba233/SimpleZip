//
//  main.swift
//  SimpleZip
//
//  自定义入口:CLI companion 复用主二进制 —— 以 `simplezip` 之名(PATH 符号链接)或
//  `--cli` 前缀被调用时走纯命令行路径,不起 NSApplication、不建窗口,跑完以退出码结束;
//  其余情况照常启动 SwiftUI App(@main 改由本文件接管,SimpleZipApp 不再标 @main)。
//  GUI 二进制名是大写 `SimpleZip`,判定区分大小写,Finder / LaunchServices 启动不受影响。
//

import AppKit
import SwiftUI

let processArguments = CommandLine.arguments
if CLIInvocation.isCLIInvocation(
    argv0: processArguments.first ?? "",
    firstArgument: processArguments.count > 1 ? processArguments[1] : nil
) {
    // CLI 是 async 流程(ArchiveService 入口在默认 MainActor 隔离下要主 actor 执行;
    // 同步阻塞主线程等结果会死锁)。Task 排上主执行器,跑完在任务里 exit。
    // 必须 RunLoop.main.run() 而非 dispatchMain():dispatch_main() 把真主线程停车,主队列
    // 任务改由「主队列语义的工作线程」执行 —— MainActor 满足,但 AppKit 按 pthread_main_np()
    // 校验,promptPassword 的 NSAlert 一实例化就抛 NSInternalInconsistencyException。
    // RunLoop.main.run() 让真主线程留在原地伺服主队列,口令小窗才能弹。
    Task { @MainActor in
        exit(await CLIRunner.run(arguments: processArguments))
    }
    RunLoop.main.run()
}
// 启动最早期清理:历史版本把归档清单缓存写进了主 UserDefaults domain,撑爆 CFPreferences 的 4 MB 单值上限后,
// 该 domain 的任何写都 fault + 反复整体重序列化,拖垮启动 —— App Intents 后台 helper 因此连接超时,Shortcuts
// 报「Couldn't communicate…」。缓存已改存独立文件,在 NSApplication 起来前把遗留 key 删掉,主 domain
// 立刻恢复小而快。
ArchiveListingCacheStore.purgeLegacyStandardStorage()
SimpleZipApp.main()
