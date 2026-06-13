//
//  ReproducibilityReportTests.swift
//  SimpleZipCoreTests
//
//  #43 可复现深度报告:因素状态如实(zip/tar 差异、可复现开/关)、二次打包 identical 判定。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReproducibilityReportTests {
    private func status(_ report: ReproducibilityReport, _ factor: ReproducibilityReport.Factor) -> ReproducibilityReport.FactorStatus? {
        report.factors.first { $0.factor == factor }?.status
    }

    @Test func zipReproducibleStripsTimeAndNormalizesOrder() {
        let report = ReproducibilityReport.analyze(format: .zip, reproducibleEnabled: true)
        #expect(status(report, .timestamp) == .stripped)
        #expect(status(report, .entryOrder) == .normalized)
        #expect(status(report, .permissions) == .storedAsIs)   // 如实:不归一化权限
        #expect(status(report, .ownerGroup) == .notApplicable)  // zip 不携带
        #expect(status(report, .xattr) == .notApplicable)
        #expect(report.identical == nil)                        // 未跑实证
    }

    @Test func reproducibleOffKeepsTimestamp() {
        let report = ReproducibilityReport.analyze(format: .zip, reproducibleEnabled: false)
        #expect(status(report, .timestamp) == .storedAsIs)
    }

    @Test func tarCarriesOwnerGroupAndXattr() {
        let report = ReproducibilityReport.analyze(format: .tar, reproducibleEnabled: true)
        #expect(status(report, .ownerGroup) == .storedAsIs)
        #expect(status(report, .xattr) == .storedAsIs)
        #expect(status(report, .entryOrder) == .storedAsIs)     // tar 按喂入顺序
        #expect(report.nonReproducibleFactors.contains(.ownerGroup))
    }

    @Test func identicalReflectsDoublePackHashes() {
        var report = ReproducibilityReport.analyze(format: .zip, reproducibleEnabled: true)
        report.firstSHA256 = "abc"
        report.secondSHA256 = "abc"
        #expect(report.identical == true)
        report.secondSHA256 = "def"
        #expect(report.identical == false)
    }

    @Test func nonReproducibleFactorsAreTheStoredAsIsOnes() {
        let report = ReproducibilityReport.analyze(format: .zip, reproducibleEnabled: true)
        // zip 可复现:只有 permissions 是 storedAsIs。
        #expect(report.nonReproducibleFactors == [.permissions])
    }
}
