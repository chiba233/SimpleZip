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

    // MARK: - parseArchiveHeaderComment（0.4.1 #114 归档级注释,只读）

    @Test func headerCommentParsesBraceForm() {
        let output = """
        Listing archive: a.zip

        --
        Path = a.zip
        Type = zip
        Physical Size = 164
        Comment = 
        {
        第一行注释
        line two
        }

        ----------
        Path = src/a.txt
        Comment = entry-level 注释不该被取到
        """
        #expect(ArchiveService.parseArchiveHeaderComment(output) == "第一行注释\nline two")
    }

    @Test func headerCommentParsesInlineFormAndEmpty() {
        let inline = """
        Path = a.zip
        Type = zip
        Comment = single line

        ----------
        """
        #expect(ArchiveService.parseArchiveHeaderComment(inline) == "single line")
        let none = """
        Path = a.zip
        Type = zip
        Comment = 

        ----------
        Path = b.txt
        """
        #expect(ArchiveService.parseArchiveHeaderComment(none).isEmpty)
        #expect(ArchiveService.parseArchiveHeaderComment("").isEmpty)
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

    @Test
    func streamParserPerCharChunksMatchOneShot() {
        // 流式路径(SevenZipBackend.list)按任意字节边界喂 chunk;现有 fixture 都是整串喂,测不到「跨 chunk
        // 切半行 / 切在空白分隔行」。这条用最极端的逐字符喂,断言与一次性 parseSevenZipList 完全一致,
        // 并确认头块(Type/Physical Size)被正确跳过。
        let output = """
        Path = /tmp/x.7z
        Type = 7z
        Physical Size = 100

        ----------
        Path = a.txt
        Size = 1
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Method = LZMA2

        Path = dir/b.txt
        Size = 2
        Modified = 2026-05-13 01:02:04
        Attributes = A
        Method = LZMA2
        """
        let oneShot = ArchiveService.parseSevenZipList(output)
        let parser = ArchiveService.SevenZipListStreamParser()
        for ch in output { parser.consume(String(ch)) }
        let streamed = parser.finish()
        #expect(oneShot.map(\.name) == ["a.txt", "dir/b.txt"])
        #expect(streamed.map(\.name) == oneShot.map(\.name))
        #expect(streamed.map(\.modifiedText) == oneShot.map(\.modifiedText))
    }

    @Test
    func streamParserPerCharChunksHandleCRLF() {
        // 密码路径用 PTY,macOS ONLCR 把 \n 变 \r\n —— 流式逐 chunk 也必须正确去 \r 并分块。
        let output = "Path = a.txt\r\nSize = 1\r\nModified = 2026-05-13 01:02:03\r\nMethod = LZMA2\r\n\r\nPath = b.txt\r\nSize = 2\r\nModified = 2026-05-13 01:02:04\r\nMethod = LZMA2\r\n"
        let parser = ArchiveService.SevenZipListStreamParser()
        for ch in output { parser.consume(String(ch)) }
        let streamed = parser.finish()
        #expect(streamed.map(\.name) == ["a.txt", "b.txt"])
        // value 不应带残留 \r(否则 ArchiveSafety 误判)。
        #expect(streamed.allSatisfy { !$0.name.contains("\r") && !$0.method.contains("\r") })
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

/// 0.4.2 批量测试:失败诊断文本 → 失败桶 的归类启发式。
struct ArchiveTestFailureClassificationTests {

    @Test func classifiesPasswordFailures() {
        #expect(ArchiveService.classifyTestFailure("ERROR: Wrong password : data.7z") == .encrypted)
        #expect(ArchiveService.classifyTestFailure("Cannot open encrypted archive. Wrong password?") == .encrypted)
        #expect(ArchiveService.classifyTestFailure("\nEnter password (will not be echoed):") == .encrypted)
    }

    @Test func classifiesMissingVolume() {
        #expect(ArchiveService.classifyTestFailure("ERROR: Missing volume : archive.7z.002") == .missingVolume)
    }

    @Test func classifiesUnsupported() {
        #expect(ArchiveService.classifyTestFailure("ERROR: x.bin\nCannot open the file as archive") == .unsupported)
        #expect(ArchiveService.classifyTestFailure("Unsupported Method") == .unsupported)
    }

    @Test func classifiesCorruption() {
        #expect(ArchiveService.classifyTestFailure("CRC Failed : docs/report.pdf") == .corrupted)
        #expect(ArchiveService.classifyTestFailure("ERROR: Data Error : a.txt") == .corrupted)
        #expect(ArchiveService.classifyTestFailure("ERRORS:\nHeaders Error\nUnconfirmed start of archive") == .corrupted)
        #expect(ArchiveService.classifyTestFailure("WARNINGS:\nThere are some data after the end of the payload data") == .corrupted)
    }

    @Test func passwordWinsOverCRCWhenBothPresent() {
        // 加密包口令错时 7zz 常同时报 CRC 错 —— 根因是口令,归 encrypted。
        #expect(ArchiveService.classifyTestFailure("Wrong password? CRC Failed in encrypted file") == .encrypted)
    }

    @Test func unknownTextFallsBackToOther() {
        #expect(ArchiveService.classifyTestFailure("something exploded") == .other)
        #expect(ArchiveService.classifyTestFailure("") == .other)
    }
}

/// 0.4.2 #7:归档路径安全报告(纯静态分析)。
struct ArchiveSecurityReportTests {

    private func entry(_ name: String, attributes: String = "", symlinkTarget: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: 1, modified: nil, sizeText: "", modifiedText: "", method: "", attributes: attributes, symlinkTarget: symlinkTarget)
    }

    @Test func cleanArchiveYieldsNoFindings() {
        let items = [entry("docs/a.txt"), entry("docs/b.txt"), entry("src/main.swift")]
        #expect(ArchiveSecurityReport.analyze(items).isEmpty)
    }

    @Test func detectsPathEscapeFamilies() {
        let items = [
            entry("/etc/passwd"),
            entry("../../escape.txt"),
            entry("C:\\Windows\\evil.dll"),
            entry("\\\\server\\share\\x"),
            entry("dir\\windows-style.txt")
        ]
        let kinds = ArchiveSecurityReport.analyze(items).map(\.kind)
        #expect(kinds.contains(.absolutePath))
        #expect(kinds.contains(.parentTraversal))
        #expect(kinds.contains(.windowsDrivePath))
        #expect(kinds.contains(.uncPath))
        #expect(kinds.contains(.backslashPath))
    }

    @Test func detectsControlAndBidiCharacters() {
        let rlo = "invoice\u{202E}fdp.exe"
        let findings = ArchiveSecurityReport.analyze([entry(rlo), entry("tab\tname.txt")])
        #expect(findings.first?.kind == .controlCharacters)
        #expect(findings.first?.entryPaths.count == 2)
    }

    @Test func detectsOverlongPaths() {
        let longComponent = String(repeating: "a", count: 256)
        let findings = ArchiveSecurityReport.analyze([entry("dir/\(longComponent).txt")])
        #expect(findings.map(\.kind) == [.overlongPath])
    }

    @Test func detectsSetuidMode() {
        let findings = ArchiveSecurityReport.analyze([entry("bin/su", attributes: "_ -rwsr-xr-x"), entry("bin/ok", attributes: "_ -rwxr-xr-x")])
        #expect(findings.map(\.kind) == [.setuidExecutable])
        #expect(findings.first?.entryPaths == ["bin/su"])
    }

    @Test func flagsOnlyExternalSymlinks() {
        let findings = ArchiveSecurityReport.analyze([
            entry("link-out", symlinkTarget: "/etc/passwd"),
            entry("link-up", symlinkTarget: "../../outside"),
            entry("link-in", symlinkTarget: "sibling/file.txt")
        ])
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .externalSymlink)
        #expect(findings.first?.entryPaths.count == 2)
    }

    @Test func detectsCaseCollisionsAndPlainDuplicates() {
        // #19 升级(用户拍板):字节级同路径再现从「只在列表可见」升级为安全报告类别 ——
        // 解压时后者静默覆盖前者,落盘与列表不符,值得点名。
        let findings = ArchiveSecurityReport.analyze([
            entry("README.md"), entry("readme.md"),   // 大小写冲突
            entry("same.txt"), entry("same.txt")      // 字节级纯重复 —— duplicateEntryPath
        ])
        #expect(findings.map(\.kind) == [.caseCollision, .duplicateEntryPath])
        #expect(findings.first?.entryPaths == ["README.md ↔ readme.md"])
        #expect(findings.last?.entryPaths == ["same.txt"])
    }

    // MARK: - 0.4.3 #14 跨平台文件名风险

    @Test func detectsNormalizationCollisions() {
        // 同一个「ä.txt」:NFC(单码位)vs NFD(a + 组合分音符)。Swift 字符串比较规范等价,
        // 所以必须按 UTF-8 字节区分 —— 这正是被检测的风险本身。
        let nfc = "\u{00E4}.txt"
        let nfd = "a\u{0308}.txt"
        let findings = ArchiveSecurityReport.analyze([entry(nfc), entry(nfd)])
        #expect(findings.map(\.kind) == [.normalizationCollision])
        // 同字节的重复不是规范化问题 —— 走 duplicateEntryPath 类别。
        #expect(ArchiveSecurityReport.analyze([entry(nfc), entry(nfc)]).map(\.kind) == [.duplicateEntryPath])
    }

    @Test func detectsWindowsReservedNames() {
        let findings = ArchiveSecurityReport.analyze([
            entry("docs/CON"),          // 整段保留名
            entry("aux.txt"),           // 保留名 + 扩展名同样致命
            entry("COM3/file.txt"),     // 目录段也算
            entry("console.txt"),       // 前缀相同但不是保留名 —— 不报
            entry("com0.txt")           // COM0 不在保留集 —— 不报
        ])
        #expect(findings.map(\.kind) == [.windowsReservedName])
        #expect(findings.first?.entryPaths.count == 3)
    }

    @Test func detectsTrailingSpaceOrDot() {
        let findings = ArchiveSecurityReport.analyze([
            entry("report. "),          // 尾随空格
            entry("notes./readme.txt"), // 目录段尾随点
            entry("normal.txt")         // 正常名 —— 不报(扩展名前的点不算尾随)
        ])
        #expect(findings.map(\.kind) == [.trailingSpaceOrDot])
        #expect(findings.first?.entryPaths.count == 2)
    }
}

