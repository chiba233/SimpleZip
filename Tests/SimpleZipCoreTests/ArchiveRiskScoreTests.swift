//
//  ArchiveRiskScoreTests.swift
//  SimpleZipCoreTests
//
//  #18 归档安全评分:bucket-max 定级(最严重一档定 A/B/C)、确定排序、加密中性、信号映射。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchiveRiskScoreTests {
    private func finding(_ kind: ArchiveSecurityFindingKind, count: Int = 1) -> ArchiveSecurityFinding {
        ArchiveSecurityFinding(kind: kind, entryPaths: (0..<count).map { "entry\($0)" })
    }

    @Test func cleanArchiveIsGradeA() {
        let result = ArchiveRiskScore.assess(findings: [])
        #expect(result.grade == .a)
        #expect(result.level == .low)
        #expect(result.contributions.isEmpty)
        #expect(result.dominant == nil)
    }

    @Test func highSeverityFindingForcesGradeC() {
        // 路径逃逸 = 高严重度 → C/高,哪怕只有一条。
        let result = ArchiveRiskScore.assess(findings: [finding(.externalSymlink)])
        #expect(result.grade == .c)
        #expect(result.level == .high)
        #expect(result.dominant?.dimension == .externalSymlink)
    }

    @Test func mediumSeverityFindingIsGradeB() {
        let result = ArchiveRiskScore.assess(findings: [finding(.duplicateEntryPath)])
        #expect(result.grade == .b)
        #expect(result.level == .medium)
    }

    @Test func cosmeticOnlyStaysGradeA() {
        // 保留名 + 段尾空格点 + macOS 垃圾 = 全是 low → 仍 A(不被鸡毛蒜皮放大)。
        let result = ArchiveRiskScore.assess(
            findings: [finding(.windowsReservedName), finding(.trailingSpaceOrDot)],
            junkCount: 40
        )
        #expect(result.grade == .a)
        #expect(result.contributions.count == 3)   // 列出来,但不拉低等级
    }

    @Test func encryptionIsNeutralNeverLowersGrade() {
        // 已加密 = info,绝不拉低等级:纯加密包仍是 A。
        let result = ArchiveRiskScore.assess(findings: [], encryptedCount: 5)
        #expect(result.grade == .a)
        #expect(result.contributions.first?.dimension == .encrypted)
        #expect(result.contributions.first?.severity == .info)
        #expect(result.dominant == nil)            // info 不算「拉低等级」的主导项
    }

    @Test func missingVolumesAndCorruptionAreHigh() {
        #expect(ArchiveRiskScore.assess(findings: [], missingVolumeCount: 1).grade == .c)
        #expect(ArchiveRiskScore.assess(findings: [], isCorrupted: true).grade == .c)
    }

    @Test func contributionsSortBySeverityThenCount() {
        let result = ArchiveRiskScore.assess(
            findings: [finding(.trailingSpaceOrDot, count: 9), finding(.externalSymlink, count: 1), finding(.duplicateEntryPath, count: 3)],
            encryptedCount: 2
        )
        // 高(symlink) → 中(duplicate) → 低(trailing) → info(encrypted)
        let order = result.contributions.map(\.dimension)
        #expect(order == [.externalSymlink, .duplicateEntryPath, .trailingSpaceOrDot, .encrypted])
        #expect(result.grade == .c)
    }

    @Test func findingKindRawValuesMapToDimensions() {
        // 14 类安全发现 rawValue 必须都能映射到同名维度,否则评级会漏掉某类风险。
        for kind in ArchiveSecurityFindingKind.allCases {
            #expect(ArchiveRiskScore.Dimension(rawValue: kind.rawValue) != nil, "未映射: \(kind.rawValue)")
        }
    }
}
