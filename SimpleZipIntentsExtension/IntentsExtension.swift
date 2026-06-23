//
//  IntentsExtension.swift
//  SimpleZipIntentsExtension
//
//  App Intents Extension 入口。Shortcuts / Siri 运行本扩展里声明的 intent 时,系统在**这个轻量扩展进程**里
//  跑 perform(),**不拉起完整 SimpleZip UI app** —— 这正是「Couldn't communicate with a helper application」
//  的根治:完整 app 启动(窗口状态恢复 + 一堆 UI XPC)太重,赶不上 App Intents 的连接窗口而超时(4101)。
//
//  扩展**沙箱化**(macOS 26 强制 App Intents 扩展沙箱化才注册;见 .entitlements),可读宿主 app 内置的 7zz
//  (经 SIMPLEZIP_7ZZ_PATH 钩子定位)。扩展里的 intent 复用 SimpleZip/Core(ArchiveService 等),不碰 app
//  target 的 UI / TaskCenter。
//

import AppIntents
// `@main` 的 AppIntentsExtension 静态 `main()` 由 ExtensionFoundation 提供 —— 部分 SDK 下 `import AppIntents`
// 不自动带入,必须显式导入,否则报「Cannot use static method 'main()' here; 'ExtensionFoundation' was not imported」。
import ExtensionFoundation

@main
struct SimpleZipIntentsExtension: AppIntentsExtension {
}