/// 0.4.2 #8:解压前预检统计。
struct ArchiveExtractPreflightTests {

    private func entry(_ name: String, isDirectory: Bool = false, size: Int64? = nil, encrypted: Bool = false, symlinkTarget: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: isDirectory, size: size, modified: nil, sizeText: "", modifiedText: "", method: "", isEncrypted: encrypted, symlinkTarget: symlinkTarget)
    }

    @Test func countsFilesFoldersBytesSymlinksEncrypted() {
        let items = [
            entry("docs/", isDirectory: true),
            entry("docs/a.txt", size: 100),
            entry("docs/b.txt", size: 200, encrypted: true),
            entry("link", size: 0, symlinkTarget: "/etc/passwd")
        ]
        let preflight = ArchiveExtractPreflight.analyze(items)
        #expect(preflight.fileCount == 3)
        #expect(preflight.folderCount == 1)
        #expect(preflight.totalBytes == 300)
        #expect(preflight.symlinkCount == 1)
        #expect(preflight.encryptedEntryCount == 1)
        #expect(preflight.suspiciousEntryCount == 1)   // 外指 symlink
    }

    @Test func topLevelNamesDeduplicateAndSort() {
        let items = [
            entry("zeta/x.txt"), entry("zeta/y.txt"),
            entry("./alpha/a.txt"), entry("root.txt"), entry("/abs/ignore-leading.txt")
        ]
        #expect(ArchiveExtractPreflight.topLevelNames(of: items) == ["abs", "alpha", "root.txt", "zeta"])
    }
}

