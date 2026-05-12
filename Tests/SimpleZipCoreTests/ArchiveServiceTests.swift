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
}
