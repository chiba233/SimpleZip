//
//  AIPresetRecommendation.swift
//  SimpleZip
//
//  0.4.5 #80:AI 预设推荐(白皮书 Feat 10)。创建归档时按输入画像(角色 / 扩展名 / marker / 是否媒体为主)
//  **确定性**推荐一个压缩预设类别,并给一组**安全的** option 提示 —— 但绝不直接改参数:App 只展示,用户点了才应用。
//
//  安全边界:option 提示走 `hintableOptions` 白名单,**永不含 password / 加密算法 / GPG** —— 那些字段只能用户
//  手设,AI 不预填(与 `AIOperationOptionPatch` 的 suggestOnly 红线一致)。`sanitize` 兜底剔除任何越界 hint。
//  纯函数 + 确定性,SwiftPM 可断言。
//

import Foundation

/// 推荐的压缩预设类别(稳定英文 token)。App 据此在用户的可用预设里匹配,或作为默认行为提示。
nonisolated enum AIPresetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sourceArchive = "source-archive"
    case releasePackage = "release-package"
    case mediaStore = "media-store"
    case backup
    case general

    /// 在可用预设 id 里匹配本类的关键词(小写子串)。`general` 不匹配具体预设。
    var matchTokens: [String] {
        switch self {
        case .sourceArchive: return ["source", "src", "code"]
        case .releasePackage: return ["release", "dist", "publish"]
        case .mediaStore: return ["media", "photo", "video", "store"]
        case .backup: return ["backup"]
        case .general: return []
        }
    }
}

/// 一个 option 提示值(布尔 / 字符串;创建选项里两类够用)。
nonisolated enum AIOptionHintValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case string(String)
}

/// 一条安全 option 提示(只覆盖非敏感的创建选项)。
nonisolated struct AIPresetOptionHint: Codable, Equatable, Sendable {
    let option: String
    let value: AIOptionHintValue

    init(_ option: String, _ value: AIOptionHintValue) {
        self.option = option
        self.value = value
    }
}

/// 预设推荐结果。`presetID` 为匹配到的用户预设 id(无匹配为 nil,仍给 optionHints);`evidence` 解释为什么。
nonisolated struct AIPresetRecommendation: Codable, Equatable, Sendable {
    let kind: AIPresetKind
    let presetID: String?
    let optionHints: [AIPresetOptionHint]
    let evidence: [AIEvidenceFact]

    init(kind: AIPresetKind, presetID: String? = nil,
         optionHints: [AIPresetOptionHint] = [], evidence: [AIEvidenceFact] = []) {
        self.kind = kind
        self.presetID = presetID
        self.optionHints = optionHints
        self.evidence = evidence
    }
}

