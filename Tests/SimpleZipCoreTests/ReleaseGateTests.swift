//
//  ReleaseGateTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 #10:质量门 —— 三态评估 / 「没查 ≠ 没问题」/ 解码容错。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseGateTests {
    @Test func allOffFiresNothing() {
        let facts = ReleaseGate.Facts(suspiciousPathCount: 5, junkCount: 3, emptyDirectoryCount: 2,
                                      wroteChecksums: false, signRequested: false, bundleFailureCount: 1)
        #expect(ReleaseGate.evaluate(facts: facts, rules: ReleaseGateRules()).isEmpty)
        #expect(ReleaseGateRules().isAllOff)
    }

    @Test func warnAndBlockSeparateCorrectly() {
        var rules = ReleaseGateRules()
        rules.suspiciousPaths = .block
        rules.junkFiles = .warn
        let facts = ReleaseGate.Facts(suspiciousPathCount: 2, junkCount: 7)
        let violations = ReleaseGate.evaluate(facts: facts, rules: rules)
        #expect(violations.count == 2)
        #expect(violations[0].rule == .suspiciousPaths && violations[0].isBlocking && violations[0].count == 2)
        #expect(violations[1].rule == .junkFiles && !violations[1].isBlocking && violations[1].count == 7)
    }

    @Test func cleanFactsFireNothingEvenWhenArmed() {
        var rules = ReleaseGateRules()
        rules.suspiciousPaths = .block
        rules.junkFiles = .block
        rules.emptyDirectories = .block
        rules.missingChecksums = .block
        rules.missingSignature = .block
        let facts = ReleaseGate.Facts(suspiciousPathCount: 0, junkCount: 0, emptyDirectoryCount: 0,
                                      wroteChecksums: true, signRequested: true)
        #expect(ReleaseGate.evaluate(facts: facts, rules: rules).isEmpty)
    }

    @Test func nilCountsAreNotEvaluated() {
        // 检查没跑(计数 nil)→ 计数型规则不评估,绝不把「没查」当违规或当干净。
        var rules = ReleaseGateRules()
        rules.suspiciousPaths = .block
        rules.junkFiles = .block
        rules.missingChecksums = .block
        let facts = ReleaseGate.Facts(suspiciousPathCount: nil, junkCount: nil, wroteChecksums: false)
        let violations = ReleaseGate.evaluate(facts: facts, rules: rules)
        #expect(violations.map(\.rule) == [.missingChecksums])
    }

    @Test func missingSignatureFiresOnlyWhenNotRequested() {
        var rules = ReleaseGateRules()
        rules.missingSignature = .warn
        let unsigned = ReleaseGate.Facts(signRequested: false)
        let signed = ReleaseGate.Facts(signRequested: true)
        #expect(ReleaseGate.evaluate(facts: unsigned, rules: rules).count == 1)
        #expect(ReleaseGate.evaluate(facts: signed, rules: rules).isEmpty)
    }

    @Test func unknownModeDecodesAsOff() throws {
        let json = #"{"suspiciousPaths":"detonate","junkFiles":"warn","emptyDirectories":"off","missingChecksums":"block","missingSignature":"off","bundleIssues":"off"}"#
        let rules = try JSONDecoder().decode(ReleaseGateRules.self, from: Data(json.utf8))
        #expect(rules.suspiciousPaths == .off)
        #expect(rules.junkFiles == .warn)
        #expect(rules.missingChecksums == .block)
    }

    @Test func rulesRoundTripThroughCodable() throws {
        var rules = ReleaseGateRules()
        rules.emptyDirectories = .warn
        rules.bundleIssues = .block
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode(ReleaseGateRules.self, from: data)
        #expect(decoded == rules)
        #expect(!decoded.isAllOff)
    }
}
