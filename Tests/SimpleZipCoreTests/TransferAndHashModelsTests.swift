//
//  TransferAndHashModelsTests.swift
//  SimpleZipCoreTests
//
//  P1b:ArchiveTransferModels + HashModels 从 Features 下沉 Core 后补的契约测试
//  (未知 TransferAction 降级、TransferStats 合并、HashReport 纯文本汇总)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct TransferAndHashModelsTests {
    @Test func transferActionDecodesKnownRawValue() throws {
        let decoded = try JSONDecoder().decode(TransferAction.self, from: Data("\"added\"".utf8))
        #expect(decoded == .added)
    }

    @Test func transferActionUnknownValueFallsBackToChanged() throws {
        // 新版本写的未知 case 被旧版本读到 → 降级中性的 .changed,不抛错(否则废掉整段历史)。
        let decoded = try JSONDecoder().decode(TransferAction.self, from: Data("\"someFutureAction\"".utf8))
        #expect(decoded == .changed)
    }

    @Test func transferLogEntryDecodesMissingOptionalKeys() throws {
        // 旧历史没有 isDirectory / detail 键 → 安全回退,不让整段历史解码失败。
        let json = Data("{\"name\":\"a.txt\",\"action\":\"added\"}".utf8)
        let decoded = try JSONDecoder().decode(TransferLogEntry.self, from: json)
        #expect(decoded.name == "a.txt")
        #expect(decoded.action == .added)
        #expect(decoded.isDirectory == false)
        #expect(decoded.detail == nil)
    }

    @Test func transferStatsMergeSumsFields() {
        var a = TransferStats(transferred: 3, skipped: 1, sameHashSkips: 2)
        let b = TransferStats(transferred: 4, skipped: 5, sameHashSkips: 6)
        a.merge(b)
        #expect(a.transferred == 7)
        #expect(a.skipped == 6)
        #expect(a.sameHashSkips == 8)
    }

    @Test func hashReportPlainTextSummaryFormatsPathAndHashesInAlgorithmOrder() {
        let result = FileHashResult(
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            displayName: "a.txt",
            size: 10,
            hashes: [.sha256: "abc", .md5: "def"]
        )
        let report = HashReport(algorithms: [.md5, .sha256], results: [result])
        let summary = report.plainTextSummary
        #expect(summary.contains("/tmp/a.txt"))
        #expect(summary.contains("MD5: def"))
        #expect(summary.contains("SHA256: abc"))
        // 行序由 algorithms 顺序决定(MD5 在 SHA256 之前)。
        guard let md5Range = summary.range(of: "MD5: def"),
              let shaRange = summary.range(of: "SHA256: abc") else {
            Issue.record("summary missing expected hash lines")
            return
        }
        #expect(md5Range.lowerBound < shaRange.lowerBound)
    }

    @Test func hashReportAggregatesCountAndSize() {
        let a = FileHashResult(url: URL(fileURLWithPath: "/tmp/a"), displayName: "a", size: 10, hashes: [:])
        let b = FileHashResult(url: URL(fileURLWithPath: "/tmp/b"), displayName: "b", size: 32, hashes: [:])
        let report = HashReport(algorithms: [.crc32], results: [a, b])
        #expect(report.fileCount == 2)
        #expect(report.totalSize == 42)
    }
}
