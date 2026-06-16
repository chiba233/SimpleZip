//
//  AISemanticTag.swift
//  SimpleZip
//
//  0.4.5 #80:受控语义标签全集 + 排序 + 纠错降权(白皮书 Feat 1「AI 智能标签系统」+ Feat 5「归档角色」
//  + Feat 11「纠错学习」)。**模型不能自由发明标签,只能从这个受控集合里选** —— AI 输出的标签必须能
//  `init?(token:)` 解析且落在 App 给的候选集内,否则整条丢弃。
//
//  与 `ArchiveProfile` 产的确定性 string tags 对齐(raw 用同一套稳定英文 token,不随 UI 语言走);这一层
//  把「候选 + 确定性分数 + 证据 + 用户纠错降权」统一起来,供 AI 工作区 / 归档查找 / 工具栏推荐共用。
//  纯值类型 + 确定性排序,SwiftPM 可断言。
//

import Foundation

/// 受控语义标签全集。raw = 稳定英文 token,与 `ArchiveProfile.semanticTags` / 白皮书示例一致。
nonisolated enum AISemanticTag: String, Codable, Equatable, CaseIterable, Sendable {
    // 归档角色(Feat 5 角色候选 + 常见派生)
    case sourceArchive = "source-archive"
    case sourcePackage = "source-package"
    case releaseArtifact = "release-artifact"
    case releasePackage = "release-package"
    case installer = "installer"
    case installerPackage = "installer-package"
    case backup = "backup"
    case backupPackage = "backup-package"
    case testFixture = "test-fixture"
    case signedContainer = "signed-container"
    case configBundle = "config-bundle"
    case mediaBundle = "media-bundle"
    case localizedAppPackage = "localized-app-package"
    // 特征标签(描述内容特征,不直接等于「这是什么包」)
    case swiftProject = "swift-project"
    case localizedApp = "localized-app"
    case documentation = "documentation"
    case applicationBundle = "application-bundle"
    case signedContainerRelated = "signed-container-related"
    case brokenVolume = "broken-volume"

    /// 从 `ArchiveProfile` / AI 输出的 string token 安全解析。未知 token → nil(整条丢弃)。
    init?(token: String) { self.init(rawValue: token) }

    /// 是否是「归档角色」类标签(Feat 5):直接回答「这个归档是什么」,用于工具栏推荐 / 工作区分组的角色
    /// 判断。特征标签(swift-project / documentation / signed-container-related …)不算角色。
    var isArchiveRole: Bool {
        switch self {
        case .sourceArchive, .sourcePackage, .releaseArtifact, .releasePackage,
             .installer, .installerPackage, .backup, .backupPackage,
             .testFixture, .signedContainer, .configBundle, .mediaBundle, .localizedAppPackage:
            return true
        case .swiftProject, .localizedApp, .documentation, .applicationBundle,
             .signedContainerRelated, .brokenVolume:
            return false
        }
    }
}

/// 一个候选标签 + 确定性分数 + 证据(Feat 1)。App 确定性产候选,模型只在候选内排序 / 补理由 ——
/// 模型绝不发明候选。
nonisolated struct AISemanticTagCandidate: Codable, Equatable, Sendable {
    let tag: AISemanticTag
    /// 0...1 确定性分数(来自 `ArchiveProfile` 规则命中强度)。
    let deterministicScore: Double
    let evidence: [AIEvidenceFact]

    init(tag: AISemanticTag, deterministicScore: Double, evidence: [AIEvidenceFact] = []) {
        self.tag = tag
        self.deterministicScore = deterministicScore
        self.evidence = evidence
    }
}

/// 标签排序 + 模型输出校验。纯函数 —— 同一输入逐次一致。
nonisolated enum AISemanticTagRanker {
    /// 每次负反馈对有效分数的固定衰减;cap 防一个标签被反复踩死。
    static let decayPerNegative = 0.15
    static let negativeFeedbackCap = 5
    /// 每次正反馈(用户确认「就是这个标签」)对有效分数的提升;比负衰减略小,防刷分。
    static let boostPerPositive = 0.10
    static let positiveFeedbackCap = 5

    /// 排序候选:按「确定性分数 + 正反馈加成 − 负反馈衰减」降序,同分按 token 升序确定性。
    /// `negativeFeedback` / `positiveFeedback` 均为 `标签 token → 次数`(Feat 11)。
    static func rank(
        _ candidates: [AISemanticTagCandidate],
        negativeFeedback: [String: Int] = [:],
        positiveFeedback: [String: Int] = [:],
        limit: Int? = nil
    ) -> [AISemanticTagCandidate] {
        func effective(_ c: AISemanticTagCandidate) -> Double {
            let negHits = min(max(negativeFeedback[c.tag.rawValue] ?? 0, 0), negativeFeedbackCap)
            let posHits = min(max(positiveFeedback[c.tag.rawValue] ?? 0, 0), positiveFeedbackCap)
            return c.deterministicScore
                - decayPerNegative * Double(negHits)
                + boostPerPositive * Double(posHits)
        }
        let sorted = candidates.sorted {
            let (l, r) = (effective($0), effective($1))
            return l != r ? l > r : $0.tag.rawValue < $1.tag.rawValue
        }
        if let limit, limit >= 0 { return Array(sorted.prefix(limit)) }
        return sorted
    }

    /// 校验模型选出的 tag tokens:只保留**在候选集内**的(发明的 / 候选外的标签丢弃),保持模型给的顺序、
    /// 去重。这是 Feat 1 的硬约束「模型只能从候选里选」的执行点。
    static func validateChosen(
        _ chosenTokens: [String],
        against candidates: [AISemanticTagCandidate]
    ) -> [AISemanticTag] {
        let allowed = Set(candidates.map { $0.tag })
        var seen = Set<AISemanticTag>()
        var result: [AISemanticTag] = []
        for token in chosenTokens {
            guard let tag = AISemanticTag(token: token), allowed.contains(tag), seen.insert(tag).inserted
            else { continue }
            result.append(tag)
        }
        return result
    }
}
