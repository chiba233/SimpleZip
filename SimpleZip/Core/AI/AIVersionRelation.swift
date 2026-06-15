//
//  AIVersionRelation.swift
//  SimpleZip
//
//  0.4.5 #80:AI 版本关系解释(白皮书 Feat 16)。近似重复 / hash / diff / release 对比都是确定性结果;
//  这里给「两个归档/文件之间的关系」一个稳定标签 —— 同内容副本 / 同发布新构建 / 源码 vs 二进制 / 分卷 /
//  旧备份 vs 当前 / 本地化变体。让清理视角更有用(用户看到的不是泛泛「重复」,而是具体关系)。
//
//  分类**完全确定性**(从已算好的信号:hash 组、字节数、名字 token、角色),模型只把标签变成人话。
//  纯函数,SwiftPM 可断言。
//

import Foundation

/// 两个项目之间的关系(稳定英文 token)。
nonisolated enum AIVersionRelation: String, Codable, Equatable, CaseIterable, Sendable {
    case sameContentDifferentName = "same-content-different-name"
    case sameReleaseNewBuild = "same-release-new-build"
    case sourceVsBinaryRelease = "source-vs-binary-release"
    case partialVolumeSet = "partial-volume-set"
    case oldBackupVsCurrent = "old-backup-vs-current"
    case localizedVariant = "localized-variant"
    case unrelated
}

/// 参与关系判定的一项(都是确定性、低敏信号)。
nonisolated struct AIVersionRelationItem: Codable, Equatable, Sendable {
    let id: String
    /// 文件名拆出的低敏 token(小写处理在分类器内)。
    let nameTokens: [String]
    /// 角色(AIArchiveRole rawValue),可空。
    let role: String?
    /// 同内容归一标识(如 hash 前缀);相等且非空 = 内容相同。
    let hashGroup: String?
    let byteSize: Int64?

    init(id: String, nameTokens: [String], role: String? = nil, hashGroup: String? = nil, byteSize: Int64? = nil) {
        self.id = id
        self.nameTokens = nameTokens
        self.role = role
        self.hashGroup = hashGroup
        self.byteSize = byteSize
    }
}

nonisolated enum AIVersionRelationClassifier {
    /// 两两确定性分类(固定优先级:分卷 > 同内容 > 源码vs二进制 > 本地化 > 旧备份 > 同发布新构建 > 无关)。
    static func classify(_ a: AIVersionRelationItem, _ b: AIVersionRelationItem) -> AIVersionRelation {
        let ta = a.nameTokens.map { $0.lowercased() }
        let tb = b.nameTokens.map { $0.lowercased() }
        let setA = Set(ta), setB = Set(tb)
        let shared = setA.intersection(setB)
        // 共享非版本 / 非 locale 的「主干」token(项目名),用于判断是否同一来源。
        let stems = shared.subtracting(localeTokens).filter { !isVersionToken($0) && !isVolumeToken($0) && $0.count >= 2 }
        let related = !stems.isEmpty

        // 1) 分卷集:任一方含分卷 token(001/002/part/vol)。
        if ta.contains(where: isVolumeToken) || tb.contains(where: isVolumeToken) {
            if related || sameStemIgnoringVolume(ta, tb) { return .partialVolumeSet }
        }

        // 2) 同内容:hash 组相等且非空(同 hash 必同内容,无论名字)。
        if let ha = a.hashGroup, let hb = b.hashGroup, !ha.isEmpty, ha == hb {
            return .sameContentDifferentName
        }

        // 3) 源码 vs 二进制发布:一方源码包、另一方发布/安装包,且共享主干。
        if related, isSource(a.role) != isSource(b.role),
           (isReleaseLike(a.role) || isReleaseLike(b.role)) {
            return .sourceVsBinaryRelease
        }

        // 4) 本地化变体:共享主干 + 各自带不同 locale token。
        if related {
            let la = setA.intersection(localeTokens)
            let lb = setB.intersection(localeTokens)
            if !la.isEmpty || !lb.isEmpty, la != lb { return .localizedVariant }
        }

        // 5) 旧备份 vs 当前:一方含 backup token、另一方不含,共享主干。
        if related, setA.contains("backup") != setB.contains("backup") {
            return .oldBackupVsCurrent
        }

        // 6) 同发布新构建:都像发布包、共享主干、版本 token 不同。
        if related, isReleaseLike(a.role), isReleaseLike(b.role) {
            let va = ta.filter(isVersionToken)
            let vb = tb.filter(isVersionToken)
            if (!va.isEmpty || !vb.isEmpty), va != vb { return .sameReleaseNewBuild }
        }

        return .unrelated
    }

    // MARK: - 信号判定

    private static func isSource(_ role: String?) -> Bool {
        role == AIArchiveRole.sourcePackage.rawValue
    }
    private static func isReleaseLike(_ role: String?) -> Bool {
        role == AIArchiveRole.releasePackage.rawValue || role == AIArchiveRole.installerPackage.rawValue
    }

    /// 分卷 token:3 位纯数字(001/002…)或 part / vol。
    static func isVolumeToken(_ token: String) -> Bool {
        if token == "part" || token == "vol" || token == "volume" { return true }
        return token.count == 3 && token.allSatisfy { $0.isNumber }
    }

    /// 版本 token:`1.2` / `1.2.3` / `v1.2`。
    static func isVersionToken(_ token: String) -> Bool {
        var t = token
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isNumber } }
    }

    private static func sameStemIgnoringVolume(_ a: [String], _ b: [String]) -> Bool {
        let sa = Set(a.filter { !isVolumeToken($0) && $0.count >= 2 })
        let sb = Set(b.filter { !isVolumeToken($0) && $0.count >= 2 })
        return !sa.isDisjoint(with: sb)
    }

    static let localeTokens: Set<String> = [
        "zh", "en", "ja", "ko", "fr", "de", "es", "ru", "th",
        "zh-hans", "zh-hant", "en-us", "en-gb", "pt", "it", "nl"
    ]
}
