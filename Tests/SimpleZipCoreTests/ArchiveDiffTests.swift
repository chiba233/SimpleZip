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

    /// 0.4.2:条目注释参与比对。
    @Test func detectsCommentChange() {
        let left = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "1", modifiedText: "", method: "", crc: "AAAA", comment: "old note")]
        let right = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "1", modifiedText: "", method: "", crc: "AAAA", comment: "new note")]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.changed.count == 1)
        #expect(result.changed.first?.fields == [.comment])
    }

    // MARK: - 导出（0.4.2）

    @Test func jsonExportIsDeterministicAndDiffOnly() throws {
        let left = [file("gone.txt", size: 1, crc: "AAAA"), file("same.txt", size: 5, crc: "5555")]
        let right = [file("new.txt", size: 2, crc: "BBBB"), file("same.txt", size: 5, crc: "5555")]
        let result = ArchiveDiff.compare(left: left, right: right)

        let once = try ArchiveDiffExport.json(result: result, leftName: "a.zip", rightName: "b.zip")
        let twice = try ArchiveDiffExport.json(result: result, leftName: "a.zip", rightName: "b.zip")
        #expect(once == twice)

        let object = try JSONSerialization.jsonObject(with: Data(once.utf8)) as? [String: Any]
        #expect(object?["left"] as? String == "a.zip")
        let summary = object?["summary"] as? [String: Int]
        #expect(summary == ["added": 1, "removed": 1, "changed": 0, "unchanged": 1])
        // 只导差异项：unchanged 不出现条目数组。
        #expect((object?["added"] as? [[String: Any]])?.count == 1)
        #expect(object?["unchangedEntries"] == nil)
    }

    @Test func jsonExportRecordsChangedFieldsStably() throws {
        let left = [file("a.txt", size: 1, crc: "AAAA")]
        let right = [file("a.txt", size: 2, crc: "BBBB")]
        let result = ArchiveDiff.compare(left: left, right: right)
        let json = try ArchiveDiffExport.json(result: result, leftName: "l", rightName: "r")
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let changed = object?["changed"] as? [[String: Any]]
        #expect(changed?.first?["fields"] as? [String] == ["size", "crc"])
    }

    @Test func csvExportEscapesAndCoversAllStatuses() {
        let left = [file("with,comma.txt", size: 1, crc: "AAAA"), file("mod.txt", size: 1, crc: "AAAA")]
        let right = [file("added.txt", size: 2, crc: "BBBB"), file("mod.txt", size: 3, crc: "CCCC")]
        let result = ArchiveDiff.compare(left: left, right: right)
        let csv = ArchiveDiffExport.csv(result: result, leftName: "l", rightName: "r")
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)   // header + removed + added + changed
        #expect(lines[0].hasPrefix("status,path,is_directory,fields,"))
        #expect(lines.contains { $0.hasPrefix("removed,\"with,comma.txt\"") })
        #expect(lines.contains { $0.hasPrefix("added,added.txt") })
        #expect(lines.contains { $0.hasPrefix("changed,mod.txt,false,size+crc") })
    }

    @Test func resultsAreSortedByPath() {
        let left: [ArchiveItem] = []
        let right = [file("z.txt", size: 1), file("a.txt", size: 1), file("m.txt", size: 1)]
        let result = ArchiveDiff.compare(left: left, right: right)
        #expect(result.added.map(\.name) == ["a.txt", "m.txt", "z.txt"])
    }
}

/// 0.4.2 #16:垃圾识别 + diff 垃圾过滤。
struct ArchiveJunkFilesTests {

    @Test func recognizesClassicJunk() {
        #expect(ArchiveJunkFiles.isJunkPath(".DS_Store"))
        #expect(ArchiveJunkFiles.isJunkPath("docs/.DS_Store"))
        #expect(ArchiveJunkFiles.isJunkPath("__MACOSX/docs/._a.txt"))
        #expect(ArchiveJunkFiles.isJunkPath("__MACOSX/"))
        #expect(ArchiveJunkFiles.isJunkPath("docs/._report.pdf"))
        #expect(ArchiveJunkFiles.isJunkPath("Thumbs.db"))
        #expect(ArchiveJunkFiles.isJunkPath("photos/desktop.ini"))
        #expect(!ArchiveJunkFiles.isJunkPath("docs/report.pdf"))
        #expect(!ArchiveJunkFiles.isJunkPath("._"))            // 光杆 ._ 不算
        #expect(!ArchiveJunkFiles.isJunkPath("my__MACOSX.txt")) // 仅目录段精确匹配
    }