/// 0.4.2 #15:发布包检查的条目侧统计。
struct ReleaseInspectionTests {

    private func entry(_ name: String, isDirectory: Bool = false, size: Int64? = nil, attributes: String = "", symlinkTarget: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: isDirectory, size: size, modified: nil, sizeText: "", modifiedText: "", method: "", attributes: attributes, symlinkTarget: symlinkTarget)
    }

    @Test func statsCoverAllDimensions() {
        let items = [
            entry("docs/", isDirectory: true),
            entry("docs/a.txt", size: 100),
            entry("empty-dir/", isDirectory: true),
            entry(".DS_Store", size: 1),
            entry("bin/tool", size: 50, attributes: "_ -rwxr-xr-x"),
            entry("link", size: 0, symlinkTarget: "target")
        ]
        let stats = ReleaseInspection.stats(for: items)
        #expect(stats.fileCount == 4)
        #expect(stats.folderCount == 2)
        #expect(stats.totalBytes == 151)
        #expect(stats.junkCount == 1)
        #expect(stats.emptyDirectoryCount == 1)   // empty-dir 没有子条目;docs 有
        #expect(stats.executableCount == 1)
        #expect(stats.symlinkCount == 1)
    }

    @Test func executableModeDetection() {
        #expect(ReleaseInspection.isExecutableMode("_ -rwxr-xr-x"))
        #expect(ReleaseInspection.isExecutableMode("_ -rwsr-xr-x"))
        #expect(!ReleaseInspection.isExecutableMode("_ -rw-r--r--"))
        #expect(!ReleaseInspection.isExecutableMode("A"))
        #expect(!ReleaseInspection.isExecutableMode(""))
    }
}

