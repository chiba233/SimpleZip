import Foundation
import Testing
@testable import SimpleZipCore

/// #15 缺分卷搜索:另选目录递归找缺失卷(按命名解析匹配)+ 期望名提示。
struct MissingVolumeSearchTests {

    @Test func findsMissingNumericVolumesRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-MissingVolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let search = root.appendingPathComponent("backup/deep")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: search.appendingPathComponent("a.7z.002").path, contents: Data("2".utf8))
        FileManager.default.createFile(atPath: search.appendingPathComponent("unrelated.7z.002").path, contents: Data())

        // 组内现有 001 和 003,缺 002。
        let set = try #require(FileSplitCombine.volumeSet(
            forMemberNamed: "a.7z.001",
            among: ["a.7z.001", "a.7z.003"]
        ))
        #expect(set.missingIndices == [2])

        let found = FileSplitCombine.searchForMissingVolumes(of: set, in: root.appendingPathComponent("backup"))
        #expect(found.count == 1)
        #expect(found[2]?.lastPathComponent == "a.7z.002")
    }

    @Test func expectedNamesForNumericAndPartRar() throws {
        let numeric = try #require(FileSplitCombine.volumeSet(
            forMemberNamed: "a.7z.001", among: ["a.7z.001", "a.7z.003"]
        ))
        #expect(FileSplitCombine.expectedVolumeName(for: numeric, index: 2) == "a.7z.002")

        let rar = try #require(FileSplitCombine.volumeSet(
            forMemberNamed: "b.part1.rar", among: ["b.part1.rar", "b.part3.rar"]
        ))
        #expect(rar.missingIndices == [2])
        #expect(FileSplitCombine.expectedVolumeName(for: rar, index: 2) == "b.part2.rar")
        let foundRar = FileSplitCombine.searchForMissingVolumes(of: rar, in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(foundRar.isEmpty)
    }
}
