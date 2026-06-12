import Foundation
import Testing
@testable import SimpleZipCore

/// #12 冲突自动重命名:staging 预改名 —— 目标已有文件零接触,新来的撞名文件改「name 2.ext」,
/// 目录不改名(照常深度合并),staging 内部同名也不互撞。
struct ArchiveConflictAutoRenameTests {

    private func makeDirs() throws -> (staging: URL, destination: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-AutoRenameTests-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging")
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (staging, destination, root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func renamesConflictingFilesAndLeavesRestAlone() throws {
        let (staging, destination, root) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        // 目标已有 readme.txt 与 docs/guide.md;staging 带同名两个 + 一个不冲突的。
        try write("old", to: destination.appendingPathComponent("readme.txt"))
        try write("old", to: destination.appendingPathComponent("docs/guide.md"))
        try write("new", to: staging.appendingPathComponent("readme.txt"))
        try write("new", to: staging.appendingPathComponent("docs/guide.md"))
        try write("new", to: staging.appendingPathComponent("fresh.txt"))

        let renamed = ArchiveConflictAutoRename.renameConflicts(in: staging, mergingInto: destination)

        #expect(renamed == 2)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("readme 2.txt").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("readme.txt").path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("docs/guide 2.md").path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("fresh.txt").path))
        // 目标侧一个字节没动。
        #expect(try String(contentsOf: destination.appendingPathComponent("readme.txt"), encoding: .utf8) == "old")
    }

    @Test func uniquenessConsidersBothSidesAndSkipsDirectories() throws {
        let (staging, destination, root) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        // 目标已有 a.txt 和 a 2.txt → staging 的 a.txt 必须跳到 a 3.txt。
        try write("old", to: destination.appendingPathComponent("a.txt"))
        try write("old", to: destination.appendingPathComponent("a 2.txt"))
        try write("new", to: staging.appendingPathComponent("a.txt"))
        // 目录同名:不改名(深度合并语义)。
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try write("new", to: staging.appendingPathComponent("shared/inner.txt"))

        let renamed = ArchiveConflictAutoRename.renameConflicts(in: staging, mergingInto: destination)

        #expect(renamed == 1)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("a 3.txt").path))
        // shared/ 目录保持原名,inner.txt 无目标冲突也保持原名。
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("shared/inner.txt").path))
    }

    @Test func builtInExtractionPresetsAreSane() {
        let presets = ExtractionPreset.builtInPresets()
        #expect(presets.count == 3)
        #expect(Set(presets.map(\.id)).count == presets.count)
        // 「保守安全」必须含自动改名与不解 symlink;「解完清理」才允许动原包。
        let cautious = presets.first { $0.id == "cautious" }
        #expect(cautious?.autoRenameConflicts == true)
        #expect(cautious?.skipSymlinks == true)
        #expect(cautious?.trashOriginalWhenDone == false)
        #expect(presets.filter(\.trashOriginalWhenDone).map(\.id) == ["tidy-finish"])
    }
}
