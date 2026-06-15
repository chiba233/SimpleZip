//
//  ArchiveProfile.swift
//  SimpleZip
//
//  0.4.5 #80:归档的**确定性画像**(路线图建议二十 / 建议九)。从已打开归档的条目派生结构化标签 + 证据,
//  供 AI 工作区、归档查找、动态按钮、报告解释共用 —— 不必每次重扫。
//
//  这是「第一层确定性派生」:扩展名分布、marker 文件、顶层结构、加密计数、风险 hints、规则语义标签。
//  「第二层 AI 标注」(把 facts 升成更自由的语义标签)后续接,但必须可回溯到这层证据。
//
//  **红线**:`item.isEncrypted == true` 的条目整条排除 —— 名字 / 内容绝不进画像,只保留计数 + omission。
//  头加密导致清单不可见的归档由调用点判断(空 items 进来 → 空画像 + 加密 omission)。纯函数,SwiftPM 可断言。
//

import Foundation

nonisolated struct ArchiveProfile: Codable, Equatable, Sendable {
    struct ExtensionCount: Codable, Equatable, Sendable {
        let ext: String
        let count: Int
    }

    struct StructureSummary: Codable, Equatable, Sendable {
        /// `single_root_folder` / `multi_root` / `scattered_files` / `empty`。
        let topLevelShape: String
        let topLevelNames: [String]
        let entryCount: Int        // 非加密条目数
        let fileCount: Int
        let directoryCount: Int
        let encryptedEntryCount: Int
    }

    /// 规则语义标签(稳定英文 token):source-archive / swift-project / localized-app / release-artifact /
    /// signed-container-related / installer / documentation / application-bundle。
    let semanticTags: [String]
    /// 命中的 marker 文件原始名(Package.swift / README.md / SHA256SUMS / *.asc …),封顶。
    let markerFiles: [String]
    /// 按数量排序的主导扩展名(count 降序、ext 升序)。
    let dominantExtensions: [ExtensionCount]
    let structure: StructureSummary
    /// 风险 hints:contains-app-bundle / contains-symlink / contains-executable / contains-package。
    let riskHints: [String]
    /// 因加密 / 截断省略了什么。
    let omissions: [AIContextOmission]

    /// 从已打开归档的条目派生画像。`items` 含全部条目(含加密);加密条目在内部被排除并计数。
    static func derive(from items: [ArchiveItem], budget: AIBudget = .archiveProfile) -> ArchiveProfile {
        let encryptedCount = items.reduce(0) { $0 + ($1.isEncrypted ? 1 : 0) }
        let visible = items.filter { !$0.isEncrypted }

        let directoryCount = visible.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
        let fileCount = visible.count - directoryCount

        // 顶层结构。
        var topDirs = Set<String>()
        var looseFiles = Set<String>()
        for item in visible {
            let comps = item.name.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let first = comps.first else { continue }
            if comps.count > 1 {
                topDirs.insert(first)
            } else if item.isDirectory {
                topDirs.insert(first)
            } else {
                looseFiles.insert(first)
            }
        }
        let topLevelShape: String
        if visible.isEmpty {
            topLevelShape = "empty"
        } else if looseFiles.isEmpty && topDirs.count == 1 {
            topLevelShape = "single_root_folder"
        } else if looseFiles.isEmpty && topDirs.count > 1 {
            topLevelShape = "multi_root"
        } else {
            topLevelShape = "scattered_files"
        }
        // 审计 #6:顶层名也过文件名 secret 脱敏(目录可能叫 `password=x` 之类)。
        let topLevelNames = Array(topDirs.union(looseFiles).sorted().prefix(budget.maxSamplesPerGroup))
            .map(AISensitiveRedactor.redactFileNameSecrets)

        // 扩展名分布。
        var extCounts: [String: Int] = [:]
        for item in visible where !item.isDirectory {
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            extCounts[ext, default: 0] += 1
        }
        let dominantExtensions = extCounts
            .map { ExtensionCount(ext: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext }
            .prefix(budget.maxSamplesPerGroup)
        let extSet = Set(extCounts.keys)

        // marker 文件(原始名)+ 小写 basename 集合(语义标签用)。
        var markers: [String] = []
        var seenMarkers = Set<String>()
        var basenamesLower = Set<String>()
        var containsAppBundle = false
        var containsPackage = false
        for item in visible {
            // .app / .bundle / .framework / .pkg 包目录痕迹(任何路径分量)。
            for comp in item.name.split(separator: "/") {
                let lc = comp.lowercased()
                if lc.hasSuffix(".app") { containsAppBundle = true; containsPackage = true }
                else if lc.hasSuffix(".bundle") || lc.hasSuffix(".framework") || lc.hasSuffix(".pkg") {
                    containsPackage = true
                }
            }
            guard !item.isDirectory else { continue }
            let base = (item.name as NSString).lastPathComponent
            let lower = base.lowercased()
            basenamesLower.insert(lower)
            let ext = (lower as NSString).pathExtension
            if Self.markerBasenames.contains(lower) || Self.markerExtensions.contains(ext) {
                if seenMarkers.insert(lower).inserted { markers.append(base) }
            }
        }
        markers.sort()
        let markerFiles = Array(markers.prefix(budget.maxSamplesPerGroup))

        // 语义标签(固定规则顺序 → 确定性)。
        var tags: [String] = []
        func add(_ tag: String) { if !tags.contains(tag) { tags.append(tag) } }
        let codeFileCount = visible.reduce(0) {
            $0 + (Self.codeExtensions.contains((($1.name as NSString).pathExtension.lowercased())) ? 1 : 0)
        }
        let hasLproj = visible.contains {
            $0.name.lowercased().contains(".lproj/") ||
            ($0.name as NSString).lastPathComponent.lowercased() == "localizable.strings"
        }
        if basenamesLower.contains("package.swift") { add("swift-project"); add("source-archive") }
        if basenamesLower.contains(where: { ["cargo.toml", "pyproject.toml", "package.json", "go.mod"].contains($0) }) {
            add("source-archive")
        }
        if codeFileCount >= 5 { add("source-archive") }
        if hasLproj { add("localized-app") }
        if basenamesLower.contains("sha256sums") || extSet.contains("dmg") || extSet.contains("asc") {
            add("release-artifact")
        }
        if extSet.contains("asc") || extSet.contains("szs") || extSet.contains("siz") || extSet.contains("sig")
            || basenamesLower.contains("signature.asc") {
            add("signed-container-related")
        }
        if extSet.contains("pkg") || extSet.contains("dmg") { add("installer") }
        if basenamesLower.contains(where: {
            ["readme.md", "readme", "readme.txt", "changelog.md", "license", "license.md"].contains($0)
        }) {
            add("documentation")
        }
        if containsAppBundle { add("application-bundle") }

        // 风险 hints。
        var hints: [String] = []
        if containsAppBundle { hints.append("contains-app-bundle") }
        if visible.contains(where: { !$0.symlinkTarget.isEmpty }) { hints.append("contains-symlink") }
        if visible.contains(where: { Self.hasExecutableBit($0.attributes) }) { hints.append("contains-executable") }
        if containsPackage && !hints.contains("contains-app-bundle") { hints.append("contains-package") }

        var omissions: [AIContextOmission] = []
        if encryptedCount > 0 { omissions.append(.encryptedEntryNames(count: encryptedCount)) }

        return ArchiveProfile(
            semanticTags: tags,
            markerFiles: markerFiles,
            dominantExtensions: Array(dominantExtensions),
            structure: StructureSummary(
                topLevelShape: topLevelShape,
                topLevelNames: topLevelNames,
                entryCount: visible.count,
                fileCount: fileCount,
                directoryCount: directoryCount,
                encryptedEntryCount: encryptedCount
            ),
            riskHints: hints,
            omissions: omissions
        )
    }

    // MARK: - 静态词表

    private static let markerBasenames: Set<String> = [
        "package.swift", "readme.md", "readme", "readme.txt", "license", "license.md", "license.txt",
        "copying", "sha256sums", "sha256sums.txt", "makefile", "cargo.toml", "pyproject.toml",
        "package.json", "go.mod", "dockerfile", "changelog.md", "verify.md", "signature.asc", "public_key.asc"
    ]
    private static let markerExtensions: Set<String> = ["asc", "szs", "siz", "sig", "dmg", "pkg"]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "kt", "rb", "cs", "m", "mm", "php", "scala"
    ]

    /// Unix 权限串(如 `-rwxr-xr-x`)是否带可执行位。
    private static func hasExecutableBit(_ attributes: String) -> Bool {
        guard attributes.count >= 10 else { return false }
        // 跳过首字符(文件类型),看后 9 位权限里有没有 x。
        return attributes.dropFirst().prefix(9).contains("x")
    }
}
