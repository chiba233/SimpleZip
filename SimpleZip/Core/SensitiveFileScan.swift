//
//  SensitiveFileScan.swift
//  SimpleZip
//
//  0.4.4 #68:在归档(非加密)条目清单里找出**许可证 / 配置 / 疑似密钥与机密 / 脚本**类文件。
//
//  纯确定性按文件名/扩展名归类(不靠 AI 扫列表 —— 端上小模型扫长清单不可靠)。AI 只在结果上**解释**
//  「这些是什么、要注意什么」(它擅长的事)。只看非加密条目名(头加密归档根本列不出名字)。
//

import Foundation

nonisolated enum SensitiveFileCategory: String, CaseIterable, Codable {
    case secretsKeys     // 私钥 / 凭据 / 机密
    case license         // 许可证 / 版权
    case config          // 配置
    case scripts         // 脚本
}

nonisolated struct SensitiveFileScanResult: Equatable {
    struct Group: Equatable, Identifiable {
        let category: SensitiveFileCategory
        let paths: [String]
        var id: String { category.rawValue }
    }
    /// 只含非空分组,按 `SensitiveFileCategory.allCases` 顺序(机密在最前 —— 最值得留意)。
    let groups: [Group]
    /// 扫了多少个文件条目(目录不计)。
    let scannedFileCount: Int

    var isEmpty: Bool { groups.isEmpty }
    var totalHitCount: Int { groups.reduce(0) { $0 + $1.paths.count } }
}

nonisolated enum SensitiveFileScan {
    /// 私钥 / 凭据 / 机密:扩展名 + 知名文件名 + 名字里含明显机密词。
    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "der", "pkcs12", "kdb", "kdbx"
    ]
    private static let secretBaseNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", ".netrc", ".htpasswd",
        ".pgpass", "credentials", "secrets", ".gitconfig", "authorized_keys", "known_hosts"
    ]
    private static let secretNameTokens: [String] = [
        "secret", "password", "passwd", "credential", "apikey", "api_key", "token", "private_key", "privatekey"
    ]

    /// 许可证 / 版权:基本是固定文件名(允许带扩展)。
    private static let licenseStems: Set<String> = [
        "license", "licence", "copying", "copyright", "notice", "unlicense", "patents"
    ]

    /// 配置:扩展名 + 知名无扩展配置文件名。
    private static let configExtensions: Set<String> = [
        "conf", "cfg", "ini", "yaml", "yml", "toml", "json", "plist", "properties", "env", "config"
    ]
    private static let configBaseNames: Set<String> = [
        "dockerfile", "makefile", "cmakelists.txt", ".gitignore", ".dockerignore",
        ".npmrc", ".babelrc", ".eslintrc", ".editorconfig", "procfile"
    ]

    /// 脚本:扩展名。
    private static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "py", "rb", "pl", "lua", "tcl", "applescript"
    ]

    /// 归类一批条目路径(全路径,只取末段文件名匹配)。每个文件只进**第一个**命中的分类
    /// (优先级:机密 > 许可证 > 配置 > 脚本),避免一个文件出现在多个组里。
    static func scan(_ entryPaths: [String]) -> SensitiveFileScanResult {
        var byCategory: [SensitiveFileCategory: [String]] = [:]
        var scanned = 0
        for path in entryPaths {
            let base = lastComponent(path)
            guard !base.isEmpty else { continue }
            // 目录(以 / 结尾)不算文件。
            if path.hasSuffix("/") { continue }
            scanned += 1
            if let category = classify(base: base) {
                byCategory[category, default: []].append(path)
            }
        }
        let groups = SensitiveFileCategory.allCases.compactMap { category -> SensitiveFileScanResult.Group? in
            guard let paths = byCategory[category], !paths.isEmpty else { return nil }
            return SensitiveFileScanResult.Group(category: category, paths: paths)
        }
        return SensitiveFileScanResult(groups: groups, scannedFileCount: scanned)
    }

    private static func classify(base rawBase: String) -> SensitiveFileCategory? {
        let base = rawBase.lowercased()
        let ext = fileExtension(base)
        let stem = stemWithoutExtension(base)

        // 机密 / 密钥(最高优先级)。
        if secretExtensions.contains(ext) { return .secretsKeys }
        if secretBaseNames.contains(base) { return .secretsKeys }
        if secretNameTokens.contains(where: { base.contains($0) }) { return .secretsKeys }

        // 许可证(stem 命中,允许 license.txt / license.md 等)。
        if licenseStems.contains(stem) || licenseStems.contains(base) { return .license }

        // 配置。
        if configExtensions.contains(ext) { return .config }
        if configBaseNames.contains(base) { return .config }

        // 脚本。
        if scriptExtensions.contains(ext) { return .scripts }

        return nil
    }

    // MARK: - 纯文件名工具(不依赖 URL,跨平台路径分隔符按 "/" 处理)

    private static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    private static func fileExtension(_ base: String) -> String {
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[base.index(after: dot)...])
    }

    private static func stemWithoutExtension(_ base: String) -> String {
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        return String(base[..<dot])
    }
}
