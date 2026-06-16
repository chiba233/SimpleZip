//
//  AIThemeSuppressionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80 #89:不感兴趣 = 永久降权 + 随时间衰减(白皮书建议四)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIThemeSuppressionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func fp(tokens: [String], refs: [String], roles: [String], locs: [String])
        -> AIWorkspaceThemeFingerprint {
        AIWorkspaceThemeFingerprint.make(
            themeTokens: tokens,
            sourceRefs: refs.map { AIContextSourceRef(kind: .file, id: $0) },
            dominantRoleTags: roles, locationKinds: locs)
    }

    private func paperFP(refs: [String] = ["r1", "r2", "r3"]) -> AIWorkspaceThemeFingerprint {
        fp(tokens: ["paper", "docs"], refs: refs, roles: ["document"], locs: ["desktop"])
    }

    @Test func freshDismissalHasHighWeightThenDecays() {
        let ledger = AIThemeSuppressionLedger().recordingDismissal(paperFP(), at: now)
        // 刚点:≈ 基础权重 0.6。
        #expect(abs(ledger.suppressionWeight(for: paperFP(), now: now) - 0.6) < 0.0001)
        // 一个半衰期(10 天)后:≈ 0.3。
        let wHalfLife = ledger.suppressionWeight(for: paperFP(), now: now.addingTimeInterval(10 * day))
        #expect(abs(wHalfLife - 0.3) < 0.0001)
        // 远期(40 天)后衰减到地板以下 → 可重新浮现。
        let wFar = ledger.suppressionWeight(for: paperFP(), now: now.addingTimeInterval(40 * day))
        #expect(wFar < AIThemeSuppressionPolicy.resurfaceFloor)
    }

    @Test func repeatedDismissalsRememberLongerAndStronger() {
        let once = AIThemeSuppressionLedger().recordingDismissal(paperFP(), at: now)
        let twice = once.recordingDismissal(paperFP(), at: now)
        // 同一指纹再次不感兴趣 → bump 次数,不新增记录。
        #expect(twice.records.count == 1)
        #expect(twice.records[0].dismissCount == 2)
        // 次数越多:基础权重更高 + 半衰期更长 → 同样过 14 天,二次的残留权重明显更高。
        let later = now.addingTimeInterval(14 * day)
        let wOnce = once.suppressionWeight(for: paperFP(), now: later)
        let wTwice = twice.suppressionWeight(for: paperFP(), now: later)
        #expect(wTwice > wOnce)
    }

    @Test func fuzzyMatchCatchesSlightlyChangedFingerprint() {
        // 不感兴趣时 3 个 ref;下一轮主题多了一个文件(4 个 ref)→ 指纹微变,仍应命中抑制。
        let ledger = AIThemeSuppressionLedger().recordingDismissal(paperFP(refs: ["r1", "r2", "r3"]), at: now)
        let changed = paperFP(refs: ["r1", "r2", "r3", "r4"])
        #expect(ledger.suppressionWeight(for: changed, now: now) > 0.5)
    }

    @Test func differentDomainThemeNotSuppressed() {
        let ledger = AIThemeSuppressionLedger().recordingDismissal(paperFP(), at: now)
        // 角色 + 位置都无交集 → 不算同主题 → 不被抑制。
        let release = fp(tokens: ["release", "verify"], refs: ["x1", "x2"], roles: ["archive"], locs: ["downloads"])
        #expect(ledger.suppressionWeight(for: release, now: now) == 0)
    }

    @Test func nilFingerprintNeverSuppressed() {
        let ledger = AIThemeSuppressionLedger().recordingDismissal(paperFP(), at: now)
        #expect(ledger.suppressionWeight(for: nil, now: now) == 0)
    }

    @Test func partitionDropsFreshlyDismissedKeepsDecayed() {
        let ledger = AIThemeSuppressionLedger()
            .recordingDismissal(paperFP(), at: now)                       // 刚点 → 抑制
            .recordingDismissal(fp(tokens: ["old"], refs: ["o1"], roles: ["media"], locs: ["documents"]),
                                at: now.addingTimeInterval(-60 * day))     // 60 天前 → 已衰减
        let themes = [
            AIWorkspaceThemeCandidate(id: "paper", titleSeed: "我的论文", themeTokens: ["paper", "docs"],
                                      scoreSignals: ["a"], fingerprint: paperFP()),
            AIWorkspaceThemeCandidate(id: "old", titleSeed: "旧主题", themeTokens: ["old"],
                                      scoreSignals: ["a"],
                                      fingerprint: fp(tokens: ["old"], refs: ["o1"], roles: ["media"], locs: ["documents"]))
        ]
        let result = ledger.partition(themes, now: now)
        #expect(result.kept.map(\.id) == ["old"])          // 衰减的重新浮现
        #expect(result.suppressed.map(\.candidate.id) == ["paper"])  // 刚点的被压
    }

    @Test func prunedDropsFullyDecayedRecords() {
        let ledger = AIThemeSuppressionLedger()
            .recordingDismissal(paperFP(), at: now.addingTimeInterval(-90 * day))   // 早就衰减
        #expect(ledger.records.count == 1)
        #expect(ledger.pruned(now: now).records.isEmpty)
    }

    @Test func ledgerCodableRoundTrips() throws {
        let ledger = AIThemeSuppressionLedger().recordingDismissal(paperFP(), at: now)
        let data = try JSONEncoder().encode(ledger)
        let back = try JSONDecoder().decode(AIThemeSuppressionLedger.self, from: data)
        #expect(back == ledger)
    }
}
