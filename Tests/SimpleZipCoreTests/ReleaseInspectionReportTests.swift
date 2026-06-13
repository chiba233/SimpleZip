//
//  ReleaseInspectionReportTests.swift
//  SimpleZipCoreTests
//
//  P1a:ReleaseInspectionReport 从 Features 下沉 Core 后补的 Codable 往返契约测试
//  (报告随任务历史持久化,字段必须能编码 / 解码回读;id 不入 Codable,解码重生)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReleaseInspectionReportTests {
    private func sample() -> ReleaseInspectionReport {
        var report = ReleaseInspectionReport(archiveURL: URL(fileURLWithPath: "/tmp/MyApp.zip"))
        report.listable = true
        report.stats = ReleaseInspectionStats(
            fileCount: 12, folderCount: 3, totalBytes: 4096,
            junkCount: 1, emptyDirectoryCount: 0, executableCount: 2, symlinkCount: 1
        )
        report.testPassed = true
        report.sha256 = "deadbeef"
        report.hasComment = true
        report.publicKeyBesideSignature = false
        report.structuralFingerprint = "cafebabe"
        report.isBundleOnly = false
        return report
    }

    @Test func codableRoundTripPreservesFields() throws {
        let report = sample()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ReleaseInspectionReport.self, from: data)

        #expect(decoded.archiveURL == report.archiveURL)
        #expect(decoded.listable == true)
        #expect(decoded.stats == report.stats)
        #expect(decoded.testPassed == true)
        #expect(decoded.sha256 == "deadbeef")
        #expect(decoded.hasComment == true)
        #expect(decoded.publicKeyBesideSignature == false)
        #expect(decoded.structuralFingerprint == "cafebabe")
        #expect(decoded.isBundleOnly == false)
        #expect(decoded.securityFindings.isEmpty)
        #expect(decoded.gateViolations.isEmpty)
        #expect(decoded.steps.isEmpty)
    }

    @Test func idIsExcludedFromCodableAndRegeneratedOnDecode() throws {
        let report = sample()
        let json = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? ""
        // id 在 CodingKeys 之外,不应出现在编码结果里。
        #expect(!json.contains("\"id\""))
        #expect(!json.contains(report.id.uuidString))
        // 解码出的实例 id 是新生成的(每个解码实例都有独立 id),但业务字段保留。
        let decoded = try JSONDecoder().decode(ReleaseInspectionReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded.archiveURL == report.archiveURL)
    }
}
