//
//  ArchiveServiceParsingTests.swift
//  SimpleZip
//
//  围绕输出解析、条目展开和归一化辅助函数的边角案例测试。
//  原 ArchiveServiceTests 里已经覆盖了「正常的 7z/unzip 列表」一类的 happy path，
//  这里专门补「空输入、表头/分隔行、缺字段块、零子项目录」这类容易在后端拆分时被忽视的分支。
//

import Foundation
import Testing
@testable import SimpleZipCore

struct ArchiveServiceParsingTests {

    // MARK: - parseUnzipList 边角

    @Test
    func parseUnzipListReturnsEmptyForEmptyInput() {
        #expect(ArchiveService.parseUnzipList("").isEmpty)
    }

    @Test
    func parseUnzipListSkipsHeaderFooterAndDividerLines() {
        // unzip -l 输出里只有「长度 + 日期 + 时间 + 名字」格式的行才是真实条目，
        // 其余表头 / 分隔线 / 汇总都要被略过。
        let output = """
        Archive:  sample.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
                5  05-12-2026 10:30   foo.txt
        ---------                     -------
                5                     1 file
        """

        let items = ArchiveService.parseUnzipList(output)
        #expect(items.count == 1)
        #expect(items[0].name == "foo.txt")
    }

    // MARK: - parseSevenZipList 边角

    @Test
    func parseSevenZipListReturnsEmptyForEmptyInput() {
        #expect(ArchiveService.parseSevenZipList("").isEmpty)
    }

