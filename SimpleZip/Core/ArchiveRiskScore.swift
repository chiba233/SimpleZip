//
//  ArchiveRiskScore.swift
//  SimpleZip
//
//  0.4.4 #18:归档安全评分(规则系统,A/B/C ↔ 低/中/高)。
//
//  **红线**:纯规则、确定性、可测 —— 绝不让 AI 判安全(AI 只解释/分类/建议)。把已有的安全发现
//  (`ArchiveSecurityReport.analyze` 的 14 类)+ 4 个额外信号(加密 / macOS 垃圾 / 缺分卷 / 损坏)
//  按固定严重度分桶,**取最严重的一档**定级。对普通用户最好解释(「按发现的最严重问题定级」),
//  且不会被「一堆鸡毛蒜皮」放大成高风险。加密是中性信息(列出但绝不拉低等级 —— 加密 ≠ 不安全)。
//

import Foundation

nonisolated enum ArchiveRiskScore {

    /// 维度严重度。`info` 是中性信息(展示但不参与定级)。
    enum Severity: Int, Codable, Comparable, CaseIterable {
        case info = 0      // 中性(如已加密)—— 列出但不拉低等级
        case low = 1       // 表层 / 跨平台外观问题(垃圾、保留名、段尾空格点)
        case medium = 2    // 解压可能静默互覆 / 跨平台失败
        case high = 3      // 真实解压安全风险 / 归档不完整 / 损坏
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 字母等级。`level` 给只认「低/中/高」的展示(1:1 映射)。
    enum Grade: String, Codable {
        case a, b, c
        var level: Level {
            switch self {
            case .a: return .low
            case .b: return .medium
            case .c: return .high
            }
        }
    }

    enum Level: String, Codable { case low, medium, high }

    /// 参与评级的维度。前 14 个 rawValue **与 `ArchiveSecurityFindingKind` 对齐**(可直接按 rawValue 映射,
    /// 也能复用现成的 `security.kind.*` 文案);后 4 个是安全发现之外、由调用方传入的信号。
    enum Dimension: String, Codable, CaseIterable {
        case absolutePath, parentTraversal, windowsDrivePath, uncPath, backslashPath,
             controlCharacters, overlongPath, setuidExecutable, externalSymlink,
             caseCollision, duplicateEntryPath, normalizationCollision,
             windowsReservedName, trailingSpaceOrDot
        case encrypted, macOSJunk, missingVolumes, corrupted

        var severity: Severity {
            switch self {
            // 真实解压安全风险 / 归档不完整 / 损坏。
            case .externalSymlink, .absolutePath, .parentTraversal, .uncPath,
                 .controlCharacters, .setuidExecutable, .missingVolumes, .corrupted:
                return .high
            // 跨平台静默互覆 / 解压失败。
            case .windowsDrivePath, .backslashPath, .caseCollision, .duplicateEntryPath,
                 .normalizationCollision, .overlongPath:
                return .medium
            // 表层 / 外观。
            case .windowsReservedName, .trailingSpaceOrDot, .macOSJunk:
                return .low
            // 中性信息。
            case .encrypted:
                return .info
            }
        }
    }

    struct Contribution: Equatable, Codable {
        let dimension: Dimension
        let count: Int
        var severity: Severity { dimension.severity }
    }

    struct Assessment: Equatable, Codable {
        let grade: Grade
        /// 严重度高→低,同档 count 高→低,完全确定序(测试与展示稳定)。
        let contributions: [Contribution]
        var level: Level { grade.level }
        /// 决定等级的最严重维度(只看会拉低等级的项,即非 info);完全干净 = nil。
        var dominant: Contribution? { contributions.first { $0.severity != .info } }
    }

    /// 评级。`findings` 来自 `ArchiveSecurityReport.analyze`;其余信号由各报告面按自身可得情况传入
    /// (拿不到的传 0 / false —— 例如安全报告面不跑完整性测试,`isCorrupted` 就传 false)。
    static func assess(
        findings: [ArchiveSecurityFinding],
        encryptedCount: Int = 0,
        junkCount: Int = 0,
        missingVolumeCount: Int = 0,
        isCorrupted: Bool = false
    ) -> Assessment {
        var contributions: [Contribution] = []
        // 14 类安全发现 → 同名维度(rawValue 对齐,映射不到的跳过 = 不影响定级)。
        for finding in findings {
            guard let dimension = Dimension(rawValue: finding.kind.rawValue) else { continue }
            contributions.append(Contribution(dimension: dimension, count: finding.entryPaths.count))
        }
        if encryptedCount > 0 { contributions.append(Contribution(dimension: .encrypted, count: encryptedCount)) }
        if junkCount > 0 { contributions.append(Contribution(dimension: .macOSJunk, count: junkCount)) }
        if missingVolumeCount > 0 { contributions.append(Contribution(dimension: .missingVolumes, count: missingVolumeCount)) }
        if isCorrupted { contributions.append(Contribution(dimension: .corrupted, count: 1)) }

        // 确定序:严重度高→低 → count 高→低 → 维度声明序兜底。
        let declOrder = Dimension.allCases.enumerated().reduce(into: [Dimension: Int]()) { $0[$1.element] = $1.offset }
        contributions.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (declOrder[lhs.dimension] ?? 0) < (declOrder[rhs.dimension] ?? 0)
        }

        // 取最严重一档定级:high→C,medium→B,只有 low/info 或完全为空→A。
        let topSeverity = contributions.map(\.severity).max() ?? .info
        let grade: Grade
        switch topSeverity {
        case .high: grade = .c
        case .medium: grade = .b
        case .low, .info: grade = .a
        }
        return Assessment(grade: grade, contributions: contributions)
    }
}
