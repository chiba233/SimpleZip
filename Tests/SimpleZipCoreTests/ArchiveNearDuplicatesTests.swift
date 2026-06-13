import XCTest
@testable import SimpleZipCore

final class ArchiveNearDuplicatesTests: XCTestCase {
    private func item(_ name: String, size: Int64 = 100, crc: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: size, modified: nil, sizeText: "\(size) B",
                    modifiedText: "", method: "", isEncrypted: false, packedSize: nil, packedSizeText: "",
                    crc: crc, created: nil, createdText: "", attributes: "", accessed: nil, accessedText: "",
                    hostOS: "", characteristics: "", symlinkTarget: "", comment: "")
    }

    func testNormalizationStripsCopyAndVersionMarkers() {
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("report (1).docx"), "report.docx")
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("Report copy.docx"), "report.docx")
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("report_v2.docx"), "report.docx")
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("report final.docx"), "report.docx")
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("报告 副本.docx"), "报告.docx")
        // 裸数字结尾不剥(chapter1/chapter2 是不同章,别合并)。
        XCTAssertEqual(ArchiveNearDuplicates.normalizedKey("chapter1.md"), "chapter1.md")
    }

    func testGroupsVersionsTogether() {
        let result = ArchiveNearDuplicates.find([
            item("docs/report.docx", size: 1000, crc: "aaa"),
            item("docs/report (1).docx", size: 1200, crc: "bbb"),
            item("docs/report_v2.docx", size: 1300, crc: "ccc"),
            item("photo.jpg"),
            item("unique.txt"),
        ])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.entries.count, 3)
        XCTAssertFalse(result.groups.first?.hasByteIdentical ?? true)  // 三个 crc 不同 = 仅版本相似
    }

    func testFlagsByteIdenticalRenames() {
        let result = ArchiveNearDuplicates.find([
            item("a/logo.png", crc: "deadbeef"),
            item("a/logo copy.png", crc: "deadbeef"),   // 同 crc,改名同源
        ])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertTrue(result.groups.first?.hasByteIdentical ?? false)
    }

    func testNoGroupsWhenAllDistinct() {
        let result = ArchiveNearDuplicates.find([item("a.txt"), item("b.txt"), item("c.png")])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.scannedFileCount, 3)
    }
}
