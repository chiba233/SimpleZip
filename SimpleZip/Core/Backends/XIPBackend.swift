//
//  XIPBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  `.xip` 的解压后端。
//
//  设计动机：xip 本体是 xar 容器（7zz 能秒列出 Content / Metadata 两个成员），但真正的
//  内容物（比如 Xcode-beta.app）藏在 Content 里，而且 xip 的核心价值是 **Apple 签名校验** ——
//  所以「解压整个 .xip」走系统自带的 `/usr/bin/xip --expand`：拿到真实载荷、顺带验签，
//  非 Apple 信任签名的 xip 会被系统工具拒绝，错误原样上抛给用户（不静默降级）。
//  浏览 / 测试 / 选条目解压仍走 7zz 的 xar 路径（ArchiveService 路由决定），
//  跟官方 7-Zip 对 xip 的行为一致。
//

import Foundation

enum XIPBackend {

    /// `/usr/bin/xip` 随 macOS 自带；保险起见仍然探测一下（万一在精简系统上跑）。
    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xip")
    }

    /// 解压整个 .xip 到 destination。`xip --expand` 固定展开到进程当前目录，
    /// 所以把子进程 cwd 指到 destination；可经 operationID 取消（杀子进程）。
    /// xip 不输出逐文件进度，进度状态只能给「不确定 + 当前文件名」。
    static func extract(
        _ archive: URL,
        to destination: URL,
        operationID: UUID?,
        progress: @escaping @Sendable (ArchiveProgressState) -> Void,
        outputObserver: (@Sendable (String) -> Void)?
    ) async throws {
        guard isAvailable() else {
            throw ArchiveError.commandFailed("xip tool not found at /usr/bin/xip")
        }
        progress(ArchiveProgressState(fraction: nil, currentFile: archive.lastPathComponent, statusText: nil))
        _ = try await BackendProcessRunner.runAndCapture(
            "/usr/bin/xip",
            arguments: ["--expand", archive.path],
            currentDirectory: destination,
            outputObserver: outputObserver,
            operationID: operationID,
            outputRetentionLimit: BackendProcessRunner.diagnosticsOutputRetentionLimit
        )
        progress(ArchiveProgressState(fraction: 1, currentFile: nil))
    }
}
