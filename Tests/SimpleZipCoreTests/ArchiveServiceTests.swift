import Foundation
import Testing
@testable import SimpleZipCore

struct ArchiveServiceTests {
    @Test
    func zipExcludePatternsIncludeBuiltinsAndCustomRules() {
        var options = ArchiveCreationOptions()
        options.skipDSStore = true
        options.skipHiddenFiles = true
        options.customExcludes = "*.tmp, build/*\n.cache"

        let patterns = ArchiveService.zipExcludePatterns(from: options)

        #expect(
            patterns == [".*", "*.DS_Store", "*.tmp", "*/.*", "*/.DS_Store", ".cache", "build/*"].sorted()
        )
    }

    @Test
    func customExcludePatternsSplitLinesAndCommas() {
        let patterns = ArchiveService.customExcludePatterns(from: " *.tmp, build/* \n\n.cache,")

        #expect(patterns == ["*.tmp", "build/*", ".cache"])
    }

    @Test
    func splitCommandLineArgumentsHandlesQuotesAndEscapes() {
        let arguments = ArchiveService.splitCommandLineArguments(from: "-mx=9 -xr!\"My Cache\" '-foo bar' \"escaped\\\"quote\"")

        #expect(arguments == ["-mx=9", "-xr!My Cache", "-foo bar", "escaped\"quote"])
    }

    @Test
    func normalizedSevenZipVolumeSizeValidatesInput() throws {
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: "") == nil)
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: " 256M ") == "256m")
        #expect(try ArchiveService.normalizedSevenZipVolumeSize(from: "512k") == "512k")
        #expect(throws: ArchiveError.self) {
            try ArchiveService.normalizedSevenZipVolumeSize(from: "two gb")
        }
    }

    @Test
    func excludedFileCountMatchesBuiltInAndCustomRules() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceDirectory.appendingPathComponent(".DS_Store").path, contents: Data())
        FileManager.default.createFile(atPath: sourceDirectory.appendingPathComponent(".env").path, contents: Data())
        FileManager.default.createFile(atPath: nestedDirectory.appendingPathComponent("cache.tmp").path, contents: Data())
        FileManager.default.createFile(atPath: nestedDirectory.appendingPathComponent("keep.txt").path, contents: Data())

        var options = ArchiveCreationOptions()
        options.skipDSStore = true
        options.skipHiddenFiles = false
        options.customExcludes = "*.tmp"
        #expect(ArchiveService.excludedFileCount(in: [sourceDirectory], options: options) == 2)

        options.skipHiddenFiles = true
        #expect(ArchiveService.excludedFileCount(in: [sourceDirectory], options: options) == 3)
    }

    @Test
    func parseUnzipListCapturesRawSortFields() {
        let output = """
        Archive:  sample.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
                5  05-12-2026 10:30   foo.txt
                0  05-12-2026 10:31   dir/
                7  05-12-2026 10:32   dir/bar.txt
        ---------                     -------
               12                     3 files
        """

        let items = ArchiveService.parseUnzipList(output)

        #expect(items.count == 3)
        #expect(items[0].name == "foo.txt")
        #expect(items[0].size == 5)
        #expect(items[0].modified != nil)
        #expect(items[1].name == "dir/")
        #expect(items[1].size == nil)
    }

    @Test
    func parseZipListUsesTarPathsAndUnzipMetadata() {
        let tarOutput = """
        foo.txt
        dir/
        dir/bar.txt
        """
        let unzipOutput = """
          Length      Date    Time    Name
        ---------  ---------- -----   ----
                5  05-12-2026 10:30   foo.txt
                0  05-12-2026 10:31   dir/
                7  05-12-2026 10:32   dir/bar.txt
        ---------                     -------
               12                     3 files
        """

        let items = ArchiveService.parseZipList(tarOutput: tarOutput, unzipOutput: unzipOutput)

        #expect(items.map(\.name) == ["foo.txt", "dir/", "dir/bar.txt"])
        #expect(items[0].size == 5)
        #expect(items[2].size == 7)
        #expect(items[2].modifiedText == "05-12-2026 10:32")
    }

    @Test
    func parseZipListDecodesEscapedTarPaths() {
        let tarOutput = """
        payload/
        payload/\\344\\270\\255\\346\\226\\207.txt
        """
        let unzipOutput = """
          Length      Date    Time    Name
        ---------  ---------- -----   ----
                0  05-12-2026 10:31   payload/
                7  05-12-2026 10:32   payload/�?�??.txt
        ---------                     -------
                7                     2 files
        """

        let items = ArchiveService.parseZipList(tarOutput: tarOutput, unzipOutput: unzipOutput)

        #expect(items.map(\.name) == ["payload/", "payload/中文.txt"])
    }

    @Test
    func parseSevenZipListCapturesNumericAndDateFields() {
        let output = """
        Path = dir/file.txt
        Size = 12
        Packed Size = 8
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Method = LZMA2:12

        Path = dir/
        Size = 0
        Packed Size = 0
        Modified = 2026-05-13 01:02:00
        Attributes = D
        Folder = +
        Method = 
        """

        let items = ArchiveService.parseSevenZipList(output)

        #expect(items.count == 2)
        #expect(items[0].name == "dir/file.txt")
        #expect(items[0].size == 12)
        #expect(items[0].modified != nil)
        #expect(items[1].name == "dir/")
        #expect(items[1].isDirectory)
        #expect(items[1].size == nil)
    }

    @Test
    func parseSevenZipListTreatsAttributeDEntryAsDirectory() {
        // 某些归档把目录标成 Attributes=D 但 Folder=-（或缺失）。只看 Folder 会把它当 0 字节文件 →
        // 跟合成的同名文件夹并存出现「幽灵文件」。Attributes 前缀 D 也必须判为目录。
        let output = """
        Path = minecraft
        Size = 0
        Modified = 2026-05-28 01:44:08
        Attributes = D drwxr-xr-x
        Folder = -
        Method =\u{20}

        Path = minecraft/level.dat
        Size = 100
        Attributes = A
        Method = LZMA2:12
        """

        let items = ArchiveService.parseSevenZipList(output)
        let dir = items.first { $0.name == "minecraft" }
        #expect(dir?.isDirectory == true)
        #expect(dir?.size == nil)
    }

    @Test
    func parseSevenZipListCapturesEncryptedEntries() {
        let output = """
        Path = locked/file.txt
        Size = 12
        Packed Size = 8
        Modified = 2026-05-13 01:02:03
        Attributes = A
        Encrypted = +
        Method = LZMA2:12 7zAES
        """

        let items = ArchiveService.parseSevenZipList(output)

        #expect(items.count == 1)
        #expect(items[0].isEncrypted)
    }

    @Test
    func archiveItemsSuggestPasswordRequirementForEncryptedSevenZipEntries() {
        let items = [
            ArchiveItem(
                name: "locked/file.txt",
                isDirectory: false,
                size: 12,
                modified: nil,
                sizeText: "12 bytes",
                modifiedText: "",
                method: "LZMA2:12 7zAES",
                isEncrypted: true
            )
        ]

        #expect(ArchiveService.archiveItemsSuggestPasswordRequirement(items, in: URL(fileURLWithPath: "/tmp/locked.7z")))
    }

    @Test
    func expandedEntryNamesExpandsDirectoriesToChildren() {
        let entries = [
            ArchiveItem(name: "dir/", isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: ""),
            ArchiveItem(name: "dir/a.txt", isDirectory: false, size: 1, modified: nil, sizeText: "1 byte", modifiedText: "", method: ""),
            ArchiveItem(name: "dir/sub/", isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: ""),
            ArchiveItem(name: "dir/sub/b.txt", isDirectory: false, size: 2, modified: nil, sizeText: "2 bytes", modifiedText: "", method: "")
        ]

        let expanded = ArchiveService.expandedEntryNames(for: entries)

        #expect(expanded == ["dir/a.txt", "dir/sub/b.txt"])
    }

    @Test
    func archiveSafetyDetectsPathTraversalAndAbsoluteEntries() {
        #expect(!ArchiveSafety.isUnsafeEntryName("safe/folder/file.txt"))
        #expect(ArchiveSafety.isUnsafeEntryName("../escape.txt"))
        #expect(ArchiveSafety.isUnsafeEntryName("safe/../../escape.txt"))
        #expect(ArchiveSafety.isUnsafeEntryName("/tmp/escape.txt"))
        #expect(ArchiveSafety.isUnsafeEntryName("C:\\Users\\escape.txt"))
        #expect(ArchiveSafety.isUnsafeEntryName("\\\\server\\share\\escape.txt"))
    }

    /// P1(Shortcuts 无人值守入口):输出基名必须是单段纯文件名 —— `../escape` 这类名字
    /// 拼路径会把产物带出目标目录,必须在拼接前拒绝。
    @Test
    func archiveSafetyRejectsUnsafeOutputBaseNames() {
        #expect(!ArchiveSafety.isUnsafeOutputBaseName("release"))
        #expect(!ArchiveSafety.isUnsafeOutputBaseName("我的归档 2"))
        #expect(!ArchiveSafety.isUnsafeOutputBaseName("report.final"))   // 含点但非上跳 —— 合法
        #expect(ArchiveSafety.isUnsafeOutputBaseName(""))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("."))
        #expect(ArchiveSafety.isUnsafeOutputBaseName(".."))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("../escape"))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("sub/escape"))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("sub\\escape"))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("/tmp/abs"))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("~trick"))
        #expect(ArchiveSafety.isUnsafeOutputBaseName("C:evil"))
    }

    @Test
    func archiveSafetyValidatorRejectsSymlinksInExtractedTree() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let target = tempDirectory.appendingPathComponent("target.txt")
        let link = tempDirectory.appendingPathComponent("link.txt")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ArchiveError.self) {
            try ArchiveSafety.validateExtractedTree(at: tempDirectory)
        }
    }

    @Test
    func sevenZipCreateArgumentsIncludeAdvancedOptions() throws {
        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.compressionLevel = .maximum
        options.password = "secret"
        options.skipDSStore = false
        options.skipHiddenFiles = false
        options.customExcludes = "*.tmp"
        options.sevenZipMethod = .ppmd
        options.sevenZipThreadCount = 4
        options.sevenZipSolidArchive = false
        options.sevenZipEncryptFileNames = false
        options.sevenZipVolumeSize = "256M"

        let arguments = try ArchiveService.sevenZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/archive.7z"),
            relativeNames: ["alpha", "beta"],
            options: options
        )

        #expect(arguments.contains("-mx=9"))
        #expect(arguments.contains("-p"))
        #expect(arguments.contains("-mhe=off"))
        #expect(arguments.contains("-ms=off"))
        #expect(arguments.contains("-m0=PPMd"))
        #expect(arguments.contains("-mmt=4"))
        #expect(arguments.contains("-v256m"))
        #expect(arguments.contains("-xr!*.tmp"))
    }

    @Test
    func sevenZipZipCreateArgumentsIncludeSplitVolume() throws {
        var options = ArchiveCreationOptions()
        options.format = .zip
        options.compressionLevel = .fast
        options.password = "secret"
        options.sevenZipVolumeSize = "64M"
        options.customExcludes = "*.tmp"

        let arguments = try ArchiveService.sevenZipZipCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/archive.zip"),
            relativeNames: ["alpha", "beta"],
            options: options
        )

        #expect(arguments.contains("-tzip"))
        #expect(arguments.contains("-mx=1"))
        #expect(arguments.contains("-p"))
        #expect(arguments.contains("-v64m"))
        #expect(arguments.contains("-xr!*.tmp"))
    }

    @Test
    func rarCreateArgumentsIncludeCoreOptions() throws {
        var options = ArchiveCreationOptions()
        options.format = .rar
        options.compressionLevel = .maximum
        options.password = "secret"
        options.sevenZipEncryptFileNames = true
        options.sevenZipPathMode = .relative
        options.sevenZipVolumeSize = "1G"
        options.customExcludes = "*.tmp"
        options.rawParameters = "-rr5"

        let arguments = try ArchiveService.rarCreateArguments(
            destination: URL(fileURLWithPath: "/tmp/archive.rar"),
            relativeNames: ["payload"],
            options: options
        )

        #expect(arguments.first == "a")
        #expect(arguments.contains("-ma5"))
        #expect(arguments.contains("-m5"))
        #expect(arguments.contains("-ep1"))
        #expect(arguments.contains("-v1g"))
        #expect(arguments.contains("-hp"))
        #expect(arguments.contains("-x*.tmp"))
        #expect(arguments.contains("-rr5"))
    }

    @Test
    func supportedArchiveURLNormalizesSplitAndMultipartVolumes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let splitRoot = tempDirectory.appendingPathComponent("sample.001")
        let splitPart = tempDirectory.appendingPathComponent("sample.002")
        let zipRoot = tempDirectory.appendingPathComponent("bundle.zip")
        let zipPart = tempDirectory.appendingPathComponent("bundle.z01")
        let sevenZipSplitRoot = tempDirectory.appendingPathComponent("payload.7z.001")
        let sevenZipSplitPart = tempDirectory.appendingPathComponent("payload.7z.003")
        let rarRoot = tempDirectory.appendingPathComponent("movie.part01.rar")
        let rarPart = tempDirectory.appendingPathComponent("movie.part02.rar")
        let legacyRarRoot = tempDirectory.appendingPathComponent("legacy.rar")
        let legacyRarPart = tempDirectory.appendingPathComponent("legacy.r01")

        for url in [splitRoot, splitPart, zipRoot, zipPart, sevenZipSplitRoot, sevenZipSplitPart, rarRoot, rarPart, legacyRarRoot, legacyRarPart] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        #expect(ArchiveService.supportedArchiveURL(splitPart) == splitRoot)
        #expect(ArchiveService.supportedArchiveURL(zipPart) == zipRoot)
        #expect(ArchiveService.supportedArchiveURL(zipRoot) == zipRoot)
        #expect(ArchiveService.supportedArchiveURL(sevenZipSplitPart) == sevenZipSplitRoot)
        #expect(ArchiveService.supportedArchiveURL(rarPart) == rarRoot)
        #expect(ArchiveService.supportedArchiveURL(legacyRarPart) == legacyRarRoot)
    }

    @Test
    func createAndExtractZipArchiveRoundTripsFiles() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("source", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "hello zip".write(
            to: sourceDirectory.appendingPathComponent("root.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "inside".write(
            to: nestedDirectory.appendingPathComponent("child.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        let archiveURL = tempDirectory.appendingPathComponent("roundtrip.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let items = try await ArchiveService.list(archiveURL)
        #expect(items.contains { $0.name == "source/root.txt" })
        #expect(items.contains { $0.name == "source/nested/child.txt" })

        let destination = tempDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await ArchiveService.extract(archiveURL, to: destination)

        let rootText = try String(
            contentsOf: destination.appendingPathComponent("source/root.txt"),
            encoding: .utf8
        )
        let childText = try String(
            contentsOf: destination.appendingPathComponent("source/nested/child.txt"),
            encoding: .utf8
        )
        #expect(rootText == "hello zip")
        #expect(childText == "inside")
    }

    @Test
    func selectedZipExtractionPreservesRequestedEntryPath() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("source", isDirectory: true)
        let nestedDirectory = sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "ignore me".write(
            to: sourceDirectory.appendingPathComponent("root.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "selected".write(
            to: nestedDirectory.appendingPathComponent("child.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        let archiveURL = tempDirectory.appendingPathComponent("selected.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let entry = ArchiveItem(
            name: "source/nested/child.txt",
            isDirectory: false,
            size: nil,
            modified: nil,
            sizeText: "",
            modifiedText: "",
            method: ""
        )
        let destination = tempDirectory.appendingPathComponent("selected-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await ArchiveService.extract(archiveURL, entries: [entry], to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source/nested/child.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("source/root.txt").path))
    }

    @Test
    func createAndExtractAESZipArchiveWithPassword() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("secure", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "top secret".write(
            to: sourceDirectory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .zip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        options.password = "secret-123"
        options.passwordConfirmation = "secret-123"
        options.encryptionMethod = .aes256
        let archiveURL = tempDirectory.appendingPathComponent("secure.zip")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let destination = tempDirectory.appendingPathComponent("secure-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await ArchiveService.extract(archiveURL, to: destination, password: "secret-123", zipDecryptionMethod: .automatic)

        let extracted = try String(
            contentsOf: destination.appendingPathComponent("secure/note.txt"),
            encoding: .utf8
        )
        #expect(extracted == "top secret")
    }

    @Test
    func listingHeaderEncryptedSevenZipRequiresPasswordWithoutHanging() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("secure", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "classified".write(
            to: sourceDirectory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        options.password = "secret-123"
        options.passwordConfirmation = "secret-123"
        options.sevenZipEncryptFileNames = true
        let archiveURL = tempDirectory.appendingPathComponent("secure.7z")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService.list(archiveURL)
        }

        _ = try await ArchiveService.list(archiveURL, password: "secret-123")
    }

    @Test
    func createAndExtractHeaderEncryptedSevenZipArchiveWithPassword() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("secure", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "classified".write(
            to: sourceDirectory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .sevenZip
        options.skipDSStore = false
        options.skipHiddenFiles = false
        options.password = "secret-123"
        options.passwordConfirmation = "secret-123"
        options.sevenZipEncryptFileNames = true
        let archiveURL = tempDirectory.appendingPathComponent("secure.7z")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let destination = tempDirectory.appendingPathComponent("secure-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await ArchiveService.extract(archiveURL, to: destination, password: "secret-123")

        let extracted = try String(
            contentsOf: destination.appendingPathComponent("secure/note.txt"),
            encoding: .utf8
        )
        #expect(extracted == "classified")
    }

    @Test
    func createTarArchiveContainsExpectedEntries() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "tar root".write(
            to: sourceDirectory.appendingPathComponent("root.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .tar
        options.skipDSStore = false
        options.skipHiddenFiles = false
        let archiveURL = tempDirectory.appendingPathComponent("payload.tar")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let listing = try runProcess("/usr/bin/tar", arguments: ["-tf", archiveURL.path])
            .split(separator: "\n")
            .map(String.init)

        #expect(listing.contains("payload/"))
        #expect(listing.contains("payload/root.txt"))
    }

    @Test
    func createDiskImageArchiveListsSelectedItems() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceDirectory = tempDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "inside dmg".write(
            to: sourceDirectory.appendingPathComponent("root.txt"),
            atomically: true,
            encoding: .utf8
        )

        var options = ArchiveCreationOptions()
        options.format = .dmg
        let archiveURL = tempDirectory.appendingPathComponent("payload.dmg")
        try await ArchiveService.createArchive(from: [sourceDirectory], destination: archiveURL, options: options)

        let items = try await ArchiveService.list(archiveURL)
        #expect(items.contains { $0.name == "payload/" && $0.isDirectory })
    }

    @Test
    func parseSevenZipBenchmarkCapturesSummaryMetrics() {
        let output = """
        RAM usage:   1779 MB,  # Benchmark threads:      8

                               Compressing  |                  Decompressing
        Dict     Speed Usage    R/U Rating  |      Speed Usage    R/U Rating
                 KiB/s     %   MIPS   MIPS  |      KiB/s     %   MIPS   MIPS

        22:      48478   562   8387  47160  |     443614   559   6764  37828
        23:      35313   466   7717  35981  |     382130   493   6708  33055
        ----------------------------------  | ------------------------------
        Avr:     39370   508   8093  41167  |     402139   530   6601  35015
        Tot:             519   7347  38091
        """

        let report = ArchiveService.parseSevenZipBenchmark(
            output,
            backendDescription: "Bundled 7-Zip",
            options: SevenZipBenchmarkOptions(dictionarySizeMB: 32, threadCount: 4)
        )

        #expect(report.backendDescription == "Bundled 7-Zip")
        #expect(report.benchmarkThreads == 8)
        #expect(report.compressionAverage?.speedKiBPerSecond == 39370)
        #expect(report.decompressionAverage?.ratingMips == 6601)
        #expect(report.totalRatingMips == 38091)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw ArchiveError.commandFailed(output)
        }
        return output
    }
}

/// 0.4.2 #9:会话级密码缓存(纯内存)。
struct SessionPasswordCacheTests {

    @Test func recordsPerPathAndLastSuccessful() {
        let cache = SessionPasswordCache()
        let a = URL(fileURLWithPath: "/tmp/a.zip")
        let b = URL(fileURLWithPath: "/tmp/b.zip")
        #expect(cache.candidates(for: a).isEmpty)

        cache.record("secret-a", for: a)
        #expect(cache.candidates(for: a) == ["secret-a"])
        // b 没记过自己的 → 给「最近成功」的 secret-a(批量解压同密码场景)。
        #expect(cache.candidates(for: b) == ["secret-a"])

        cache.record("secret-b", for: b)
        // a 的候选 = 自己的 + 最近成功的(去重)。
        #expect(cache.candidates(for: a) == ["secret-a", "secret-b"])
        #expect(cache.candidates(for: b) == ["secret-b"])
    }

    @Test func emptyPasswordIsNeverRecorded() {
        let cache = SessionPasswordCache()
        cache.record("", for: URL(fileURLWithPath: "/tmp/x.zip"))
        #expect(cache.candidates(for: URL(fileURLWithPath: "/tmp/x.zip")).isEmpty)
    }

    @Test func clearAllForgetsEverything() {
        let cache = SessionPasswordCache()
        let url = URL(fileURLWithPath: "/tmp/x.zip")
        cache.record("pw", for: url)
        cache.clearAll()
        #expect(cache.candidates(for: url).isEmpty)
    }
}
