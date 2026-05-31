import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖「手动清理临时文件」的 Core 逻辑：只认 SimpleZip 前缀、能算大小、清理后只删自己的、别人的不动。
struct TemporaryResourceManagerTests {
    private func makeIsolatedBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SZTMTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ bytes: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test
    func onlyMatchesSimpleZipPrefixedEntries() throws {
        let base = try makeIsolatedBase()
        defer { try? FileManager.default.removeItem(at: base) }

        try writeFile(1000, at: base.appendingPathComponent("SimpleZip-SZS-Create-1/manifest.json"))
        try writeFile(2000, at: base.appendingPathComponent("SimpleZipArchiveOpen/abc/payload.txt"))
        try writeFile(5000, at: base.appendingPathComponent("OtherApp-cache/data.bin"))

        let urls = TemporaryResourceManager.temporaryArtifactURLs(in: base)
        let names = Set(urls.map(\.lastPathComponent))
        #expect(names == ["SimpleZip-SZS-Create-1", "SimpleZipArchiveOpen"])
        #expect(!names.contains("OtherApp-cache"))
    }

    @Test
    func byteSizeSumsAllSimpleZipArtifacts() throws {
        let base = try makeIsolatedBase()
        defer { try? FileManager.default.removeItem(at: base) }

        try writeFile(4096, at: base.appendingPathComponent("SimpleZip-a/f1.bin"))
        try writeFile(4096, at: base.appendingPathComponent("SimpleZip-b/sub/f2.bin"))

        // 按磁盘分配大小累加，可能向上取整到块边界，所以用 >=。
        let size = TemporaryResourceManager.temporaryArtifactsByteSize(in: base)
        #expect(size >= 8192)
    }

    @Test
    func clearRemovesOnlySimpleZipArtifactsAndReportsFreed() throws {
        let base = try makeIsolatedBase()
        defer { try? FileManager.default.removeItem(at: base) }

        try writeFile(3000, at: base.appendingPathComponent("SimpleZip-x/file.bin"))
        try writeFile(7000, at: base.appendingPathComponent("KeepMe/file.bin"))

        let freed = TemporaryResourceManager.clearTemporaryArtifacts(in: base)
        #expect(freed > 0)

        // SimpleZip 条目清掉了，别人的留着。
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("SimpleZip-x").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("KeepMe").path))
        #expect(TemporaryResourceManager.temporaryArtifactsByteSize(in: base) == 0)
    }
}
