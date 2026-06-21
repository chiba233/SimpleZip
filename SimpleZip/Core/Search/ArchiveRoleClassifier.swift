//
//  ArchiveRoleClassifier.swift
//  SimpleZip
//
//  0.4.5 #80:归档**角色**确定性识别(白皮书 Feat 5)。角色比「格式」有用 —— 一个 `.zip` 可能是源码包、
//  发布包、安装包、备份包、测试样本、签名容器、配置包、媒体包或本地化 app 包。角色直接驱动工具栏推荐、
//  AI 工作区、归档查找。
//
//  这是「第一层确定性打分」:从 `ArchiveProfile`(marker / 扩展分布 / 语义标签 / 结构)规则打分。本地弱模型
//  只在分数接近、或需要命名 / 解释时介入(后续接);用户纠错写 role feedback,同类信号降权(Feat 11)。
//  纯函数 + 确定性,SwiftPM 可断言。
//
//  注:`backup-package` / `test-fixture` 主要靠**目录名 token**(backup / test)判定,而 token 不在
//  `ArchiveProfile` 里(它只看条目),所以本层不给这两个角色打分 —— 由调用点结合 `AILocationContext`
//  的 folderNameTokens 叠加,或交给模型。
//

import Foundation

nonisolated enum AIArchiveRole: String, Codable, Equatable, CaseIterable, Sendable {
    case sourcePackage = "source-package"
    case releasePackage = "release-package"
    case installerPackage = "installer-package"
    case backupPackage = "backup-package"
    case testFixture = "test-fixture"
    case signedContainer = "signed-container"
    case configBundle = "config-bundle"
    case mediaBundle = "media-bundle"
    case localizedAppPackage = "localized-app-package"
    case unknown
}

nonisolated struct AIArchiveRoleScore: Codable, Equatable, Sendable {
    let role: AIArchiveRole
    /// 0…1 归一化分数。
    let score: Double
    /// 命中的确定性信号(给证据卡 / 解释用)。
    let reasons: [String]
}

nonisolated enum ArchiveRoleClassifier {
    /// 从确定性画像给各角色打分,按分降序(同分按角色名稳定排序 → 确定性)。只返回有得分的角色。
    static func classify(profile: ArchiveProfile) -> [AIArchiveRoleScore] {
        let tags = Set(profile.semanticTags)
        let extSet = Set(profile.dominantExtensions.map(\.ext))
        let totalFiles = max(1, profile.structure.fileCount)
        func extShare(_ group: Set<String>) -> Double {
            let n = profile.dominantExtensions.filter { group.contains($0.ext) }.reduce(0) { $0 + $1.count }
            return Double(n) / Double(totalFiles)
        }

        var raw: [AIArchiveRole: (score: Double, reasons: [String])] = [:]
        func add(_ role: AIArchiveRole, _ score: Double, _ reason: String) {
            var cur = raw[role] ?? (0, [])
            cur.score += score
            cur.reasons.append(reason)
            raw[role] = cur
        }

        // 源码包。
        if tags.contains("source-archive") { add(.sourcePackage, 0.6, "source-archive tag") }
        if tags.contains("swift-project") { add(.sourcePackage, 0.3, "swift-project marker") }

        // 发布包。
        if tags.contains("release-artifact") { add(.releasePackage, 0.6, "release-artifact tag") }
        if profile.markerFiles.contains(where: { $0.lowercased() == "sha256sums" }) {
            add(.releasePackage, 0.3, "SHA256SUMS present")
        }
        if extSet.contains("dmg") { add(.releasePackage, 0.2, "dmg present") }

        // 安装包。
        if extSet.contains("pkg") { add(.installerPackage, 0.5, "pkg present") }
        if extSet.contains("dmg") { add(.installerPackage, 0.4, "dmg present") }
        if tags.contains("installer") { add(.installerPackage, 0.3, "installer tag") }

        // 签名容器。
        if tags.contains("signed-container-related") { add(.signedContainer, 0.5, "signed-container-related tag") }
        if extSet.contains("szs") || extSet.contains("siz") { add(.signedContainer, 0.4, "szs/siz present") }
        if extSet.contains("asc") || extSet.contains("sig") { add(.signedContainer, 0.3, "signature file") }

        // 本地化 app 包。
        if tags.contains("localized-app") { add(.localizedAppPackage, 0.5, "localized-app tag") }
        if tags.contains("application-bundle") {
            add(.localizedAppPackage, 0.2, "app bundle")
            add(.installerPackage, 0.2, "app bundle")
        }

        // 媒体包(主导扩展是媒体)。
        let mediaShare = extShare(Self.mediaExtensions)
        if mediaShare >= 0.5 {
            add(.mediaBundle, 0.4 + 0.4 * mediaShare, "media-heavy (\(Int((mediaShare * 100).rounded()))%)")
        }

        // 配置包(主导扩展是配置,且不像源码)。
        let configShare = extShare(Self.configExtensions)
        if configShare >= 0.4 && !tags.contains("source-archive") {
            add(.configBundle, 0.3 + 0.4 * configShare, "config-heavy (\(Int((configShare * 100).rounded()))%)")
        }

        return raw
            .map { AIArchiveRoleScore(role: $0.key, score: min(1.0, $0.value.score), reasons: $0.value.reasons) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.role.rawValue < $1.role.rawValue }
    }

    /// 最可能的角色:最高分且 ≥ 阈值,否则 `.unknown`(分太低 / 无信号时不硬猜)。
    static func primaryRole(for profile: ArchiveProfile, threshold: Double = 0.3) -> AIArchiveRole {
        guard let top = classify(profile: profile).first, top.score >= threshold else { return .unknown }
        return top.role
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp",
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "wav", "flac", "aac", "m4a"
    ]
    static let configExtensions: Set<String> = [
        "yaml", "yml", "json", "toml", "ini", "conf", "cfg", "plist", "xml", "env", "properties"
    ]
}
