import Foundation
import Testing
@testable import SimpleZipCore

/// #10 疑似重复归档:指纹一致=结构相同组;指纹不同但条目数+总大小一致=疑似组;确定性排序。
struct ArchiveDuplicateScanTests {

    private func source(_ name: String, fingerprint: String?, count: Int, bytes: Int64) -> ArchiveDuplicateScan.Source {
        ArchiveDuplicateScan.Source(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fingerprint: fingerprint, entryCount: count, totalBytes: bytes
        )
    }

    @Test func groupsByFingerprintThenBySizeAndCount() {
        let groups = ArchiveDuplicateScan.groups(from: [
            source("foo.zip", fingerprint: "aaa", count: 3, bytes: 100),
            source("foo (1).zip", fingerprint: "aaa", count: 3, bytes: 100),
            source("foo-副本.7z", fingerprint: "bbb", count: 3, bytes: 100),
            source("bar.zip", fingerprint: "ccc", count: 9, bytes: 999),
            source("encrypted.zip", fingerprint: nil, count: 3, bytes: 100)
        ])

        #expect(groups.count == 2)
        let identical = groups.first { $0.confidence == .identicalStructure }
        #expect(identical?.urls.map(\.lastPathComponent) == ["foo (1).zip", "foo.zip"])
        // 指纹组消费掉的不再进疑似组;指纹不同/不可得但 (3, 100) 一致的两个归到疑似组。
        let similar = groups.first { $0.confidence == .sameCountAndSize }
        #expect(similar?.urls.map(\.lastPathComponent).sorted() == ["encrypted.zip", "foo-副本.7z"])
        #expect(similar?.entryCount == 3)
        #expect(similar?.totalBytes == 100)
    }

    @Test func singletonsAndEmptySummariesFormNoGroups() {
        let groups = ArchiveDuplicateScan.groups(from: [
            source("a.zip", fingerprint: "aaa", count: 1, bytes: 10),
            source("b.zip", fingerprint: "bbb", count: 2, bytes: 20),
            // 列不出条目且无元数据 —— 不参与任何分组(俩这种也不该成组)。
            source("x.zip", fingerprint: nil, count: 0, bytes: 0),
            source("y.zip", fingerprint: nil, count: 0, bytes: 0)
        ])
        #expect(groups.isEmpty)
    }
}
