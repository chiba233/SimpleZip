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

    @Test func redactsUnderscoreCompoundSecretKeys() {
        // 审计 #2:下划线 / 连字符复合键(snake_case)。
        #expect(!AISensitiveRedactor.redact("client_secret: abcdef123456").contains("abcdef123456"))
        #expect(!AISensitiveRedactor.redact("secret_key=AKIA1234").contains("AKIA1234"))
        #expect(!AISensitiveRedactor.redact("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI").contains("wJalrXUtnFEMI"))
        #expect(!AISensitiveRedactor.redactFileNameSecrets("secret_key=AKIA1234.pem").contains("AKIA1234"))
    }

    @Test func doesNotOverRedactNaturalLanguageDiagnostics() {
        // 审计 #4:冒号前有空格 = 自然语言诊断,不该吃掉后面的词 / 非加密条目名。
        #expect(AISensitiveRedactor.redact("ERROR: Wrong password : secret.txt").contains("secret.txt"))
        #expect(AISensitiveRedactor.redact("password : data error").contains("data error"))
    }

    @Test func redactsSpaceSeparatedLongTokens() {
        // 审计 #3:空格分隔的长 token / bearer。
        #expect(!AISensitiveRedactor.redact("denied: token abc123def456ghi").contains("abc123def456ghi"))
        #expect(!AISensitiveRedactor.redact("Authorization Bearer eyJhbGciOiJIUzI1NiJ9").contains("eyJhbGciOiJIUzI1NiJ9"))
        // 普通词(短值)不被误伤。
        #expect(AISensitiveRedactor.redact("uses a token bucket algorithm").contains("bucket"))
    }

    @Test func missingVolumeLineIsExtractedAsError() {
        let lines = AISensitiveRedactor.errorLines(from: "Scanning...\nMissing volume : release.7z.002\nDone")
        #expect(lines.contains { $0.contains("Missing volume") })
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
