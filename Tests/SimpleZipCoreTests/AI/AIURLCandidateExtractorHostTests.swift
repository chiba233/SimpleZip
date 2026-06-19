//
//  AIURLCandidateExtractorHostTests.swift
//  SimpleZipCoreTests
//
//  独立 AI 进程改造 · 把高价值域名判定从 app target 的 AIBackgroundIndexer 下沉到 Core 的
//  AIURLCandidateExtractor 后**首次可单测**。覆盖 isHighValueURL(精确 / 去 www / 子域命中,以及
//  **子域伪造必须不命中** 这一安全要点)与 webPageLabel(裸主机名 / 无 host 回退)。
//

import Foundation
import Testing
@testable import SimpleZipCore

@Suite struct AIURLCandidateExtractorHostTests {
    // MARK: isHighValueURL

    @Test func exactHighValueHostMatches() {
        #expect(AIURLCandidateExtractor.isHighValueURL("https://github.com/user/repo"))
        #expect(AIURLCandidateExtractor.isHighValueURL("https://stackoverflow.com/questions/1"))
        #expect(AIURLCandidateExtractor.isHighValueURL("https://crates.io/crates/serde"))
    }

    @Test func subdomainOfHighValueHostMatches() {
        // docs.github.com 是 github.com 的子域 → 命中(hasSuffix("." + host))。
        #expect(AIURLCandidateExtractor.isHighValueURL("https://docs.github.com/en/get-started"))
        #expect(AIURLCandidateExtractor.isHighValueURL("https://gist.github.com/abc"))
    }

    @Test func wwwPrefixIsStrippedBeforeMatching() {
        #expect(AIURLCandidateExtractor.isHighValueURL("https://www.github.com/x"))
    }

    @Test func spoofedSuffixDoesNotMatch() {
        // 安全要点:github.com.evil.com 不是 github.com 的子域,绝不能命中(否则伪造域名骗过判定)。
        #expect(!AIURLCandidateExtractor.isHighValueURL("https://github.com.evil.com/x"))
        // notgithub.com 既不精确等于、也不以 ".github.com" 结尾 → 不命中。
        #expect(!AIURLCandidateExtractor.isHighValueURL("https://notgithub.com/x"))
    }

    @Test func nonHighValueOrHostlessIsFalse() {
        #expect(!AIURLCandidateExtractor.isHighValueURL("https://example.com/x"))
        #expect(!AIURLCandidateExtractor.isHighValueURL("not a url"))
        #expect(!AIURLCandidateExtractor.isHighValueURL(""))
    }

    // MARK: webPageLabel

    @Test func webPageLabelReturnsBareHost() {
        #expect(AIURLCandidateExtractor.webPageLabel(for: "https://www.github.com/user/repo") == "github.com")
        #expect(AIURLCandidateExtractor.webPageLabel(for: "https://docs.rs/foo") == "docs.rs")
        #expect(AIURLCandidateExtractor.webPageLabel(for: "https://stackoverflow.com") == "stackoverflow.com")
    }

    @Test func webPageLabelFallsBackToRawWhenNoHost() {
        #expect(AIURLCandidateExtractor.webPageLabel(for: "not a url") == "not a url")
    }
}
