//
//  ReleaseGate.swift
//  SimpleZip
//
//  0.4.4 #10:发布前质量门。每条规则三态(关 / 警告 / 阻断),默认全关 —— 行为与没有此功能时
//  完全一致。评估是纯函数(SwiftPM 可测);阻断的处置(任务失败)在发布助手流水线侧。
//

import Foundation

/// 单条规则的档位。解码容错:未知值降级 `.off`(宁可不拦,不要把旧配置变成误拦)。
nonisolated enum ReleaseGateMode: String, Codable, CaseIterable, Equatable {
    case off
    case warn
    case block

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReleaseGateMode(rawValue: raw) ?? .off
    }
}

/// 六条规则的档位集合。默认全关。
nonisolated struct ReleaseGateRules: Codable, Equatable {
    var suspiciousPaths: ReleaseGateMode = .off
    var junkFiles: ReleaseGateMode = .off
    var emptyDirectories: ReleaseGateMode = .off
    var missingChecksums: ReleaseGateMode = .off
    var missingSignature: ReleaseGateMode = .off
    var bundleIssues: ReleaseGateMode = .off

    var isAllOff: Bool {
        [suspiciousPaths, junkFiles, emptyDirectories, missingChecksums, missingSignature, bundleIssues]
            .allSatisfy { $0 == .off }
    }

    func mode(for rule: ReleaseGate.Rule) -> ReleaseGateMode {
        switch rule {
        case .suspiciousPaths: return suspiciousPaths
        case .junkFiles: return junkFiles
        case .emptyDirectories: return emptyDirectories
        case .missingChecksums: return missingChecksums
        case .missingSignature: return missingSignature
        case .bundleIssues: return bundleIssues
        }
    }

    mutating func setMode(_ mode: ReleaseGateMode, for rule: ReleaseGate.Rule) {
        switch rule {
        case .suspiciousPaths: suspiciousPaths = mode
        case .junkFiles: junkFiles = mode
        case .emptyDirectories: emptyDirectories = mode
        case .missingChecksums: missingChecksums = mode
        case .missingSignature: missingSignature = mode
        case .bundleIssues: bundleIssues = mode
        }
    }
}

nonisolated enum ReleaseGate {
    enum Rule: String, Codable, CaseIterable, Equatable {
        case suspiciousPaths
        case junkFiles
        case emptyDirectories
        case missingChecksums
        case missingSignature
        case bundleIssues
    }

    /// 评估所需的事实。计数型字段 nil = 这次没检查(检查关了)→ 对应规则不评估,
    /// 绝不把「没查」当「没问题」或「有问题」。
    struct Facts: Equatable {
        var suspiciousPathCount: Int?
        var junkCount: Int?
        var emptyDirectoryCount: Int?
        var wroteChecksums: Bool
        var signRequested: Bool
        var bundleFailureCount: Int

        init(
            suspiciousPathCount: Int? = nil,
            junkCount: Int? = nil,
            emptyDirectoryCount: Int? = nil,
            wroteChecksums: Bool = false,
            signRequested: Bool = false,
            bundleFailureCount: Int = 0
        ) {
            self.suspiciousPathCount = suspiciousPathCount
            self.junkCount = junkCount
            self.emptyDirectoryCount = emptyDirectoryCount
            self.wroteChecksums = wroteChecksums
            self.signRequested = signRequested
            self.bundleFailureCount = bundleFailureCount
        }
    }

    struct Violation: Equatable, Codable {
        let rule: Rule
        let mode: ReleaseGateMode
        /// 计数型规则带命中数(可疑路径 / 垃圾 / 空目录 / bundle 问题);开关型(校验/签名缺失)为 nil。
        let count: Int?

        var isBlocking: Bool { mode == .block }
    }

    /// 按规则档位评估事实,返回触发的违规(关着的 / 没触发的不出现)。顺序固定按 Rule 声明序。
    static func evaluate(facts: Facts, rules: ReleaseGateRules) -> [Violation] {
        var violations: [Violation] = []
        func check(_ rule: Rule, fires: Bool, count: Int? = nil) {
            let mode = rules.mode(for: rule)
            guard mode != .off, fires else { return }
            violations.append(Violation(rule: rule, mode: mode, count: count))
        }
        if let count = facts.suspiciousPathCount {
            check(.suspiciousPaths, fires: count > 0, count: count)
        }
        if let count = facts.junkCount {
            check(.junkFiles, fires: count > 0, count: count)
        }
        if let count = facts.emptyDirectoryCount {
            check(.emptyDirectories, fires: count > 0, count: count)
        }
        check(.missingChecksums, fires: !facts.wroteChecksums)
        check(.missingSignature, fires: !facts.signRequested)
        check(.bundleIssues, fires: facts.bundleFailureCount > 0, count: facts.bundleFailureCount)
        return violations
    }
}
