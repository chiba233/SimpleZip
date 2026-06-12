import Foundation
import Testing
@testable import SimpleZipCore

/// #11 内容搜索:候选判定(白名单扩展名 + 大小上限)与匹配引擎(二进制嗅探/大小写不敏感/行号/上限)。
struct ArchiveContentSearchTests {

    private func entry(_ path: String, size: Int64?, isDirectory: Bool = false) -> ArchiveItem {
        ArchiveItem(name: path, isDirectory: isDirectory, size: size, modified: nil,
                    sizeText: "", modifiedText: "", method: "")
    }

    @Test func candidateSelection() {
        #expect(ArchiveContentSearch.isTextCandidate(entry("docs/readme.md", size: 100)))
        #expect(ArchiveContentSearch.isTextCandidate(entry("src/Main.SWIFT", size: 100)))
        #expect(ArchiveContentSearch.isTextCandidate(entry("Makefile", size: 100)))
        // 目录 / 二进制扩展名 / 超上限 / 大小未知 → 全不进。
        #expect(!ArchiveContentSearch.isTextCandidate(entry("src", size: nil, isDirectory: true)))
        #expect(!ArchiveContentSearch.isTextCandidate(entry("a.bin", size: 100)))
        #expect(!ArchiveContentSearch.isTextCandidate(entry("a.pdf", size: 100)))
        #expect(!ArchiveContentSearch.isTextCandidate(entry("big.txt", size: ArchiveContentSearch.defaultMaxFileBytes + 1)))
        #expect(!ArchiveContentSearch.isTextCandidate(entry("unknown.txt", size: nil)))
    }

    @Test func matchingIsCaseInsensitiveWithLineNumbers() {
        let data = Data("first line\nSecond NEEDLE here\nthird\nneedle again".utf8)
        let hits = ArchiveContentSearch.matches(in: data, query: "Needle")
        #expect(hits.count == 2)
        #expect(hits[0].lineNumber == 2)
        #expect(hits[0].lineText == "Second NEEDLE here")
        #expect(hits[1].lineNumber == 4)
    }

    @Test func binaryDataIsSkipped() {
        var bytes = Data("needle".utf8)
        bytes.insert(0, at: 0)
        #expect(ArchiveContentSearch.matches(in: bytes, query: "needle").isEmpty)
    }

    @Test func perFileLimitCapsResults() {
        let data = Data(Array(repeating: "needle", count: 50).joined(separator: "\n").utf8)
        #expect(ArchiveContentSearch.matches(in: data, query: "needle", perFileLimit: 20).count == 20)
    }
}
