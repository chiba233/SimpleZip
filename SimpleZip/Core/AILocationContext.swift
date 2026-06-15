//
//  AILocationContext.swift
//  SimpleZip
//
//  0.4.5 #80:把一个文件夹路径拆成**低敏的位置上下文**(路线图建议六 / 建议二「格式化规则」)。
//
//  完整绝对路径不进长期学习。学习 / 推荐用三件低敏信号:位置类别(Downloads / Desktop / 外置盘 / 临时
//  工作区 …)、稳定路径哈希(同一文件夹可识别但不暴露路径)、目录名 token(release / test / backup /
//  siz / szs …,帮助识别工作场景)。纯函数 + 确定性哈希(FNV-1a,无 IO / 无 crypto),SwiftPM 可断言。
//

import Foundation

/// 文件夹的位置类别。稳定英文 token。`projectFolder` 需要 marker(由上层用目录内容判定后升级);
/// `sameDirectory` 是关系类别(解压目标 = 归档所在目录),由调用点判定,本分类器不产出这两者。
nonisolated enum AILocationKind: String, Codable, Equatable, CaseIterable, Sendable {
    case downloads
    case desktop
    case documents
    case externalDrive = "external-drive"
    case temporaryWorkspace = "temporary-workspace"
    case projectFolder = "project-folder"
    case sameDirectory = "same-directory"
    case other
}

/// 一个文件夹的低敏上下文:类别 + 稳定哈希 + 目录名 token。
nonisolated struct AILocationContext: Codable, Equatable, Sendable {
    let kind: AILocationKind
    /// 同一文件夹稳定识别(用于学习),不暴露完整路径。形如 `loc-9d1a3f20`。
    let pathHash: String
    /// 目录名拆出的低敏 token(`release` / `test` / `siz` / `szs` …),封顶 6 个。
    let folderNameTokens: [String]

    init(kind: AILocationKind, pathHash: String, folderNameTokens: [String]) {
        self.kind = kind
        self.pathHash = pathHash
        self.folderNameTokens = folderNameTokens
    }
}

nonisolated enum AILocationClassifier {
    /// 把一个**目录**路径分类成低敏上下文。`home` 可注入(测试用),默认取当前用户主目录。
    static func classify(directoryPath: String, home: String = NSHomeDirectory()) -> AILocationContext {
        let canonical = canonicalize(directoryPath)
        return AILocationContext(
            kind: kind(forPath: canonical, home: canonicalize(home)),
            pathHash: pathHash(canonical),
            folderNameTokens: folderNameTokens(canonical)
        )
    }

    /// 位置类别(不含 projectFolder / sameDirectory —— 见枚举说明)。
    static func kind(forPath path: String, home: String) -> AILocationKind {
        func under(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }

        if under(home + "/Downloads") { return .downloads }
        if under(home + "/Desktop") { return .desktop }
        if under(home + "/Documents") { return .documents }
        if isTemporary(path) { return .temporaryWorkspace }
        if path.hasPrefix("/Volumes/") { return .externalDrive }
        return .other
    }

    /// 升级位置类别:目录内含 release / 项目 marker 时把 `.other` 提升为 `.projectFolder`。
    /// marker 由上层(有目录列表)传入,本层不读文件系统。
    static func refineKind(_ kind: AILocationKind, folderEntryNames: [String]) -> AILocationKind {
        guard kind == .other else { return kind }
        let lowered = Set(folderEntryNames.map { $0.lowercased() })
        let markers: Set<String> = [
            "package.swift", "readme.md", "readme", "license", "license.md",
            ".git", "cargo.toml", "pyproject.toml", "package.json", "go.mod",
            "changelog.md", "makefile"
        ]
        return lowered.contains(where: markers.contains) ? .projectFolder : .other
    }

    /// 稳定、确定性、低暴露的路径标识。非加密用途,只为「同一文件夹」识别(复用 AIStableHash,A2)。
    static func pathHash(_ path: String) -> String {
        "loc-" + AIStableHash.fnv1a32Hex(canonicalize(path))
    }

    /// 目录名拆 token:小写、按非字母数字切分、丢 <2 字符、去重、封顶 6 个。CJK 作为字母保留。
    static func folderNameTokens(_ path: String) -> [String] {
        let name = (path as NSString).lastPathComponent.lowercased()
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            let token = String(current)
            if token.count >= 2, !tokens.contains(token) { tokens.append(token) }
            current = String.UnicodeScalarView()
        }
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return Array(tokens.prefix(6))
    }

    // MARK: - Private

    private static func canonicalize(_ path: String) -> String {
        // 审计 #8:空 / 纯空白路径短路返回 "" —— 否则 URL(fileURLWithPath: "") 会解析成进程当前工作目录,
        // 让空输入被误分类成 CWD 所在位置。
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func isTemporary(_ path: String) -> Bool {
        path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/")
            || path.hasPrefix("/private/tmp/")
            || path.hasPrefix("/tmp/")
            || path.contains("/SimpleZip-")
    }
}
