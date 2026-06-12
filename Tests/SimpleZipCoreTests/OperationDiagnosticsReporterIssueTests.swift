import Foundation
import Testing
@testable import SimpleZipCore

/// #17 GitHub Issue 模板 —— 区块齐全 + 复用同一套脱敏。
struct OperationDiagnosticsReporterIssueTests {

    @Test func issueMarkdownHasSectionsAndSanitizes() {
        let inputs = OperationDiagnosticsInputs(
            appVersion: "1.0", appBuild: "7", macOSVersion: "macOS 26",
            sevenZipDescription: "bundled", sevenZipVersion: "26.01",
            rarDescription: "none", rarVersion: "-",
            title: "Extract foo.zip",
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 60),
            rawOutput: "line1\n-pSecretPass123 should vanish\nline3",
            errorMessage: "boom -pSecretPass123",
            fileSystemSummary: "temp volume: 1 GB free of 2 GB"
        )
        let markdown = OperationDiagnosticsReporter.makeGitHubIssueMarkdown(from: inputs)
        #expect(markdown.contains("### Environment"))
        #expect(markdown.contains("### Steps to reproduce"))
        #expect(markdown.contains("| SimpleZip | 1.0 (build 7) |"))
        #expect(markdown.contains("Extract foo.zip"))
        #expect(markdown.contains("### File system"))
        #expect(!markdown.contains("SecretPass123"))
    }
}
