//
//  AIArchiveInternalMap.swift
//  SimpleZip
//
//  0.4.5 #80:AI 归档内部地图(白皮书 Feat 13)。打开大归档时,用户最缺「一眼知道里面是什么」。从确定性
//  `ArchiveProfile` + 非加密样本路径派生一张内部地图:若干 section(源码 / 本地化 / 测试 / 发布校验 /
//  文档 / 媒体 / 配置)+ 推荐 Lens。模型只负责给 section 起人话标题、总结结构 —— 这里是确定性骨架。
//
//  **红线**:只吃 `ArchiveProfile`(已排除加密条目)+ 已脱敏样本路径;`encryptedEntryCount > 0` 时写
//  omission,绝不猜加密部分。纯函数,SwiftPM 可断言。可缓存进 `ArchiveMemoryRecord` 复用。
//

import Foundation

/// 内部地图的一个 section。`titleToken` 是稳定英文 token(UI 本地化 / 模型起标题);`evidence` 是命中信号。
nonisolated struct AIArchiveMapSection: Codable, Equatable, Sendable {
    let titleToken: String
    let evidence: [String]
}

nonisolated struct AIArchiveInternalMap: Codable, Equatable, Sendable {
    let sections: [AIArchiveMapSection]
    /// 推荐视角(AILens rawValue);无明显倾向时 nil。
    let suggestedLens: String?
    let omissions: [AIContextOmission]

    var isEmpty: Bool { sections.isEmpty }
}

nonisolated enum AIArchiveMapBuilder {
    /// 从画像 + 样本路径确定性派生内部地图。section 按固定顺序产出(确定性)。
    static func build(profile: ArchiveProfile, samplePaths: [String]) -> AIArchiveInternalMap {
        let tags = Set(profile.semanticTags)
        let markers = Set(profile.markerFiles.map { $0.lowercased() })
        let exts = Set(profile.dominantExtensions.map(\.ext))
        let lowerPaths = samplePaths.map { $0.lowercased() }
        func pathHas(_ needle: String) -> [String] { lowerPaths.filter { $0.contains(needle) } }

        var sections: [AIArchiveMapSection] = []
        func add(_ token: String, _ evidence: [String]) {
            let uniq = Array(NSOrderedSet(array: evidence)).compactMap { $0 as? String }
            if !uniq.isEmpty { sections.append(AIArchiveMapSection(titleToken: token, evidence: Array(uniq.prefix(5)))) }
        }

        // 源码。
        var sourceEv: [String] = []
        if markers.contains("package.swift") { sourceEv.append("Package.swift") }
        if markers.contains("package.json") { sourceEv.append("package.json") }
        if markers.contains("pyproject.toml") { sourceEv.append("pyproject.toml") }
        if tags.contains("source-archive") || tags.contains("swift-project") { sourceEv.append("source-archive") }
        sourceEv += pathHas("sources/") + pathHas("src/")
        add("source", sourceEv)

        // 本地化。
        var l10nEv = pathHas(".lproj") + pathHas("localizable.strings")
        if tags.contains("localized-app") { l10nEv.append("localized-app") }
        add("localization", l10nEv)

        // 测试。
        add("tests", pathHas("tests/") + pathHas("/test/") + (lowerPaths.contains { $0.hasPrefix("test/") } ? ["test/"] : []))

        // 发布校验。
        var relEv: [String] = []
        if markers.contains("sha256sums") { relEv.append("SHA256SUMS") }
        if markers.contains("signature.asc") || exts.contains("asc") { relEv.append("signature.asc") }
        if markers.contains("verify.md") { relEv.append("VERIFY.md") }
        if tags.contains("release-artifact") { relEv.append("release-artifact") }
        add("release-verification", relEv)

        // 文档。
        var docEv: [String] = []
        if markers.contains("readme.md") || markers.contains("readme") { docEv.append("README") }
        if markers.contains("license") || markers.contains("license.md") { docEv.append("LICENSE") }
        if markers.contains("changelog.md") { docEv.append("CHANGELOG") }
        if tags.contains("documentation") { docEv.append("documentation") }
        add("documentation", docEv)

        // 媒体 / 配置(按主导扩展)。
        let mediaExts = exts.intersection(["jpg", "jpeg", "png", "gif", "heic", "mov", "mp4", "m4v", "mp3", "wav", "flac"])
        add("media", Array(mediaExts).sorted())
        let configExts = exts.intersection(["yaml", "yml", "json", "toml", "ini", "conf", "plist", "xml"])
        if !tags.contains("source-archive") { add("config", Array(configExts).sorted()) }

        // 推荐 Lens(固定优先级:发布 > 签名 > 源码)。
        var lens: String?
        let sectionTokens = Set(sections.map(\.titleToken))
        if sectionTokens.contains("release-verification") { lens = AILens.release.rawValue }
        else if exts.contains("asc") || exts.contains("szs") || exts.contains("siz") { lens = AILens.signing.rawValue }
        else if sectionTokens.contains("source") { lens = AILens.source.rawValue }

        var omissions: [AIContextOmission] = []
        if profile.structure.encryptedEntryCount > 0 {
            omissions.append(.encryptedEntryNames(count: profile.structure.encryptedEntryCount))
        }

        return AIArchiveInternalMap(sections: sections, suggestedLens: lens, omissions: omissions)
    }
}
