//
//  RarBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import Foundation

/// RAR CLI 后端 —— 把所有「按用户偏好挑哪份 rar / 跑创建命令 / 管本地安装的 RARLAB 二进制」
/// 的逻辑收敛在一个 namespace 里。
///
/// 设计动机：跟 7-Zip / NativeZip / DiskImage 一起完成 Phase 4 的 backend 拆分 ——
/// 让 `ArchiveService` 只做 format → backend 路由，不持有任何具体后端的私有路径 / 进程语义。
///
/// 跟 7-Zip 的关键差别：
/// - 默认 **不** 内置 RARLAB 二进制（它是闭源 + LICENSE 要求用户接受才能分发），
///   bundled 候选只有「用户自己装的本地 RAR」（解压到 `~/Library/Application Support/SimpleZip/Tools/rar`）。
/// - 上层（Settings → 压缩 → RAR pane / 欢迎助手 → 后端步骤）提供 README + LICENSE 双 checkbox
///   的 review sheet，确认后才跑安装脚本 —— 这条流程在 SwiftUI 侧，本 backend 只提供
///   readme / license / installer 的 URL 入口。
enum RarBackend {

    // MARK: - 设备发现

    /// 按用户偏好（automatic / bundled / system）挑出当前应该用的 rar。
    /// 全部失败 → `ArchiveError.missingRarTool`。
    static func resolve() throws -> ResolvedRarTool {
        let candidates: [ResolvedRarTool]
        switch AppPreferences.rarBackend {
        case .automatic, .bundled:
            // automatic 和 bundled 都先看本地用户装的版本；找不到才往系统级回落。
            // 这跟 7-Zip 的策略不同 —— 7-Zip bundled 是 App Resources 内的二进制，永远存在；
            // RAR 的「bundled」对用户来说语义是「装到自己的 Application Support 目录」，
            // 没装时跟「自动」一样回落到系统级，体验更顺。
            candidates = localCandidates + systemCandidates
        case .system:
            candidates = systemCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingRarTool
    }

    static func toolPath() throws -> String {
        try resolve().path
    }

    static func isAvailable() -> Bool {
        (try? resolve()) != nil
    }

    // MARK: - 用户面元信息

    static func backendDescription() -> String {
        do {
            let tool = try resolve()
            return L10n.format("settings.rar.resolvedPath", tool.source.title, tool.path)
        } catch {
            return L10n.text("settings.rar.notFound")
        }
    }

    /// 跑 `rar`（无参数 = 打印 banner + 版本头）取第一行非空作为版本。
    /// rar 没有 `--version` 之类标准开关 —— banner 就是它的版本信息。
    static func version() async -> String {
        do {
            let tool = try resolve()
            do {
                let output = try await BackendProcessRunner.runAndCapture(tool.path, arguments: [])
                let firstLine = output
                    .split(separator: "\n")
                    .map(String.init)
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    ?? tool.path
                return L10n.format("settings.rar.resolvedVersion", tool.source.title, firstLine)
            } catch {
                return L10n.format("settings.rar.resolvedVersion", tool.source.title, tool.path)
            }
        } catch {
            return L10n.text("settings.rar.notFound")
        }
    }

    // MARK: - 本地安装管理

    /// 用户在「设置」/「欢迎助手」里点过「安装本地 RAR」后落盘的位置。
    /// nil 表示拿不到 Application Support 目录（极端情况下系统返回空），
    /// 调用方应当跟「没装」一样处理。
    static func localBackendURL() -> URL? {
        ArchiveService.applicationSupportDirectory()?.appendingPathComponent("Tools/rar")
    }

    static func hasLocalBackend() -> Bool {
        guard let url = localBackendURL() else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// 彻底清掉用户本地装的 RAR（rar 可执行 + 落盘的 license / readme 副本）。
    /// 单文件不存在不报错 —— 历史版本可能未落 license/readme，删 rar 主程序时容忍。
    static func deleteLocalBackend() throws {
        guard let toolsDirectory = ArchiveService.applicationSupportDirectory()?
            .appendingPathComponent("Tools", isDirectory: true) else {
            return
        }
        let fileManager = FileManager.default
        for name in ["rar", "rar-license.txt", "rar-readme.txt"] {
            let url = toolsDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - 安装资源入口（README / LICENSE / installer 脚本）

    /// 「在 Finder 中显示安装资源」按钮跳的目录。整个 App resourceURL 已经够用。
    static func installResourcesURL() -> URL? {
        Bundle.main.resourceURL
    }

    static func installReadmeURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-rar-install-readme", withExtension: "txt")
    }

    static func installLicenseURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-rar-license-notice", withExtension: "txt")
    }

    static func installerScriptURL() -> URL? {
        Bundle.main.url(forResource: "simplezip-install-rar-backend", withExtension: "sh")
    }

    // MARK: - 操作（创建 RAR）

    /// 用解析出来的 rar 二进制 + `rarCreateArguments` 拼出来的参数跑创建。
    /// 跟 `case .rar` 原本 ArchiveService 里的逻辑 1:1。
    /// list / extract / test 走 `SevenZipBackend` —— 7zz 早就支持 RAR，rar 命令行只用来「创建」。
    static func create(
        destination: URL,
        relativeNames: [String],
        options: ArchiveCreationOptions,
        currentDirectory: URL?,
        progressParser: ProgressOutputParser?,
        outputObserver: (@Sendable (String) -> Void)?,
        operationID: UUID?
    ) async throws {
        let tool = try toolPath()
        let arguments = try ArchiveService.rarCreateArguments(
            destination: destination,
            relativeNames: relativeNames,
            options: options
        )
        let inputStrategy: ProcessInputStrategy = options.password.isEmpty
            ? .none
            : .passwordPrompts(ArchiveService.passwordResponses(for: options))
        _ = try await BackendProcessRunner.runAndCapture(
            tool,
            arguments: arguments,
            currentDirectory: currentDirectory,
            progressParser: progressParser,
            inputStrategy: inputStrategy,
            outputObserver: outputObserver,
            operationID: operationID
        )
    }

    // MARK: - 候选路径

    /// 用户安装的本地 rar —— `~/Library/Application Support/SimpleZip/Tools/rar`。
    private static var localCandidates: [ResolvedRarTool] {
        ArchiveService.uniqueExistingCandidatePaths(
            [
                ArchiveService.applicationSupportDirectory()?
                    .appendingPathComponent("Tools/rar").path
            ].compactMap { $0 }
        ).map { ResolvedRarTool(path: $0, source: .local) }
    }

    /// 系统级 rar —— RARLAB 官方 .app / brew / $PATH 各种来源。
    private static var systemCandidates: [ResolvedRarTool] {
        ArchiveService.uniqueExistingCandidatePaths(
            [
                "/Applications/RAR.app/Contents/MacOS/RAR",
                "/Applications/RAR.app/Contents/MacOS/rar",
                "/Applications/WinRAR.app/Contents/MacOS/RAR",
                "/Applications/WinRAR.app/Contents/MacOS/rar",
                "/opt/homebrew/bin/rar",
                "/usr/local/bin/rar",
                ArchiveService.envPath(for: "rar")
            ].compactMap { $0 }
        ).map { ResolvedRarTool(path: $0, source: .system) }
    }
}

/// 跨上下文共享 —— Settings RAR pane、欢迎助手后端步骤、健康检查都用到。
/// path + source 一起放是为了 UI 能显示 "来自 SimpleZip 本地安装 / 系统"。
struct ResolvedRarTool {
    let path: String
    let source: RarToolSource
}

/// rar 来源分类 —— 决定用户面板里那行说明文字。
enum RarToolSource {
    case local
    case system

    var title: String {
        switch self {
        case .local:
            return L10n.text("settings.rar.source.local")
        case .system:
            return L10n.text("settings.rar.source.system")
        }
    }
}
