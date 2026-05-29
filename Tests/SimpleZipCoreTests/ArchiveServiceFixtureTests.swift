//
//  ArchiveServiceFixtureTests.swift
//  SimpleZip
//
//  使用预录 fixture 校验「读」路径，避免「自己写的 archive 自己再读」式的自证测试。
//  fixture 在 Tests/SimpleZipCoreTests/Fixtures/ 下，生成步骤见同目录 README.md。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct ArchiveServiceFixtureTests {

    // MARK: - Plain UTF-8 内容

    @Test
    func plainZipFixtureListsUnicodeAndNestedEntries() async throws {
        let url = try fixtureURL(named: "plain_unicode", extension: "zip")
        let items = try await ArchiveService.list(url)
        let names = Set(items.map(\.name))

        // /usr/bin/zip 输出的条目里至少包含这两个中文文件，且嵌套层级保留斜杠。
        #expect(names.contains("payload/根条目.txt"))
        #expect(names.contains("payload/nested/嵌套.txt"))
        // 不应该弹密码 —— fixture 是未加密的。
        #expect(!ArchiveService.archiveItemsSuggestPasswordRequirement(items, in: url))
    }

    @Test
    func plainSevenZipFixtureListsUnicodeAndNestedEntries() async throws {
        let url = try fixtureURL(named: "plain_unicode", extension: "7z")
        let items = try await ArchiveService.list(url)
        let names = Set(items.map(\.name))

        #expect(names.contains("payload/根条目.txt"))
        #expect(names.contains("payload/nested/嵌套.txt"))
        #expect(!ArchiveService.archiveItemsSuggestPasswordRequirement(items, in: url))
    }

    @Test
    func plainTarFixtureListsUnicodeAndNestedEntries() async throws {
        let url = try fixtureURL(named: "plain_unicode", extension: "tar")
        let items = try await ArchiveService.list(url)
        let names = Set(items.map(\.name))

        // tar 的目录条目通常带尾斜杠；我们只关心文件条目是否齐。
        #expect(names.contains("payload/根条目.txt"))
        #expect(names.contains("payload/nested/嵌套.txt"))
    }

    // MARK: - 解压 round-trip

    @Test
    func plainZipFixtureExtractsContentByteForByte() async throws {
        let url = try fixtureURL(named: "plain_unicode", extension: "zip")
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await ArchiveService.extract(url, to: tempDir)

        let rootContent = try String(contentsOf: tempDir.appendingPathComponent("payload/根条目.txt"), encoding: .utf8)
        let nestedContent = try String(contentsOf: tempDir.appendingPathComponent("payload/nested/嵌套.txt"), encoding: .utf8)
        // generate.sh 用 printf '根条目内容\n' 写入，extractor 必须严格保留 UTF-8 字节。
        #expect(rootContent == "根条目内容\n")
        #expect(nestedContent == "嵌套条目内容\n")
    }

    @Test
    func plainSevenZipFixtureExtractsContentByteForByte() async throws {
        let url = try fixtureURL(named: "plain_unicode", extension: "7z")
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await ArchiveService.extract(url, to: tempDir)

        let rootContent = try String(contentsOf: tempDir.appendingPathComponent("payload/根条目.txt"), encoding: .utf8)
        let nestedContent = try String(contentsOf: tempDir.appendingPathComponent("payload/nested/嵌套.txt"), encoding: .utf8)
        #expect(rootContent == "根条目内容\n")
        #expect(nestedContent == "嵌套条目内容\n")
    }

    // MARK: - 加密探测

    @Test
    func aes256ZipFixtureIsDetectedAsAES256() throws {
        let url = try fixtureURL(named: "aes256_password", extension: "zip")
        // 不调 list（会立即问密码），只走纯字节解析路径。
        let detection = ArchiveService.detectZipEncryption(in: url)
        #expect(detection == .aes256)
    }

    @Test
    func aes256ZipFixtureSuggestsPasswordWithoutListing() async throws {
        let url = try fixtureURL(named: "aes256_password", extension: "zip")
        // 即便 list 没真跑过，针对 ZIP 也应该靠 detectZipEncryption 给出「需要密码」的判断。
        let items: [ArchiveItem] = []
        #expect(ArchiveService.archiveItemsSuggestPasswordRequirement(items, in: url))
    }

    @Test
    func headerEncryptedSevenZipFixtureRequiresPasswordToList() async throws {
        let url = try fixtureURL(named: "aes256_password", extension: "7z")
        // header-encrypted 7z 不给密码连条目列表都拿不到 —— ArchiveService.list 必须把这种
        // 情况转成可识别的 ArchiveError，绝对不能阻塞。
        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService.list(url)
        }
    }

    @Test
    func headerEncryptedSevenZipFixtureListsWithCorrectPassword() async throws {
        let url = try fixtureURL(named: "aes256_password", extension: "7z")
        let items = try await ArchiveService.list(url, password: "fixture-pw")
        let names = Set(items.map(\.name))
        #expect(names.contains("payload/根条目.txt"))
    }

    @Test
    func headerEncryptedSevenZipFixtureExtractsWithCorrectPassword() async throws {
        let url = try fixtureURL(named: "aes256_password", extension: "7z")
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await ArchiveService.extract(url, to: tempDir, password: "fixture-pw")

        let rootContent = try String(contentsOf: tempDir.appendingPathComponent("payload/根条目.txt"), encoding: .utf8)
        #expect(rootContent == "根条目内容\n")
    }

    // MARK: - 路径穿越安全

    @Test
    func pathTraversalZipFixtureIsFlaggedByArchiveSafety() async throws {
        let url = try fixtureURL(named: "path_traversal", extension: "zip")
        let items = try await ArchiveService.list(url)
        let unsafe = ArchiveSafety.unsafeEntryNames(in: items)

        // 必须识别出 ../escape.txt；
        // payload/normal.txt 同时存在，确保安全检查不是「整个归档全打回」式粗暴。
        #expect(unsafe.contains { $0.contains("escape.txt") })
        #expect(!unsafe.contains { $0 == "payload/normal.txt" })
    }

    // MARK: - 辅助

    /// 从测试 bundle 的 Fixtures/ 子目录里取出 fixture URL。
    /// 没找到时直接抛错，让失败信息明确「fixture 缺失」而不是「解码失败」。
    private func fixtureURL(named name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw FixtureLookupError.notFound("\(name).\(ext)")
        }
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum FixtureLookupError: Error {
    case notFound(String)
}
