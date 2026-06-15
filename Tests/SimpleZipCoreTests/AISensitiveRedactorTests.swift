//
//  AISensitiveRedactorTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:AI 上下文脱敏红线 + 错误行抽取 + 日志尾部截断。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AISensitiveRedactorTests {
    @Test func redactsArgvPasswordViaSharedSanitizer() {
        // 复用 OperationDiagnosticsReporter.sanitize 的 -p / -hp 规则。
        #expect(AISensitiveRedactor.redact("7zz x -phunter2 a.7z").contains("-p[REDACTED]"))
        #expect(!AISensitiveRedactor.redact("7zz x -phunter2 a.7z").contains("hunter2"))
        #expect(AISensitiveRedactor.redact("rar a -hpSECRET out").contains("-hp[REDACTED]"))
    }

    @Test func redactsKeyValueSecrets() {
        #expect(AISensitiveRedactor.redact("password=hunter2").contains("[REDACTED]"))
        #expect(!AISensitiveRedactor.redact("password=hunter2").contains("hunter2"))
        #expect(!AISensitiveRedactor.redact("PASSPHRASE: topsecret").contains("topsecret"))
        #expect(!AISensitiveRedactor.redact("api_key = abc123XYZ").contains("abc123XYZ"))
        #expect(!AISensitiveRedactor.redact("token: ghp_aBcDeF").contains("ghp_aBcDeF"))
    }

    @Test func redactsSpaceSeparatedOptionValues() {
        #expect(!AISensitiveRedactor.redact("gpg --passphrase topsecret file").contains("topsecret"))
        #expect(AISensitiveRedactor.redact("gpg --passphrase topsecret file").contains("[REDACTED]"))
    }

    @Test func redactsPemPrivateKeyBlock() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        secretmaterialhere
        -----END OPENSSH PRIVATE KEY-----
        """
        let out = AISensitiveRedactor.redact(pem)
        #expect(out.contains("[REDACTED PRIVATE KEY]"))
        #expect(!out.contains("secretmaterialhere"))
    }

    @Test func leavesOrdinaryTextUntouched() {
        let path = "Extracting Resources/zh-Hans.lproj/Localizable.strings"
        #expect(AISensitiveRedactor.redact(path) == path)
    }

    @Test func extractsErrorLinesOnly() {
        let output = """
        Scanning the drive for archives:
        1 file, 192 bytes (1 KiB)

        Extracting archive: mods.zip

        ERROR: Can not create output directory : Permission denied
        Everything is Ok
        """
        let lines = AISensitiveRedactor.errorLines(from: output)
        #expect(lines.contains { $0.contains("Permission denied") })
        // 非错误行不进来。
        #expect(!lines.contains { $0.contains("Scanning the drive") })
        #expect(!lines.contains { $0.contains("Everything is Ok") })
    }

    @Test func errorLinesAreCappedAndDeduped() {
        let many = (0..<50).map { _ in "ERROR: Data Error in file.bin" }.joined(separator: "\n")
        let lines = AISensitiveRedactor.errorLines(from: many, maxLines: 5)
        #expect(lines.count == 1) // 去重后只剩一条相同的
        let varied = (0..<50).map { "ERROR: file\($0) failed" }.joined(separator: "\n")
        #expect(AISensitiveRedactor.errorLines(from: varied, maxLines: 5).count == 5)
    }

    @Test func errorLinesRedactSecrets() {
        let out = AISensitiveRedactor.errorLines(from: "ERROR: auth failed password=hunter2")
        #expect(out.first?.contains("hunter2") == false)
    }

    @Test func logTailTruncatesAndRedacts() {
        let short = "Everything is Ok"
        #expect(AISensitiveRedactor.logTail(of: short) == short)

        let long = String(repeating: "x", count: 2000) + " password=hunter2"
        let tail = AISensitiveRedactor.logTail(of: long, maxChars: 500)
        #expect(tail.hasPrefix("…(earlier output truncated)"))
        #expect(!tail.contains("hunter2"))
        #expect(tail.count < 600)
    }
}
