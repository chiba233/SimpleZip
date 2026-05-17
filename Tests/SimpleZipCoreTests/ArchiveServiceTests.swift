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