/// 确定性预设推荐器。无模型也工作(模型只把 `evidence` 润色成一句理由)。
nonisolated enum AIPresetRecommender {
    /// AI 只能建议的「安全」创建选项白名单 —— 绝不含 password / 加密 / GPG(只能用户手设,AI 不预填)。
    static let hintableOptions: Set<String> = [
        "excludeJunk", "skipDSStore", "testAfterCreate", "reproducible", "compressionLevel", "format"
    ]

    static func recommend(
        role: String?, extensions: [String] = [], markerFiles: [String] = [],
        hasMediaHeavyContent: Bool = false, availablePresetIDs: [String] = []
    ) -> AIPresetRecommendation {
        let kind = inferKind(role: role, extensions: extensions, markerFiles: markerFiles,
                             hasMediaHeavyContent: hasMediaHeavyContent)
        let presetID = matchPreset(kind: kind, available: availablePresetIDs)
        let hints = sanitize(optionHints(for: kind))
        let evidence = buildEvidence(role: role, markerFiles: markerFiles, extensions: extensions,
                                     hasMediaHeavyContent: hasMediaHeavyContent, kind: kind)
        return AIPresetRecommendation(kind: kind, presetID: presetID, optionHints: hints, evidence: evidence)
    }

    /// 兜底剔除安全白名单外的任何 option hint(防止后续误把加密 / 口令塞进 hints)。
    static func sanitize(_ hints: [AIPresetOptionHint]) -> [AIPresetOptionHint] {
        hints.filter { hintableOptions.contains($0.option) }
    }

    // MARK: - 类别推断

    static func inferKind(role: String?, extensions: [String], markerFiles: [String],
                          hasMediaHeavyContent: Bool) -> AIPresetKind {
        if let mapped = kindForRole(role) { return mapped }
        if hasMediaHeavyContent { return .mediaStore }

        let markersLower = Set(markerFiles.map { $0.lowercased() })
        if !markersLower.isDisjoint(with: sourceMarkers) { return .sourceArchive }

        let exts = Set(extensions.map { $0.lowercased() })
        let hasSource = !exts.isDisjoint(with: sourceExtensions)
        let hasMedia = !exts.isDisjoint(with: mediaExtensions)
        if hasMedia && !hasSource { return .mediaStore }
        if hasSource { return .sourceArchive }
        return .general
    }

    private static func kindForRole(_ role: String?) -> AIPresetKind? {
        guard let role, let r = AIArchiveRole(rawValue: role) else { return nil }
        switch r {
        case .sourcePackage: return .sourceArchive
        case .releasePackage, .installerPackage, .signedContainer: return .releasePackage
        case .backupPackage: return .backup
        case .mediaBundle: return .mediaStore
        // 这些角色不直接定预设类别 —— 交给扩展名 / marker 进一步推断。
        case .testFixture, .configBundle, .localizedAppPackage, .unknown: return nil
        }
    }

    // MARK: - 安全 option 提示

    static func optionHints(for kind: AIPresetKind) -> [AIPresetOptionHint] {
        switch kind {
        case .sourceArchive:
            return [AIPresetOptionHint("excludeJunk", .bool(true)),
                    AIPresetOptionHint("testAfterCreate", .bool(true))]
        case .releasePackage:
            return [AIPresetOptionHint("excludeJunk", .bool(true)),
                    AIPresetOptionHint("testAfterCreate", .bool(true)),
                    AIPresetOptionHint("reproducible", .bool(true))]
        case .mediaStore:
            // 媒体多已压缩,建议 store 级别(更快、体积接近)。
            return [AIPresetOptionHint("compressionLevel", .string("store"))]
        case .backup:
            return [AIPresetOptionHint("testAfterCreate", .bool(true))]
        case .general:
            return []
        }
    }

    private static func matchPreset(kind: AIPresetKind, available: [String]) -> String? {
        let tokens = kind.matchTokens
        guard !tokens.isEmpty else { return nil }
        return available.first { id in
            let lower = id.lowercased()
            return tokens.contains { lower.contains($0) }
        }
    }

    private static func buildEvidence(role: String?, markerFiles: [String], extensions: [String],
                                      hasMediaHeavyContent: Bool, kind: AIPresetKind) -> [AIEvidenceFact] {
        var facts: [AIEvidenceFact] = []
        if let role, !role.isEmpty {
            facts.append(AIEvidenceFact(label: "role", facts: ["role=\(role)"]))
        }
        let matchedMarkers = markerFiles.filter { sourceMarkers.contains($0.lowercased()) }
        if !matchedMarkers.isEmpty {
            facts.append(AIEvidenceFact(label: "markers", facts: matchedMarkers))
        }
        if hasMediaHeavyContent {
            facts.append(AIEvidenceFact(label: "content", facts: ["mediaHeavy=true"]))
        }
        facts.append(AIEvidenceFact(label: "kind", facts: ["kind=\(kind.rawValue)"]))
        return facts
    }

    // MARK: - 词表

    static let sourceMarkers: Set<String> = [
        "package.swift", "cargo.toml", "package.json", "readme.md", "go.mod",
        "pom.xml", "build.gradle", ".gitignore", "makefile", "pyproject.toml", "gemfile"
    ]

    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt",
        "c", "cc", "cpp", "h", "hpp", "m", "mm", "md", "strings", "json", "yml", "yaml", "toml"
    ]

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "raw", "psd",
        "mp4", "mov", "avi", "mkv", "m4v", "mp3", "wav", "flac", "aac", "aiff"
    ]
}