    @Test func diffFilteringJunkDropsNoiseEverywhere() {
        let junk = ArchiveItem(name: "docs/.DS_Store", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "")
        let real = ArchiveItem(name: "docs/a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "")
        let result = ArchiveDiff.compare(left: [junk], right: [real, junk])
        #expect(result.added.count == 1)
        #expect(result.unchanged.count == 1)
        let filtered = result.filteringJunk()
        #expect(filtered.added.map(\.name) == ["docs/a.txt"])
        #expect(filtered.unchanged.isEmpty)
        #expect(filtered.removed.isEmpty)
    }
}

/// 0.4.2 #24:包内重复文件检测。
struct ArchiveDuplicatesTests {

    private func file(_ name: String, size: Int64?, crc: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: size, modified: nil, sizeText: "", modifiedText: "", method: "", crc: crc)
    }

    @Test func groupsBySizeAndCRC() {
        let items = [
            file("a/dup.bin", size: 100, crc: "AAAA"),
            file("b/dup-copy.bin", size: 100, crc: "aaaa"),   // CRC 大小写归一
            file("c/other.bin", size: 100, crc: "BBBB"),
            file("d/unique.bin", size: 50, crc: "AAAA")       // 同 CRC 不同大小,不算
        ]
        let groups = ArchiveDuplicates.findDuplicates(in: items)
        #expect(groups.count == 1)
        #expect(groups.first?.paths == ["a/dup.bin", "b/dup-copy.bin"])
        #expect(groups.first?.wastedBytes == 100)
    }

    @Test func skipsUnreliableEntries() {
        let items = [
            file("no-crc-1", size: 10, crc: ""),
            file("no-crc-2", size: 10, crc: ""),
            file("zero-crc-1", size: 10, crc: "00000000"),
            file("zero-crc-2", size: 10, crc: "00000000"),
            file("empty-1", size: 0, crc: "AAAA"),
            file("empty-2", size: 0, crc: "AAAA")
        ]
        #expect(ArchiveDuplicates.findDuplicates(in: items).isEmpty)
    }

    @Test func sortsByWastedBytesDescending() {
        let items = [
            file("small-1", size: 10, crc: "AAAA"), file("small-2", size: 10, crc: "AAAA"),
            file("big-1", size: 1000, crc: "BBBB"), file("big-2", size: 1000, crc: "BBBB"), file("big-3", size: 1000, crc: "BBBB")
        ]
        let groups = ArchiveDuplicates.findDuplicates(in: items)
        #expect(groups.map(\.crc) == ["BBBB", "AAAA"])
        #expect(groups.first?.wastedBytes == 2000)
    }
}

/// 0.4.2 #25:文件夹快照 + 修改时间容差。
struct FolderComparisonTests {

    @Test func folderItemsSnapshotTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-FolderDiffTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("docs/a.txt"))
        try Data().write(to: root.appendingPathComponent("top.txt"))

        let items = ArchiveDiff.folderItems(at: root)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["docs"]?.isDirectory == true)
        #expect(byName["docs/a.txt"]?.size == 5)
        #expect(byName["top.txt"]?.isDirectory == false)
        #expect(items.count == 3)
    }

    @Test func modifiedToleranceAbsorbsDOSTimestampJitter() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let left = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: base, sizeText: "", modifiedText: "", method: "")]
        let within = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: base.addingTimeInterval(1.5), sizeText: "", modifiedText: "", method: "")]
        let beyond = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: base.addingTimeInterval(10), sizeText: "", modifiedText: "", method: "")]
        #expect(ArchiveDiff.compare(left: left, right: within).changed.isEmpty)   // 2 秒内 = 同
        #expect(ArchiveDiff.compare(left: left, right: beyond).changed.first?.fields == [.modified])
    }

    @Test func oneSidedMissingTimestampIsNotAChange() {
        let dated = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: Date(timeIntervalSince1970: 1), sizeText: "", modifiedText: "", method: "")]
        let undated = [ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "")]
        #expect(ArchiveDiff.compare(left: dated, right: undated).changed.isEmpty)
    }
}
