import Foundation
import Testing
@testable import SimpleZipCore

/// #9 结构指纹 —— 确定性 / 忽略时间戳·注释·垃圾·顺序 / 区分真实结构差异。
struct ArchiveSafetyFingerprintTests {

    private func file(_ name: String, size: Int64? = 10, crc: String = "AABBCCDD", modified: Date? = nil, comment: String = "") -> ArchiveItem {
        ArchiveItem(
            name: name, isDirectory: false, size: size, modified: modified,
            sizeText: "", modifiedText: "", method: "Deflate",
            crc: crc, comment: comment
        )
    }

    private func dir(_ name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
    }

    @Test func ignoresTimestampsCommentsJunkAndOrder() {
        let a = [file("docs/a.txt", modified: Date(timeIntervalSince1970: 0)), file("b.txt", crc: "11223344"), dir("docs")]
        let b = [dir("docs/"), file("./b.txt", crc: "11223344", modified: Date(), comment: "hi"),
                 file("docs/a.txt"), file(".DS_Store"), file("__MACOSX/._a.txt")]
        #expect(ArchiveStructuralFingerprint.compute(for: a) == ArchiveStructuralFingerprint.compute(for: b))
    }

    @Test func distinguishesRealStructuralChanges() {
        let base = [file("a.txt")]
        #expect(ArchiveStructuralFingerprint.compute(for: base)
            != ArchiveStructuralFingerprint.compute(for: [file("a.txt", size: 11)]))
        #expect(ArchiveStructuralFingerprint.compute(for: base)
            != ArchiveStructuralFingerprint.compute(for: [file("a.txt", crc: "FFFFFFFF")]))
        #expect(ArchiveStructuralFingerprint.compute(for: base)
            != ArchiveStructuralFingerprint.compute(for: [file("b.txt")]))
        #expect(ArchiveStructuralFingerprint.compute(for: base)
            != ArchiveStructuralFingerprint.compute(for: base + [dir("sub")]))
    }

    @Test func normalizedLinesAreSortedAndTyped() {
        let lines = ArchiveStructuralFingerprint.normalizedLines(for: [file("b.txt"), dir("a")])
        #expect(lines == ["dir|a", "file|b.txt|10|aabbccdd"])
    }
}
