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

/// #13 智能去单层目录 —— 检测 + staging 上提(真实文件系统)。
struct ArchiveSingleRootFolderTests {

    private func entry(_ name: String, dir: Bool = false) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: dir, size: dir ? nil : 1, modified: nil, sizeText: "", modifiedText: "", method: "")
    }

    @Test func detectsUniformWrapper() {
        let items = [entry("proj-1.0/", dir: true), entry("proj-1.0/a.txt"), entry("proj-1.0/sub/b.txt"), entry(".DS_Store"), entry("__MACOSX/._a")]
        #expect(ArchiveSingleRootFolder.detect(in: items) == "proj-1.0")
    }

    @Test func rejectsTopLevelFilesAndMixedRoots() {
        #expect(ArchiveSingleRootFolder.detect(in: [entry("proj/a.txt"), entry("readme.md")]) == nil)
        #expect(ArchiveSingleRootFolder.detect(in: [entry("a/x.txt"), entry("b/y.txt")]) == nil)
        #expect(ArchiveSingleRootFolder.detect(in: []) == nil)
    }

    @Test func liftFlattensWrapperEvenWithSameNameChild() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("SimpleZip-LiftTest-\(UUID().uuidString)")
        // proj/proj/inner.txt + proj/a.txt —— 壳内有与壳同名的子目录,上提不得覆盖。
        try fm.createDirectory(at: staging.appendingPathComponent("proj/proj"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staging.appendingPathComponent("proj/a.txt"))
        try Data("y".utf8).write(to: staging.appendingPathComponent("proj/proj/inner.txt"))
        try Data().write(to: staging.appendingPathComponent(".DS_Store"))
        defer { try? fm.removeItem(at: staging) }

        #expect(ArchiveSingleRootFolder.lift(in: staging))
        #expect(fm.fileExists(atPath: staging.appendingPathComponent("a.txt").path))
        #expect(fm.fileExists(atPath: staging.appendingPathComponent("proj/inner.txt").path))
        // 原壳已消失(同名子目录顶替了它的名字,但内容是子目录的)。
        #expect(!fm.fileExists(atPath: staging.appendingPathComponent("proj/a.txt").path))
    }

    @Test func liftRefusesSymlinkWrapperAndMultipleRoots() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("SimpleZip-LiftTest-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // 壳是符号链接 → 拒绝(防越界)。
        let outside = fm.temporaryDirectory.appendingPathComponent("SimpleZip-LiftOutside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: staging.appendingPathComponent("wrapper"), withDestinationURL: outside)
        #expect(!ArchiveSingleRootFolder.lift(in: staging))
        // 两个顶层目录 → 拒绝。
        try fm.removeItem(at: staging.appendingPathComponent("wrapper"))
        try fm.createDirectory(at: staging.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("b"), withIntermediateDirectories: true)
        #expect(!ArchiveSingleRootFolder.lift(in: staging))
    }
}
