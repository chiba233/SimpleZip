//
//  ArchivePasswordContextHintTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:密码上下文提示(白皮书 Feat 26,非 AI)。重点:绝不显示疑似口令值、永远需手动确认。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct ArchivePasswordContextHintTests {
    @Test func buildsHintsFromLowSensitivitySources() {
        let hints = ArchivePasswordContextHintBuilder.hints(
            archiveID: "arch-1",
            filenameTokens: ["minecraft", "mods"],
            folderTokens: ["downloads"],
            whereFromDomains: ["moe-anime.com"])
        #expect(hints.contains { $0.hintKind == .domainToken && $0.displayText == "moe-anime.com" })
        #expect(hints.contains { $0.hintKind == .filenameToken && $0.displayText == "minecraft" })
        #expect(hints.contains { $0.hintKind == .folderToken && $0.displayText == "downloads" })
    }

    @Test func everyHintRequiresUserClick() {
        let hints = ArchivePasswordContextHintBuilder.hints(
            archiveID: "a", filenameTokens: ["x"], whereFromDomains: ["y.com"])
        #expect(hints.allSatisfy { $0.requiresUserClick })
    }

    @Test func rejectsAssignmentFormSecrets() {
        // 「password=hunter2」「token: abc」绝不显示。
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("password=hunter2"))
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("token: abc.def"))
        let hints = ArchivePasswordContextHintBuilder.hints(
            archiveID: "a", filenameTokens: ["password=hunter2", "minecraft"])
        #expect(!hints.contains { $0.displayText.contains("hunter2") })
        #expect(hints.contains { $0.displayText == "minecraft" })
    }

    @Test func rejectsSecretMarkerWords() {
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("mypassword"))
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("api_key_thing"))
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("SECRET"))
    }

    @Test func rejectsHighEntropyLongStrings() {
        // 长且字母+数字+符号混合(典型随机口令片段)。
        #expect(ArchivePasswordContextHintBuilder.looksLikeSecret("aB3$xK9!mZ2#qW7&pL4@nR1"))
        // 普通长单词(无数字无符号)不算 secret。
        #expect(!ArchivePasswordContextHintBuilder.looksLikeSecret("internationalization"))
    }

    @Test func allowsOrdinaryTokens() {
        #expect(!ArchivePasswordContextHintBuilder.looksLikeSecret("minecraft"))
        #expect(!ArchivePasswordContextHintBuilder.looksLikeSecret("release"))
        #expect(!ArchivePasswordContextHintBuilder.looksLikeSecret("moe-anime.com"))
        #expect(!ArchivePasswordContextHintBuilder.looksLikeSecret("v0.4.5"))
    }

    @Test func dedupesAndSkipsEmpty() {
        let hints = ArchivePasswordContextHintBuilder.hints(
            archiveID: "a", filenameTokens: ["dup", "dup", "  ", ""])
        #expect(hints.filter { $0.displayText == "dup" }.count == 1)
        #expect(!hints.contains { $0.displayText.isEmpty })
    }

    @Test func codableRoundTrip() throws {
        let hint = ArchivePasswordContextHint(
            archiveID: "a", hintKind: .domainToken, displayText: "x.com", sourceDescription: "where-from URL domain")
        let decoded = try JSONDecoder().decode(ArchivePasswordContextHint.self, from: JSONEncoder().encode(hint))
        #expect(decoded == hint)
        #expect(decoded.requiresUserClick)
    }
}
