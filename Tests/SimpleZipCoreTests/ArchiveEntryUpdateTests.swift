import Foundation
import Testing
@testable import SimpleZipCore

/// 「往已存在的压缩包加 / 替换条目」的数据安全核心测试 —— 用真实 7zz 跑 round-trip。
/// 重点锁住:① 替换 + 新增都正确;② **未涉及的条目原样保留**;③ **失败时原包一个字节不动**。
struct ArchiveEntryUpdateTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SZEntryUpdateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeZip(in temp: URL) async throws -> URL {
        let source = temp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "original A".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "keep B".write(to: source.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        var options = ArchiveCreationOptions()
        options.format = .zip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        let archive = temp.appendingPathComponent("test.zip")
        try await ArchiveService.createArchive(from: [source], destination: archive, options: options)
        return archive
    }

    private func extractContents(_ archive: URL, in temp: URL) async throws -> [String: String] {
        let dest = temp.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try await ArchiveService.extract(archive, to: dest)
        return try Self.walkTextFiles(under: dest)
    }

    /// 同步遍历目录下所有普通文件 → {相对路径: 文本内容}。放在非 async 上下文里（FileManager.enumerator 的
    /// makeIterator 在 async 上下文不可用）。
    private nonisolated static func walkTextFiles(under root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        // 解析符号链接(/var → /private/var),否则 enumerator 给的解析路径跟 root 前缀对不上 → 相对路径算错。
        let base = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let rel = String(full.dropFirst(base.count + 1))
            result[rel] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    @Test func replacesAndAddsEntriesAndKeepsOthers() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try await makeZip(in: temp)

        // 准备:编辑后的 a.txt + 新文件 c.txt。
        let editedA = temp.appendingPathComponent("editedA.txt")
        try "EDITED A".write(to: editedA, atomically: true, encoding: .utf8)
        let newC = temp.appendingPathComponent("newC.txt")
        try "NEW C".write(to: newC, atomically: true, encoding: .utf8)

        try await ArchiveService.addOrReplaceEntries(in: archive, additions: [
            ArchiveEntryAddition(sourceFile: editedA, entryPath: "source/a.txt"),
            ArchiveEntryAddition(sourceFile: newC, entryPath: "source/c.txt"),
        ])

        let contents = try await extractContents(archive, in: temp)
        #expect(contents["source/a.txt"] == "EDITED A")   // 替换
        #expect(contents["source/c.txt"] == "NEW C")       // 新增
        #expect(contents["source/b.txt"] == "keep B")      // 未涉及 → 原样保留
    }

    @Test func failureLeavesOriginalArchiveUntouched() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try await makeZip(in: temp)
        let before = try Data(contentsOf: archive)

        // 源文件不存在 → 复制阶段就抛错,原包不该被动过。
        let missing = temp.appendingPathComponent("does-not-exist.txt")
        await #expect(throws: (any Error).self) {
            try await ArchiveService.addOrReplaceEntries(in: archive, additions: [
                ArchiveEntryAddition(sourceFile: missing, entryPath: "source/a.txt"),
            ])
        }
        let after = try Data(contentsOf: archive)
        #expect(before == after)   // 原包字节级不变
    }

    @Test func deletesEntryAndKeepsOthers() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try await makeZip(in: temp)

        try await ArchiveService.deleteEntries(from: archive, entryPaths: ["source/a.txt"])

        let contents = try await extractContents(archive, in: temp)
        #expect(contents["source/a.txt"] == nil)      // 已删
        #expect(contents["source/b.txt"] == "keep B")  // 未涉及 → 保留
    }

    @Test func deleteFailureLeavesOriginalUntouched() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try await makeZip(in: temp)
        let before = try Data(contentsOf: archive)
        await #expect(throws: (any Error).self) {
            // 非法路径 → 规范化阶段抛错,原包不动。
            try await ArchiveService.deleteEntries(from: archive, entryPaths: ["../escape"])
        }
        #expect(try Data(contentsOf: archive) == before)
    }

    @Test func renamesEntry() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = try await makeZip(in: temp)

        try await ArchiveService.renameEntry(in: archive, from: "source/a.txt", to: "source/renamed.txt")

        let contents = try await extractContents(archive, in: temp)
        #expect(contents["source/a.txt"] == nil)
        #expect(contents["source/renamed.txt"] == "original A")  // 内容不变,只改名
        #expect(contents["source/b.txt"] == "keep B")
    }

    @Test func rejectsUnsafeEntryPaths() {
        #expect(throws: (any Error).self) { try ArchiveService.normalizedEntryRelativePath("../escape.txt") }
        #expect(throws: (any Error).self) { try ArchiveService.normalizedEntryRelativePath("/abs/path.txt") }
        #expect(throws: (any Error).self) { try ArchiveService.normalizedEntryRelativePath("") }
        #expect(throws: (any Error).self) { try ArchiveService.normalizedEntryRelativePath("a/../../b") }
    }

    @Test func normalizesCleanPaths() throws {
        #expect(try ArchiveService.normalizedEntryRelativePath("docs/a.txt") == "docs/a.txt")
        #expect(try ArchiveService.normalizedEntryRelativePath("a.txt") == "a.txt")
        #expect(try ArchiveService.normalizedEntryRelativePath("x//y/z.txt") == "x/y/z.txt")
    }

    @Test func formatGatingOnlyZipAndSevenZip() {
        #expect(ArchiveService.supportsEntryUpdate(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(ArchiveService.supportsEntryUpdate(URL(fileURLWithPath: "/tmp/a.7z")))
        #expect(!ArchiveService.supportsEntryUpdate(URL(fileURLWithPath: "/tmp/a.tar")))
        #expect(!ArchiveService.supportsEntryUpdate(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        #expect(!ArchiveService.supportsEntryUpdate(URL(fileURLWithPath: "/tmp/a.rar")))
    }
}