/// 0.4.2:解压「跳过垃圾」的 staging 清扫。
struct RemoveJunkTests {

    @Test func removesJunkAndKeepsRealFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleZip-RemoveJunkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("__MACOSX/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("__MACOSX/sub/._a.txt"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("docs/.DS_Store"))
        try Data().write(to: root.appendingPathComponent("docs/._b.txt"))
        try Data("real".utf8).write(to: root.appendingPathComponent("docs/b.txt"))

        let removed = ArchiveJunkFiles.removeJunk(in: root)
        #expect(removed == 4)   // __MACOSX 整目录 + 两个 .DS_Store + 一个 ._b.txt
        // AppleDouble 对 Foundation 枚举不可见 —— 必须用 fileExists 验证它真被删了。
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("docs/._b.txt").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("__MACOSX").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("docs/.DS_Store").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("docs/b.txt").path))
    }

    /// 0.4.3 zstd 单流(实测 7zz 26.01):`-slt` 条目块没有 Path,只有空 Size/Packed Size 行——
    /// 解析器按 7zz 自己的命名规则合成内层名,否则 zst/tar.zst 打开是空列表。
    @Test func zstdSingleStreamListSynthesizesInnerEntry() {
        // 显式数组拼接:真实 7zz 输出的空值行是「Size = 」**带尾随空格**(没有空格的话
        // split 会丢掉空子串、key 记不上)——多行字面量里的尾随空格会被编辑器吞,这里写死。
        let output = [
            "Listing archive: /tmp/sample.tar.zst",
            "",
            "--",
            "Path = /tmp/sample.tar.zst",
            "Type = zstd",
            "Method = header-open-only: XXH64 single-segments",
            "",
            "----------",
            "Size = ",
            "Packed Size = ",
            ""
        ].joined(separator: "\n")
        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.count == 1)
        #expect(items.first?.name == "sample.tar")
        #expect(items.first?.isDirectory == false)
    }

    /// 合成名规则与 7zz 解压产物命名一致(实测):去掉 .zst;.tzst → stem + ".tar"。
    @Test func zstdInnerNameSynthesisMatchesSevenZip() {
        #expect(ArchiveService.singleStreamInnerName(forArchiveNamed: "a.txt.zst") == "a.txt")
        #expect(ArchiveService.singleStreamInnerName(forArchiveNamed: "sample.tar.zst") == "sample.tar")
        #expect(ArchiveService.singleStreamInnerName(forArchiveNamed: "foo.tzst") == "foo.tar")
    }

    /// 用真实 7zz 对 Xcode xip 的 `-slt` 输出文件验证(全量,含嵌套 xz 块和尾部 Warnings/Errors)。
    @Test func xipXarRealSevenZipOutput() throws {
        let output = try String(contentsOf: URL(fileURLWithPath: "/tmp/xip_slt.txt"))
        let items = ArchiveService.parseSevenZipList(output)
        #expect(items.count == 1)
        #expect(items.first?.name == "Content")
        #expect(items.first?.isDirectory == false)
        #expect(items.first?.size == 1_966_091_760)
    }
}
