import Foundation
import Testing
@testable import SimpleZipCore

/// #8 空间分析 —— 聚合正确性 + 确定性排序 + 垃圾/加密分账。
struct ArchiveSpaceAnalysisTests {

    private func file(_ name: String, size: Int64, packed: Int64? = nil, encrypted: Bool = false) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: size, modified: nil,
                    sizeText: "", modifiedText: "", method: "", isEncrypted: encrypted, packedSize: packed)
    }

    @Test func aggregatesByDirectoryExtensionAndJunk() {
        let analysis = ArchiveSpaceAnalysis.analyze([
            file("docs/a.pdf", size: 100, packed: 40),
            file("docs/b.pdf", size: 50, packed: 20),
            file("src/main.swift", size: 30, packed: 10),
            file("readme.md", size: 5, packed: 5),
            file("__MACOSX/._a.pdf", size: 7, packed: 7),
            file("secret.bin", size: 60, packed: 60, encrypted: true),
            ArchiveItem(name: "docs/", isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
        ])
        #expect(analysis.totalBytes == 252)
        #expect(analysis.packedBytes == 142)
        #expect(analysis.junkCount == 1 && analysis.junkBytes == 7)
        #expect(analysis.encryptedCount == 1 && analysis.encryptedBytes == 60)
        #expect(analysis.largestFiles.first == .init(name: "docs/a.pdf", bytes: 100))
        #expect(analysis.topLevelDirectories.first == .init(name: "docs", bytes: 150))
        // 顶层散文件归入根("")。
        #expect(analysis.topLevelDirectories.contains(.init(name: "", bytes: 65)))
        #expect(analysis.extensions.first == .init(name: "pdf", bytes: 150))
        #expect(analysis.compressionRatio.map { abs($0 - 142.0 / 252.0) < 0.0001 } == true)
        #expect(analysis.fileCount == 6)
    }

    @Test func emptyAndNoPackedData() {
        let empty = ArchiveSpaceAnalysis.analyze([])
        #expect(empty.compressionRatio == nil)
        let noPacked = ArchiveSpaceAnalysis.analyze([file("a", size: 10)])
        #expect(noPacked.compressionRatio == nil)
    }
}
