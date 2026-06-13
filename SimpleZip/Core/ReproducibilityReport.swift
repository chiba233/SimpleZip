//
//  ReproducibilityReport.swift
//  SimpleZip
//
//  0.4.4 #43:可复现构建深度报告。在现有可复现压缩(`-mtm=off` 剥离修改时间 + 7zz 确定性排序)之上,
//  把影响可复现性的各因素**如实**列出,再配一个二次打包实证(同输入打两次、比 SHA-256 是否逐字节相同)。
//
//  诚实原则:因素状态反映 SimpleZip **实际做了什么**,不夸大成「全套归一化」。当前可复现模式只剥时间戳 +
//  靠 7zz 排序;权限位原样保留;zip/7z 不携带 owner/group / xattr。实证(双打包哈希一致)才是可复现的硬证据。
//

import Foundation

nonisolated struct ReproducibilityReport: Equatable, Identifiable {
    let id = UUID()

    enum FactorStatus: String, Codable, Equatable {
        case normalized     // 已归一(确定性)
        case stripped       // 已剥离(不写入产物)
        case storedAsIs     // 原样保留(输入变 → 产物变,当前不归一)
        case notApplicable  // 该格式不涉及此项
    }

    enum Factor: String, Codable, Equatable, CaseIterable {
        case timestamp      // 文件时间戳来源
        case entryOrder     // 条目排序规则
        case permissions    // 权限位归一化
        case ownerGroup     // owner / group 归一化
        case xattr          // 扩展属性是否剥离
    }

    struct FactorResult: Equatable, Identifiable {
        let factor: Factor
        let status: FactorStatus
        var id: String { factor.rawValue }
    }

    let formatRawValue: String
    let reproducibleEnabled: Bool
    let factors: [FactorResult]
    // 二次打包实证(nil = 未跑)。
    var firstSHA256: String?
    var secondSHA256: String?

    /// 两次打包是否逐字节相同(实证可复现)。nil = 未跑实证。
    var identical: Bool? {
        guard let first = firstSHA256, let second = secondSHA256 else { return nil }
        return first == second
    }

    /// 可能破坏可复现的因素:`storedAsIs` 的项(原样保留 → 输入这些一变,产物就变)。
    /// 实证不一致时,优先看这些;实证一致说明本次输入里这些项恰好稳定。
    var nonReproducibleFactors: [Factor] {
        factors.filter { $0.status == .storedAsIs }.map(\.factor)
    }

    static func analyze(format: ArchiveCreateFormat, reproducibleEnabled: Bool) -> ReproducibilityReport {
        let isTarFamily = (format == .tar || format == .tarGzip)
        func status(_ factor: Factor) -> FactorStatus {
            switch factor {
            case .timestamp:
                return reproducibleEnabled ? .stripped : .storedAsIs
            case .entryOrder:
                // 7zz 对 zip/7z 确定性排序;tar 按喂入顺序(SimpleZip 不额外归一)。
                return isTarFamily ? .storedAsIs : .normalized
            case .permissions:
                // SimpleZip 不归一化权限位(原样保留)。
                return .storedAsIs
            case .ownerGroup:
                // zip / 7z 不携带 owner/group;tar 携带且不归一。
                return isTarFamily ? .storedAsIs : .notApplicable
            case .xattr:
                // zip / 7z(经 7zz)不存 macOS xattr;tar 可经 AppleDouble 携带,不归一。
                return isTarFamily ? .storedAsIs : .notApplicable
            }
        }
        return ReproducibilityReport(
            formatRawValue: format.rawValue,
            reproducibleEnabled: reproducibleEnabled,
            factors: Factor.allCases.map { FactorResult(factor: $0, status: status($0)) }
        )
    }
}
