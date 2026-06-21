//
//  ArchiveBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// 协议化 4 个 backend 的「读」操作 —— `list` 和 `test` 在所有 backend 上签名一致，
/// 让 `ArchiveService.list` / `.test` 收成一行 router：拿到 backend 类型 → 直接调静态方法。
///
/// 为什么 `extract` / `create` 不进协议：
/// - NativeZipBackend.extract 需要 `zipDecryptionMethod`，决定先用 macOS 还是 7zz；
/// - SevenZipBackend.extract 需要 `pathMode`（`x` vs `e`）；
/// - DiskImageBackend.extract 没有覆盖行为 / 进度，签名最简；
/// - 7zz 的「创建」有 3 个变种（`createZip` / `createSevenZip` / `createSingleFileCompressed`），
///   NativeZip 的「创建」也有 3 个（`createTar` / `createTarGzip` / `createZipFallback`），RAR 只有 1 个。
///   强行塞进协议得做巨大的「kitchen sink options」类型，反而比现在的 switch 难维护。
/// 留两个动作进协议是当前最划算的边界 —— 读路径已经统一参数，写路径让 case 自己挑。
protocol ArchiveBackend {
    /// 列出压缩包条目。`password` 为空 = 无密码（backend 不需要密码时可忽略）。
    /// `operationID` 让长任务面板能取消正在跑的命令。
    /// nonisolated:list 是纯子进程 + 解析(无 MainActor 状态),声明成 nonisolated 让 `ArchiveService.list`
    /// 经协议存在体调它时整条链都不被弹回主线程(大归档解析冻死 UI 的根因)。
    nonisolated static func list(_ archive: URL, password: String, operationID: UUID?) async throws -> [ArchiveItem]

    /// 跑完整性测试。非零退出码 → 抛 `ArchiveError`。
    /// `outputObserver` 把后端命令输出实时喂给「详情」面板（之前漏传 → 测试详情永远「等待命令输出」）。
    nonisolated static func test(_ archive: URL, operationID: UUID?, outputObserver: (@Sendable (String) -> Void)?) async throws
}

// MARK: - Backend conformances

extension SevenZipBackend: ArchiveBackend {
    // 自己的 `list(_:password:operationID:)` 和 `test(_:operationID:)` 已经跟协议签名一致，
    // 这里空 extension 即可宣告 conformance。
}

extension NativeZipBackend: ArchiveBackend {
    // 自己的 `list(_:password:operationID:)` 和 `test(_:operationID:outputObserver:)` 已经跟
    // 协议签名一致，空 extension 宣告 conformance 即可。
}

extension DiskImageBackend: ArchiveBackend {
    /// DMG 没有 password / operationID 概念，wrapper 吞掉两个参数。
    nonisolated static func list(_ archive: URL, password: String, operationID: UUID?) async throws -> [ArchiveItem] {
        try await list(archive)
    }

    /// 同上，操作 ID 在 DMG 流程中没有取消语义；DMG 校验也没有可流式展示的命令输出，吞掉 outputObserver。
    nonisolated static func test(_ archive: URL, operationID: UUID?, outputObserver: (@Sendable (String) -> Void)?) async throws {
        try await test(archive)
    }
}
