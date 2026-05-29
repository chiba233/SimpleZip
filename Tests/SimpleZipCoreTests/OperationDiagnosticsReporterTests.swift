//
//  OperationDiagnosticsReporterTests.swift
//  SimpleZip
//
//  钉死「诊断报告应当脱敏密码 + 报告布局稳定」契约。
//  报告会贴进 GitHub Issue，任何让密码留在里面的回归都会非常糟。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct OperationDiagnosticsReporterTests {

    // MARK: - 脱敏

    @Test
    func sanitizeStripsValueAfterDashP() {
        let text = "7zz a /tmp/out.7z -psecret-pw payload"
        let cleaned = OperationDiagnosticsReporter.sanitize(text)
        // 参数前缀保留方便排错，值整体替换成 [REDACTED]。
        #expect(cleaned == "7zz a /tmp/out.7z -p[REDACTED] payload")
    }

    @Test
    func sanitizeStripsValueAfterDashHP() {
        let text = "rar a -hpverysecret out.rar payload"
        let cleaned = OperationDiagnosticsReporter.sanitize(text)
        #expect(cleaned == "rar a -hp[REDACTED] out.rar payload")
    }

    @Test
    func sanitizeKeepsPasswordPromptLabel() {
        // 「Enter password:」这类提示行不带值，不应该被改动。
        let text = "Enter password (will not be echoed):"
        let cleaned = OperationDiagnosticsReporter.sanitize(text)
        #expect(cleaned == text)
    }

    @Test
    func sanitizeDoesNotMatchSubstringsInsideWord() {
        // 中间出现的 `-p` 不能被当成参数（比如版本号 / 别的标志的延伸）。
        let text = "lib-pkcs11.so"
        let cleaned = OperationDiagnosticsReporter.sanitize(text)
        #expect(cleaned == text)
    }

    @Test
    func sanitizeHandlesMultipleOccurrencesAcrossLines() {
        let text = """
        Step 1: 7zz a archive.7z -ppassword1 payload
        Step 2: 7zz t archive.7z -ppassword2
        """
        let cleaned = OperationDiagnosticsReporter.sanitize(text)
        // 两处都该替换；其它字符原样保留。
        #expect(cleaned.contains("-p[REDACTED] payload"))
        #expect(cleaned.contains("Step 2: 7zz t archive.7z -p[REDACTED]"))
        #expect(!cleaned.contains("password1"))
        #expect(!cleaned.contains("password2"))
    }

    // MARK: - 报告结构

    @Test
    func reportIncludesAllSectionHeaders() {
        let report = OperationDiagnosticsReporter.makeReport(from: sampleInputs())
        // 关键 section 头都要出现 —— 这样维护者一眼就能定位需要的信息。
        #expect(report.contains("SimpleZip diagnostics"))
        #expect(report.contains("App version:"))
        #expect(report.contains("macOS:"))
        #expect(report.contains("Operation:"))
        #expect(report.contains("Backends:"))
        #expect(report.contains("Command output (sanitized,"))
    }

    @Test
    func reportRedactsPasswordInRawOutput() {
        var inputs = sampleInputs()
        inputs = OperationDiagnosticsInputs(
            appVersion: inputs.appVersion,
            appBuild: inputs.appBuild,
            macOSVersion: inputs.macOSVersion,
            sevenZipDescription: inputs.sevenZipDescription,
            sevenZipVersion: inputs.sevenZipVersion,
            rarDescription: inputs.rarDescription,
            rarVersion: inputs.rarVersion,
            title: inputs.title,
            startedAt: inputs.startedAt,
            finishedAt: inputs.finishedAt,
            rawOutput: "7zz a out.7z -ptopsecret /payload",
            errorMessage: nil
        )

        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        #expect(!report.contains("topsecret"))
        #expect(report.contains("-p[REDACTED]"))
    }

    @Test
    func reportRedactsPasswordInErrorMessage() {
        var inputs = sampleInputs()
        inputs = OperationDiagnosticsInputs(
            appVersion: inputs.appVersion,
            appBuild: inputs.appBuild,
            macOSVersion: inputs.macOSVersion,
            sevenZipDescription: inputs.sevenZipDescription,
            sevenZipVersion: inputs.sevenZipVersion,
            rarDescription: inputs.rarDescription,
            rarVersion: inputs.rarVersion,
            title: inputs.title,
            startedAt: inputs.startedAt,
            finishedAt: inputs.finishedAt,
            rawOutput: inputs.rawOutput,
            errorMessage: "Command failed: 7zz a out.7z -hpsuperprivate"
        )

        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        #expect(!report.contains("superprivate"))
        #expect(report.contains("-hp[REDACTED]"))
    }

    @Test
    func reportTruncatesLongRawOutput() {
        var inputs = sampleInputs()
        let bigOutput = String(repeating: "x", count: 12_000)
        inputs = OperationDiagnosticsInputs(
            appVersion: inputs.appVersion,
            appBuild: inputs.appBuild,
            macOSVersion: inputs.macOSVersion,
            sevenZipDescription: inputs.sevenZipDescription,
            sevenZipVersion: inputs.sevenZipVersion,
            rarDescription: inputs.rarDescription,
            rarVersion: inputs.rarVersion,
            title: inputs.title,
            startedAt: inputs.startedAt,
            finishedAt: inputs.finishedAt,
            rawOutput: bigOutput,
            errorMessage: nil,
            outputTailCharacterLimit: 200
        )

        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        // 没有完整 12k bytes —— 实际报告里只保留尾段 200 字符 + 截断说明。
        #expect(report.count < 1_500)
        #expect(report.contains("(truncated)"))
    }

    @Test
    func reportFormatsDurationInMillisecondsForSubSecondOps() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = started.addingTimeInterval(0.25)
        var inputs = sampleInputs()
        inputs = OperationDiagnosticsInputs(
            appVersion: inputs.appVersion,
            appBuild: inputs.appBuild,
            macOSVersion: inputs.macOSVersion,
            sevenZipDescription: inputs.sevenZipDescription,
            sevenZipVersion: inputs.sevenZipVersion,
            rarDescription: inputs.rarDescription,
            rarVersion: inputs.rarVersion,
            title: inputs.title,
            startedAt: started,
            finishedAt: finished,
            rawOutput: "",
            errorMessage: nil
        )
        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        #expect(report.contains("(250 ms)"))
    }

    @Test
    func reportFormatsStillRunningWhenFinishedNil() {
        var inputs = sampleInputs()
        inputs = OperationDiagnosticsInputs(
            appVersion: inputs.appVersion,
            appBuild: inputs.appBuild,
            macOSVersion: inputs.macOSVersion,
            sevenZipDescription: inputs.sevenZipDescription,
            sevenZipVersion: inputs.sevenZipVersion,
            rarDescription: inputs.rarDescription,
            rarVersion: inputs.rarVersion,
            title: inputs.title,
            startedAt: inputs.startedAt,
            finishedAt: nil,
            rawOutput: "",
            errorMessage: nil
        )
        let report = OperationDiagnosticsReporter.makeReport(from: inputs)
        #expect(report.contains("still running"))
    }

    // MARK: - 辅助

    private func sampleInputs() -> OperationDiagnosticsInputs {
        OperationDiagnosticsInputs(
            appVersion: "0.1.6",
            appBuild: "42",
            macOSVersion: "14.5 (23F79)",
            sevenZipDescription: "Bundled /Apps/SimpleZip/Tools/7zz",
            sevenZipVersion: "7-Zip (z) 26.01 (arm64)",
            rarDescription: "Not installed",
            rarVersion: "n/a",
            title: "Creating Archive.zip",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            rawOutput: "Everything is OK",
            errorMessage: nil
        )
    }
}
