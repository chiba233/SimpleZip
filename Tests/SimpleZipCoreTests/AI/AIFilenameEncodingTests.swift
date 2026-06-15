//
//  AIFilenameEncodingTests.swift
//  SimpleZipCoreTests
//
//  0.4.5 #80:乱码文件名候选编码确定性评分(白皮书 Feat 24)。确定性候选解码 + 评分,AI 只在候选间排序。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIFilenameEncodingTests {
    // Shift-JIS "テスト"(片假名 test):テ=83 65, ス=83 58, ト=83 67。
    private let shiftJISTesuto: [UInt8] = [0x83, 0x65, 0x83, 0x58, 0x83, 0x67]
    // 纯 ASCII "test.txt"。
    private let asciiName: [UInt8] = Array("test.txt".utf8)

    @Test func shiftJISMojibakeRanksShiftJISTop() {
        let decodes = MojibakeEncodingScorer.decode(rawBytes: shiftJISTesuto, utf8FlagPresent: false)
        #expect(decodes.first?.encodingID == "shift_jis")
        let top = decodes.first
        #expect(top?.decodedName == "テスト")
        #expect(top?.scriptHints.contains("kana") == true)
        // UTF-8 解不出这些字节,不应作为候选出现。
        #expect(!decodes.contains { $0.encodingID == "utf8" })
    }

    @Test func asciiPrefersUTF8() {
        let decodes = MojibakeEncodingScorer.decode(rawBytes: asciiName, utf8FlagPresent: false)
        #expect(decodes.first?.encodingID == "utf8")
        #expect(decodes.first?.decodedName == "test.txt")
    }

    @Test func utf8FlagPinsUTF8ToTop() {
        let utf8Bytes = Array("café-日本.txt".utf8)
        let decodes = MojibakeEncodingScorer.decode(rawBytes: utf8Bytes, utf8FlagPresent: true)
        #expect(decodes.first?.encodingID == "utf8")
        #expect(decodes.first?.deterministicScore == 1.0)
    }

    @Test func emptyBytesYieldNoCandidates() {
        #expect(MojibakeEncodingScorer.decode(rawBytes: [], utf8FlagPresent: false).isEmpty)
    }

    @Test func scoresAreSortedDescending() {
        let decodes = MojibakeEncodingScorer.decode(rawBytes: shiftJISTesuto, utf8FlagPresent: false)
        let scores = decodes.map(\.deterministicScore)
        #expect(scores == scores.sorted(by: >))
    }

    @Test func bestEncodingAcrossSamplesPicksShiftJIS() {
        let s1 = MojibakeEncodingScorer.sample(
            entryID: "e1", currentDisplayName: "âeâXâg", rawBytes: shiftJISTesuto, utf8FlagPresent: false)
        let s2 = MojibakeEncodingScorer.sample(
            entryID: "e2", currentDisplayName: "âeâXâg", rawBytes: shiftJISTesuto, utf8FlagPresent: false)
        let best = MojibakeEncodingScorer.bestEncoding(across: [s1, s2])
        #expect(best?.encodingID == "shift_jis")
        #expect((best?.confidence ?? 0) > 0.5)
    }

    @Test func bestEncodingEmptyWhenNoSamples() {
        #expect(MojibakeEncodingScorer.bestEncoding(across: []) == nil)
    }

    @Test func sampleBuildsHexPrefix() {
        let sample = MojibakeEncodingScorer.sample(
            entryID: "e1", currentDisplayName: "x", rawBytes: shiftJISTesuto, utf8FlagPresent: false)
        #expect(sample.rawHexPrefix == "83 65 83 58 83 67")
        #expect(sample.entryID == "e1")
        #expect(!sample.candidateDecodes.isEmpty)
    }

    @Test func repairPlanCodableRoundTrip() throws {
        let plan = MojibakeRepairPlan(
            archiveID: "arch-1", selectedEncodingID: "shift_jis", confidence: 0.86,
            sampleFixes: ["e1": "テスト"], applyMode: "rename-in-staging", requiresUserConfirmation: true)
        let decoded = try JSONDecoder().decode(MojibakeRepairPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }
}
