//
//  ReportExportTests.swift
//  SimpleZipCoreTests
//
//  0.4.4 F2:统一报告导出底座 —— 元数据页脚 / GitHub Issue 正文 / JSON 编码器确定性。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ReportExportTests {
    private let metadata = ReportMetadata(
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
        targetPath: "/Users/me/Release/MyApp.zip",
        appVersion: "0.4.4",
        macOSVersion: "Version 26.0 (Build 25A000)",
        backendVersion: "7-Zip (z) 24.09"
    )

    @Test func markdownFooterCarriesVersionsAndPath() {
        let footer = ReportExport.markdownFooter(metadata)
        #expect(footer.contains("SimpleZip 0.4.4"))
        #expect(footer.contains("7-Zip (z) 24.09"))
        #expect(footer.contains("/Users/me/Release/MyApp.zip"))
        #expect(footer.contains("---"))
    }

    @Test func markdownFooterOmitsMissingTargetPath() {
        let bare = ReportMetadata(
            generatedAt: metadata.generatedAt,
            targetPath: nil,
            appVersion: "0.4.4",
            macOSVersion: "x",
            backendVersion: "y"
        )
        let footer = ReportExport.markdownFooter(bare)
        #expect(!footer.contains("· /"))
    }

    @Test func issueBodyHasEnvironmentTableAndCollapsedReport() {
        let body = ReportExport.gitHubIssueBody(
            title: "Release Inspection — MyApp.zip",
            summaryLine: "3 findings, 1 blocking",
            reportMarkdown: "## Findings\n- junk file found",
            metadata: metadata
        )
        #expect(body.contains("### Environment"))
        #expect(body.contains("| SimpleZip | 0.4.4 |"))
        #expect(body.contains("| macOS | Version 26.0 (Build 25A000) |"))
        #expect(body.contains("| 7-Zip backend | 7-Zip (z) 24.09 |"))
        #expect(body.contains("### Release Inspection — MyApp.zip"))
        #expect(body.contains("3 findings, 1 blocking"))
        #expect(body.contains("<details><summary>Full report</summary>"))
        #expect(body.contains("- junk file found"))
        #expect(body.contains("</details>"))
    }

    @Test func jsonEncoderIsDeterministic() throws {
        struct Sample: Codable { let b: Int; let a: String; let when: Date }
        let sample = Sample(b: 2, a: "x", when: Date(timeIntervalSince1970: 1_750_000_000))
        let first = try ReportExport.jsonEncoder().encode(sample)
        let second = try ReportExport.jsonEncoder().encode(sample)
        #expect(first == second)
        let text = String(data: first, encoding: .utf8) ?? ""
        // sortedKeys:a 在 b 前;ISO8601 日期字符串。
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"b\"")!.lowerBound)
        #expect(text.contains("2025") || text.contains("2026"))
    }

    @Test func metadataRoundTripsThroughCodable() throws {
        let data = try ReportExport.jsonEncoder().encode(metadata)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReportMetadata.self, from: data)
        #expect(decoded.appVersion == metadata.appVersion)
        #expect(decoded.targetPath == metadata.targetPath)
        #expect(decoded.backendVersion == metadata.backendVersion)
    }
}
