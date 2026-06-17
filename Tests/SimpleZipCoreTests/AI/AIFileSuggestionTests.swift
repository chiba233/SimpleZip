//
//  AIFileSuggestionTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:文件浏览器「每文件行内抽屉」的 AI 建议确定性组装(AIFileSuggestion)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFileSuggestionTests {

    @Test func markdownSuggestsSummaryWithTopicFromModelShortSummary() {
        let summary = AIFileContentSummary(mode: "text-summary", headings: ["Overview", "Usage"],
                                           shortSummary: "smartcard reader case study")
        let s = AIFileSuggestion.make(fileName: "case.md", isDirectory: false, contentSummary: summary)
        #expect(s != nil)
        #expect(s?.headline == .document(topic: "smartcard reader case study"))
        #expect(s?.actions.contains(.viewSummary) == true)
        #expect(s?.detail == "Usage")                    // 大纲第二条作次要说明
        #expect(s?.provenanceTokens.first == "model")    // 有模型短摘要 → model 在前
    }

    @Test func markdownFallsBackToFirstHeadingThenGeneric() {
        let structured = AIFileContentSummary(mode: "text-summary", headings: ["Architecture"])
        let withHeading = AIFileSuggestion.make(fileName: "notes.md", isDirectory: false, contentSummary: structured)
        #expect(withHeading?.headline == .document(topic: "Architecture"))
        #expect(withHeading?.provenanceTokens == ["prefetched"])

        let bare = AIFileSuggestion.make(fileName: "notes.md", isDirectory: false)
        #expect(bare?.headline == .document(topic: nil))   // 无任何预解析 → 泛化文档
        #expect(bare?.provenanceTokens == ["instant"])
    }

    @Test func archiveSuggestsCountEncryptedAndTest() {
        let s = AIFileSuggestion.make(fileName: "release.7z", isDirectory: false,
                                      archive: .init(entryCount: 12, encrypted: true))
        #expect(s?.headline == .archive(entryCount: 12, encrypted: true))
        #expect(s?.actions.contains(.test) == true)
    }

    @Test func archiveWithNotableEntrySuggestsThatEntry() {
        let s = AIFileSuggestion.make(fileName: "bundle.zip", isDirectory: false,
                                      archive: .init(entryCount: 40, notableEntryName: "config.yaml"))
        #expect(s?.headline == .archiveWantsEntry(name: "config.yaml"))
        #expect(s?.actions.contains(.extractEntry(name: "config.yaml")) == true)
        #expect(s?.actions.contains(.previewEntry(name: "config.yaml")) == true)
    }

    @Test func signedArchiveOffersVerify() {
        let s = AIFileSuggestion.make(fileName: "payload.szs", isDirectory: false,
                                      archive: .init(entryCount: 3))
        #expect(s?.actions.contains(.verifySignature) == true)
    }

    @Test func checksumFileSuggestsVerify() {
        let s = AIFileSuggestion.make(fileName: "SHA256SUMS", isDirectory: false)
        #expect(s?.headline == .integrityFile)
        #expect(s?.actions.contains(.verifySignature) == true)
    }

    @Test func sourceCarriesLanguageAndOpenWith() {
        let s = AIFileSuggestion.make(fileName: "App.vue", isDirectory: false, betterOpenAppName: "VS Code")
        #expect(s?.headline == .sourceCode(language: "vue"))
        #expect(s?.actions.contains(.openWith(appName: "VS Code")) == true)
    }

    @Test func mediaSuggestsCompress() {
        let s = AIFileSuggestion.make(fileName: "logo.svg", isDirectory: false)
        #expect(s?.headline == .media(kind: "image"))
        #expect(s?.actions.contains(.compress) == true)
    }

    @Test func duplicateBeatsEverythingElse() {
        // 即便是归档,疑似重复也优先(最强信号)。
        let s = AIFileSuggestion.make(fileName: "release.7z", isDirectory: false,
                                      archive: .init(entryCount: 9),
                                      duplicateOfDisplayName: "release (1).7z")
        #expect(s?.headline == .duplicate(ofName: "release (1).7z"))
        #expect(s?.actions.contains(.compareDuplicate(ofName: "release (1).7z")) == true)
    }

    @Test func plainBinaryHasNothingUsefulToSay() {
        #expect(AIFileSuggestion.make(fileName: "a.out", isDirectory: false) == nil)
        #expect(AIFileSuggestion.make(fileName: "mystery.qux", isDirectory: false) == nil)
    }

    @Test func suggestionRoundTripsThroughCodable() throws {
        let s = AIFileSuggestion.make(fileName: "bundle.zip", isDirectory: false,
                                      archive: .init(entryCount: 5, notableEntryName: "x.json"))
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AIFileSuggestion?.self, from: data) == s)
    }
}