    @Test
    func parseSevenZipListIgnoresArchiveHeaderBlock() {
        // 真实 7zz l -slt 输出在条目前会先输出 archive 自己的元信息块：
        // 含 Type / Physical Size / Headers Size / Method / Solid / Blocks 等字段，
        // 其中 Method 看着也像 entry 元数据，所以早期的解析器会误把 archive 的绝对路径
        // 当成 entry 名报出去，触发 ArchiveSafety 的「绝对路径不安全」拦截。
        // 这个测试钉死「头块必须被跳过」的契约。
        let output = """
        Path = /Users/me/archive.7z
        Type = 7z
        Physical Size = 268
        Headers Size = 230
        Method = LZMA2:12
        Solid = +
        Blocks = 1

        Path = real/file.txt
        Size = 12
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Method = LZMA2
        """

        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.count == 1)
        #expect(items[0].name == "real/file.txt")
    }

    @Test
    func parseSevenZipListSplitsMultipleBlocksByBlankLines() {
        // 7z 列表每两条之间用空行分隔。
        let output = """
        Path = a.txt
        Size = 1
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Method = LZMA2

        Path = b.txt
        Size = 2
        Modified = 2026-05-13 01:02:04
        Attributes = A
        Method = LZMA2
        """

        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.count == 2)
        #expect(items.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test
    func parseSevenZipListHandlesCRLFLineEndings() {
        // 走密码路径时 list 用 PTY 跑 7zz；macOS termios 默认 ONLCR 会把 \n 转成 \r\n。
        // 这种输出曾经让解析器只剩一个伪 entry（空白分隔行变成 "\r" 不再触发 flush，
        // 后续条目的 values 互相覆盖到同一份 dict）。这条测试确保 CRLF 也能正确分块。
        let output = "Path = a.txt\r\nSize = 1\r\nModified = 2026-05-13 01:02:03\r\nAttributes = A\r\nMethod = LZMA2\r\n\r\nPath = b.txt\r\nSize = 2\r\nModified = 2026-05-13 01:02:04\r\nAttributes = A\r\nMethod = LZMA2\r\n"

        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.count == 2)
        #expect(items.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test
    func parseSevenZipListSkipsDotPathBlock() {
        // Path = "." 是 7z 给出归档根的占位条目，不应该出现在用户列表里。
        let output = """
        Path = .
        Size = 0
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Method = LZMA2

        Path = file.txt
        Size = 4
        Modified = 2026-05-13 01:02:04
        Attributes = A
        Method = LZMA2
        """

        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.map(\.name) == ["file.txt"])
    }

    // MARK: - expandedEntryNames 边角

    @Test
    func expandedEntryNamesReturnsEmptyForEmptyInput() {
        #expect(ArchiveService.expandedEntryNames(for: []).isEmpty)
    }

    @Test
    func expandedEntryNamesPassesFilesThrough() {
        let items = [
            ArchiveItem(name: "a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: ""),
            ArchiveItem(name: "b/c.txt", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "")
        ]

        let result = ArchiveService.expandedEntryNames(for: items)
        #expect(result == ["a.txt", "b/c.txt"])
    }

    @Test
    func expandedEntryNamesDropsDirectoryWithoutDescendants() {
        // 选中一个目录但没把它的子项一并选上时，整个目录会从展开结果里消失 ——
        // 这是当前实现的「意图」：不选中文件就不展开，避免对空目录单独发起解压。
        // 把这一行为锁住，Phase 3/4 时如果有人改成「保留空目录」会立即被发现。
        let items = [
            ArchiveItem(name: "empty/", isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
        ]

        #expect(ArchiveService.expandedEntryNames(for: items).isEmpty)
    }

    @Test
    func expandedEntryNamesDeduplicatesWhenFilesAlsoListedSeparately() {
        // 同一文件既出现在目录展开下、又被单独选中时，最终结果只应留一份。
        let items = [
            ArchiveItem(name: "dir/", isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: ""),
            ArchiveItem(name: "dir/a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "")
        ]

        let result = ArchiveService.expandedEntryNames(for: items)
        #expect(result == ["dir/a.txt"])
    }

    // MARK: - 名字归一化

    @Test
    func normalizedEntryNamePreservesTrailingSlashForDirectories() {
        // 目录条目以 / 结尾的语义要保留下来，否则 expandedEntryNames 会把目录误判为文件。
        #expect(ArchiveService.normalizedEntryName("dir/") == "dir/")
        #expect(ArchiveService.normalizedEntryName("dir") == "dir")
    }

    @Test
    func normalizedEntryNameStripsLeadingSlash() {
        // 7-Zip 偶尔会输出以 / 起首的绝对样式路径，与不带前导斜杠的版本应被视作同一条。
        #expect(ArchiveService.normalizedEntryName("/dir/file.txt") == "dir/file.txt")
    }

    @Test
    func normalizedDirectoryPrefixAlwaysEndsWithSlash() {
        // 用作前缀匹配时必须带末尾 / 才不会把 "a/foo" 误判为 "a" 的子项。
        #expect(ArchiveService.normalizedDirectoryPrefix("dir") == "dir/")
        #expect(ArchiveService.normalizedDirectoryPrefix("dir/") == "dir/")
        #expect(ArchiveService.normalizedDirectoryPrefix("/dir") == "dir/")
    }

    // MARK: - ZIP 加密探测

    @Test
    func archiveItemsSuggestPasswordRequirementUsesItemsForSevenZip() {
        // 7z 仅看 isEncrypted / method —— 没有 ZIP 那种解析二进制结构的路径。
        let plainItem = ArchiveItem(
            name: "a.txt", isDirectory: false, size: 1, modified: nil,
            sizeText: "", modifiedText: "", method: "LZMA2", isEncrypted: false
        )
        #expect(!ArchiveService.archiveItemsSuggestPasswordRequirement([plainItem], in: URL(fileURLWithPath: "/tmp/x.7z")))
    }

    @Test
    func detectZipEncryptionReturnsNoneForUnencryptedZip() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "hello".write(
            to: sourceDirectory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        let archiveURL = tempDirectory.appendingPathComponent("plain.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        #expect(ArchiveService.detectZipEncryption(in: archiveURL) == .none)
    }

    @Test
    func detectZipEncryptionReturnsAES256ForAESEncryptedZip() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "classified".write(
            to: sourceDirectory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        options.password = "secret"
        options.passwordConfirmation = "secret"
        options.encryptionMethod = .aes256
        let archiveURL = tempDirectory.appendingPathComponent("secure.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        // 通过解析 ZIP 中央目录里的 AES extra field（headerID 0x9901、strength=3）识别 AES-256。
        // 任何对 detectZipEncryption 的修改如果错位了 extra field 解析都会破坏这条断言。
        #expect(ArchiveService.detectZipEncryption(in: archiveURL) == .aes256)
    }

    @Test
    func detectZipEncryptionReturnsUnknownForNonZipExtension() {
        // 非 .zip 扩展名直接 short-circuit 返回 unknown，避免错误地把别的格式当 zip 来解析。
        let url = URL(fileURLWithPath: "/tmp/something.7z")
        #expect(ArchiveService.detectZipEncryption(in: url) == .unknown)
    }

    @Test
    func archiveItemsSuggestPasswordRequirementForUnencryptedZipReturnsFalse() async throws {
        // ZIP 路径会走 detectZipEncryption；未加密的 zip 应返回 false 不要弹密码框。
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "hi".write(
            to: sourceDirectory.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        let archiveURL = tempDirectory.appendingPathComponent("plain.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let items = try await ArchiveService.list(archiveURL)
        #expect(!ArchiveService.archiveItemsSuggestPasswordRequirement(items, in: archiveURL))
    }

    // MARK: - 辅助

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
