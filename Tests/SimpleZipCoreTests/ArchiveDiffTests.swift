import Foundation
import Testing
@testable import SimpleZipCore

/// #111 Archive Diff —— 纯比对引擎的回归测试。不碰后端、不需要真压缩包，只喂构造好的 `[ArchiveItem]`。
struct ArchiveDiffTests {

    private func file(
        _ name: String,
        size: Int64? = nil,
        crc: String = "",
        modified: Date? = nil,
        encrypted: Bool = false
    ) -> ArchiveItem {
        ArchiveItem(
            name: name,
            isDirectory: false,
            size: size,
            modified: modified,
            sizeText: size.map { "\($0)" } ?? "",
            modifiedText: "",
            method: "",
            isEncrypted: encrypted,
            crc: crc
        )
    }

    private func dir(_ name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
    }

    @Test func detectsAddedRemovedUnchanged() {
        let left = [file("a.txt", size: 1, crc: "AAAA"), file("b.txt", size: 2, crc: "BBBB")]
        let right = [file("a.txt", size: 1, crc: "AAAA"), file("c.txt", size: 3, crc: "CCCC")]

        let result = ArchiveDiff.compare(left: left, right: right)

        #expect(result.added.map(\.name) == ["c.txt"])
        #expect(result.removed.map(\.name) == ["b.txt"])
        #expect(result.unchanged.map(\.name) == ["a.txt"])
        #expect(result.changed.isEmpty)
        #expect(result.hasDifferences)
    }

    @Test func identicalArchivesHaveNoDifferences() {
        let items = [file("a.txt", size: 1, crc: "AAAA"), dir("d/")]
        let result = ArchiveDiff.compare(left: items, right: items)
        #expect(!result.hasDifferences)
        #expect(result.unchanged.count == 2)
    }

    @Test func contentChangeFlagsSizeAndCRC() {
        let left = [file("a.txt", size: 10, crc: "1111")]
        let right = [file("a.txt", size: 20, crc: "2222")]

        let result = ArchiveDiff.compare(left: left, right: right)

        #expect(result.added.isEmpty && result.removed.isEmpty)
        #expect(result.changed.count == 1)
        let change = try! #require(result.changed.first)
        #expect(change.path == "a.txt")
        #expect(change.fields == [.size, .crc])
    }

    @Test func emptyOrZeroCRCDoesNotCountAsCRCChange() {
        // 一侧没有 CRC（空 / 全 0）时不该判 .crc 改动；但 size 仍照常比。
        let left = [file("a.txt", size: 5, crc: "")]
        let right = [file("a.txt", size: 5, crc: "00000000")]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(!result.hasDifferences)
    }

    @Test func encryptionFlagChangeIsDetected() {
        let left = [file("secret.txt", size: 5, crc: "AAAA", encrypted: false)]
        let right = [file("secret.txt", size: 5, crc: "AAAA", encrypted: true)]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.changed.first?.fields == [.encryption])
    }

    @Test func fileBecomingDirectoryIsTypeChange() {
        let left = [file("thing", size: 5, crc: "AAAA")]
        let right = [dir("thing")]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.changed.first?.fields == [.type])
    }

    @Test func pathNormalizationPairsTrailingSlashAndDotPrefix() {
        // "./dir/" 与 "dir" 归一化后同路径；"./a.txt" 与 "a.txt" 同理。
        let left = [dir("./dir/"), file("./a.txt", size: 1, crc: "AAAA")]
        let right = [dir("dir"), file("a.txt", size: 1, crc: "AAAA")]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(!result.hasDifferences)
        #expect(result.unchanged.count == 2)
    }

    @Test func modifiedTimeChangeIsDetected() {
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let left = [file("a.txt", size: 1, crc: "AAAA", modified: t1)]
        let right = [file("a.txt", size: 1, crc: "AAAA", modified: t2)]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.changed.first?.fields == [.modified])
    }

    @Test func resultsAreSortedByPath() {
        let left: [ArchiveItem] = []
        let right = [file("z.txt", size: 1), file("a.txt", size: 1), file("m.txt", size: 1)]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.added.map(\.name) == ["a.txt", "m.txt", "z.txt"])
    }
}
