import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 `.szs` 的 **GPG-free 明文路径**（`AppPreferences.gpgEnabled == false` 时用）：
/// `extractClearsignedManifest` + `verifyWithoutSignature`。
/// 这条路径刻意不依赖 gpg 二进制，所以能在 CI 上无 GPG 跑 —— 正是它存在的意义。
struct SZSArchiveTests {
    /// 把 manifest JSON 包成一段「形如 gpg --clearsign 输出」的 clearsigned 文本（不需要真 GPG）。
    private func makeClearsigned(_ manifestJSON: Data) -> String {
        let json = String(decoding: manifestJSON, as: UTF8.self)
        return """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA512

        \(json)
        -----BEGIN PGP SIGNATURE-----

        iQFakeSignatureBytesForTestOnly==
        -----END PGP SIGNATURE-----
        """
    }

    private func writeFile(_ contents: String, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test
    func extractClearsignedManifestReadsPayloadWithoutGPG() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = SZSArchive.Manifest(
            schema: SZSArchive.schemaIdentifier,
            version: SZSArchive.schemaVersion,
            createdAt: "2026-05-31T00:00:00Z",
            createdBy: "SimpleZip test",
            title: "Demo",
            description: nil,
            rootDirectoryHint: nil,
            files: [
                SZSArchive.FileEntry(relativePath: "a.txt", size: 5, sha256: String(repeating: "0", count: 64), mediaType: nil)
            ]
        )
        let json = try SZSArchive.encodeManifest(manifest)
        let szsURL = dir.appendingPathComponent("demo.szs")
        try Data(makeClearsigned(json).utf8).write(to: szsURL)

        let parsed = try SZSArchive.extractClearsignedManifest(manifestURL: szsURL)
        #expect(parsed.schema == SZSArchive.schemaIdentifier)
        #expect(parsed.version == SZSArchive.schemaVersion)
        #expect(parsed.title == "Demo")
        #expect(parsed.files.count == 1)
        #expect(parsed.files.first?.relativePath == "a.txt")
    }

    @Test
    func verifyWithoutSignatureRunsShaChecksAndSkipsSignature() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // payloadRoot 下放真实文件：a.txt 匹配，b.txt 内容不符 → mismatch，c.txt 缺失。
        let matchURL = try writeFile("hello", named: "a.txt", in: dir)
        _ = try writeFile("tampered", named: "b.txt", in: dir)
        let matchSHA = try SIZArchive.computeInnerArchiveSHA256(of: matchURL)

        let manifest = SZSArchive.Manifest(
            schema: SZSArchive.schemaIdentifier,
            version: SZSArchive.schemaVersion,
            createdAt: "2026-05-31T00:00:00Z",
            createdBy: "SimpleZip test",
            title: nil,
            description: nil,
            rootDirectoryHint: nil,
            files: [
                SZSArchive.FileEntry(relativePath: "a.txt", size: 5, sha256: matchSHA, mediaType: nil),
                SZSArchive.FileEntry(relativePath: "b.txt", size: 8, sha256: String(repeating: "a", count: 64), mediaType: nil),
                SZSArchive.FileEntry(relativePath: "c.txt", size: 1, sha256: String(repeating: "b", count: 64), mediaType: nil)
            ]
        )
        let json = try SZSArchive.encodeManifest(manifest)
        let szsURL = dir.appendingPathComponent("demo.szs")
        try Data(makeClearsigned(json).utf8).write(to: szsURL)

        let report = try SZSArchive.verifyWithoutSignature(manifestURL: szsURL, payloadRoot: dir)

        // 文件层结果按 manifest 三条 entry 分类。
        let summary = report.summary
        #expect(summary.total == 3)
        #expect(summary.matched == 1)
        #expect(summary.mismatched == 1)
        #expect(summary.missing == 1)
        #expect(summary.allFilesOk == false)

        // 签名层：明文路径不验签，占位为 .verificationError（带 GPG 未启用文案）。
        if case .verificationError = report.signature {
            // ok
        } else {
            Issue.record("expected .verificationError placeholder when GPG is disabled")
        }
    }

    @Test
    func extractClearsignedManifestRejectsMissingSignatureBlock() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 没有 -----BEGIN PGP SIGNATURE----- 块 → 解析应失败而不是返回半个 manifest。
        let bogus = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA512

        { "schema": "SimpleZip.szs" }
        """
        let szsURL = dir.appendingPathComponent("bad.szs")
        try Data(bogus.utf8).write(to: szsURL)

        #expect(throws: SZSArchive.SZSError.self) {
            _ = try SZSArchive.extractClearsignedManifest(manifestURL: szsURL)
        }
    }

    @Test
    func expandToRegularFilesRecursesDirectoriesAndSkipsSymlinks() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // 树：top.txt + sub/nested.txt + sub/deep/deeper.txt + 一个符号链接 link.txt → top.txt。
        let top = try writeFile("top", named: "top.txt", in: dir)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub.appendingPathComponent("deep", isDirectory: true), withIntermediateDirectories: true)
        _ = try writeFile("nested", named: "sub/nested.txt", in: dir)
        _ = try writeFile("deeper", named: "sub/deep/deeper.txt", in: dir)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: top)

        // 选「整个目录」→ 递归收 3 个普通文件，符号链接被跳过。
        let expanded = SZSArchive.expandToRegularFiles([dir])
        let names = Set(expanded.map { $0.lastPathComponent })
        #expect(expanded.count == 3)
        #expect(names == ["top.txt", "nested.txt", "deeper.txt"])
        #expect(!names.contains("link.txt"))

        // 普通文件原样保留；符号链接条目被直接跳过。
        let mixed = SZSArchive.expandToRegularFiles([top, dir.appendingPathComponent("link.txt")])
        #expect(mixed.map { $0.lastPathComponent } == ["top.txt"])
    }

    @Test
    func verifyWithoutSignatureHandlesNestedDirectoryPaths() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // payloadRoot 下放嵌套真实文件，manifest 用带 `/` 的 relativePath。
        try fm.createDirectory(at: dir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        let nested = try writeFile("nested-content", named: "sub/nested.txt", in: dir)
        let nestedSHA = try SIZArchive.computeInnerArchiveSHA256(of: nested)

        let manifest = SZSArchive.Manifest(
            schema: SZSArchive.schemaIdentifier,
            version: SZSArchive.schemaVersion,
            createdAt: "2026-06-02T00:00:00Z",
            createdBy: "SimpleZip test",
            title: nil,
            description: nil,
            rootDirectoryHint: nil,
            files: [
                SZSArchive.FileEntry(relativePath: "sub/nested.txt", size: 14, sha256: nestedSHA, mediaType: nil)
            ]
        )
        let json = try SZSArchive.encodeManifest(manifest)
        let szsURL = dir.appendingPathComponent("demo.szs")
        try Data(makeClearsigned(json).utf8).write(to: szsURL)

        let report = try SZSArchive.verifyWithoutSignature(manifestURL: szsURL, payloadRoot: dir)
        #expect(report.summary.total == 1)
        #expect(report.summary.matched == 1)
        #expect(report.entries.first?.relativePath == "sub/nested.txt")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-SZSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
