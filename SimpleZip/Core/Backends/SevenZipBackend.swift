//
//  SevenZipBackend.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 7-Zip CLI 后端的「设备发现 + 元信息查询」层。
///
/// 设计动机：ArchiveService 之前把「按用户偏好挑 bundled / system 7zz」「跑 `-version`」
/// 「拼成给用户看的描述串」这套逻辑跟具体的 list / extract / test / benchmark 实现搅在一起，
/// 加起来超过 100 行。把发现 + 元信息这一层先独立成 backend，让上层（设置面板的
/// SevenZipBackendSection、HealthChecker、DiagnosticsCopier）可以直接调，
/// 不再绕 ArchiveService。
///
/// 操作层（具体的 list / extract / test / benchmark / 创建参数构造）目前仍由 ArchiveService 持有 ——
/// 这是 Phase 4 step 3a。step 3b 会把那些动作也搬过来。
enum SevenZipBackend {

    // MARK: - 设备发现

    /// 解析当前应该用哪份 7zz —— 按用户偏好（automatic / bundled / system）依次找候选路径，
    /// 取第一个 `isExecutableFile` 的。全部失败 → 抛 `ArchiveError.missingSevenZip`。
    static func resolve() throws -> ResolvedSevenZipTool {
        let candidates: [ResolvedSevenZipTool]
        switch AppPreferences.sevenZipBackend {
        case .automatic:
            candidates = bundledCandidates + systemCandidates
        case .bundled:
            candidates = bundledCandidates
        case .system:
            candidates = systemCandidates
        }

        if let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return tool
        }
        throw ArchiveError.missingSevenZip
    }

    /// 拿单纯的可执行路径，给 `Process.executableURL` 用。
    static func toolPath() throws -> String {
        try resolve().path
    }

    /// 仅判定可用与否（不要错误信息）。给 Settings 灰按钮、HealthChecker 等用。
    static func isAvailable() -> Bool {
        (try? resolve()) != nil
    }

    // MARK: - 用户面元信息

    /// 「来源 + 路径」一行 —— 在 Settings → Archive → 7-Zip section 和 Health 面板里显示。
    static func backendDescription() -> String {
        do {
            let tool = try resolve()
            return L10n.format("settings.7zip.resolvedPath", tool.source.title, tool.path)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    /// 跑 `7zz i` 取第一行版本字符串。找不到 7zz 直接返回 notFound。
    /// 异步 —— 实际启动子进程，等输出。
    static func version() async -> String {
        do {
            let tool = try resolve()
            let output = try await BackendProcessRunner.runAndCapture(tool.path, arguments: ["i"])
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? output
            return L10n.format("settings.7zip.resolvedVersion", tool.source.title, firstLine.isEmpty ? tool.path : firstLine)
        } catch {
            return L10n.text("settings.7zip.notFound")
        }
    }

    // MARK: - 候选路径

    /// App bundle 自带的 7zz 路径 —— DMG 发布版会把 `Contents/Resources/Tools/7zz` 一起打包。
    /// 罗列多个备选名是为了兼容历史 build / 不同打包脚本的产物。
    private static var bundledCandidates: [ResolvedSevenZipTool] {
        guard let resourcePath = Bundle.main.resourceURL?.path else { return [] }
        return [
            "\(resourcePath)/Tools/7zz",
            "\(resourcePath)/Tools/7z",
            "\(resourcePath)/7zz",
            "\(resourcePath)/7z"
        ].map { ResolvedSevenZipTool(path: $0, source: .bundled) }
    }

    /// 系统级 7zz —— Homebrew、p7zip Cellar、$PATH 各种来源。
    /// `uniqueExistingCandidatePaths` 去重；不存在路径在 resolve() 里再过一次 `isExecutableFile`。
    private static var systemCandidates: [ResolvedSevenZipTool] {
        let candidates: [String?] = [
            "/opt/homebrew/bin/7zz",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7zz",
            "/usr/local/bin/7z",
            "/opt/homebrew/opt/sevenzip/bin/7zz",
            "/opt/homebrew/opt/sevenzip/bin/7z",
            "/opt/homebrew/opt/p7zip/bin/7z",
            "/usr/local/opt/sevenzip/bin/7zz",
            "/usr/local/opt/sevenzip/bin/7z",
            "/usr/local/opt/p7zip/bin/7z",
            ArchiveService.envPath(for: "7zz"),
            ArchiveService.envPath(for: "7z")
        ]
        let combined = candidates.compactMap { $0 }
            + ArchiveService.cellarCandidates(formula: "sevenzip", tools: ["7zz", "7z"])
            + ArchiveService.cellarCandidates(formula: "p7zip", tools: ["7z"])
        return ArchiveService.uniqueExistingCandidatePaths(combined)
            .map { ResolvedSevenZipTool(path: $0, source: .system) }
    }
}

/// 用户偏好挑出来的「这次该用这份 7zz」结果。path + source 一起放是为了 UI 能显示 "来自 SimpleZip 内置 / 系统"。
struct ResolvedSevenZipTool {
    let path: String
    let source: SevenZipToolSource
}

/// 7zz 来源 —— 决定用户面板里那行说明文字。
enum SevenZipToolSource {
    case bundled
    case system

    var title: String {
        switch self {
        case .bundled:
            return L10n.text("settings.7zip.source.bundled")
        case .system:
            return L10n.text("settings.7zip.source.system")
        }
    }
}
