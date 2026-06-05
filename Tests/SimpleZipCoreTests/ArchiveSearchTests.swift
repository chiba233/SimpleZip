import Foundation
import Testing
@testable import SimpleZipCore

/// #113 归档内搜索 —— 纯过滤谓词的回归测试。
struct ArchiveSearchTests {

    private func file(_ name: String, size: Int64? = 1, encrypted: Bool = false) -> ArchiveItem {
        ArchiveItem(
            name: name,
            isDirectory: false,
            size: size,
            modified: nil,
            sizeText: "",
            modifiedText: "",
            method: "",
            isEncrypted: encrypted
        )
    }

    private func dir(_ name: String) -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: true, size: nil, modified: nil, sizeText: "", modifiedText: "", method: "")
    }

    private var items: [ArchiveItem] {
        [
            file("src/main.swift", size: 100),
            file("src/util.swift", size: 50, encrypted: true),
            file("README.md", size: 2_000),
            dir("src/"),
            file("assets/logo.PNG", size: 10_000)
        ]
    }

    @Test func emptyQueryReturnsEverythingUnchanged() {
        let result = ArchiveSearch.filter(items, with: ArchiveSearchQuery())
        #expect(result.count == items.count)
    }

    @Test func textMatchesDisplayNameCaseInsensitively() {
        var q = ArchiveSearchQuery(); q.text = "main"
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/main.swift"])
    }

    @Test func nameScopeDoesNotMatchParentPathSegments() {
        // scope=.name 只看末级名；"src" 不应匹配到 src/main.swift（其 displayName 是 "main.swift"）。
        var q = ArchiveSearchQuery(); q.text = "src"; q.scope = .name
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/"]) // 只有目录自身的 displayName 是 "src"
    }

    @Test func fullPathScopeMatchesPathSegments() {
        var q = ArchiveSearchQuery(); q.text = "src/"; q.scope = .fullPath
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/main.swift", "src/util.swift", "src/"])
    }

    @Test func filesOnlyExcludesDirectories() {
        var q = ArchiveSearchQuery(); q.kind = .filesOnly
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.allSatisfy { !$0.isDirectory })
        #expect(result.count == 4)
    }

    @Test func foldersOnlyKeepsDirectories() {
        var q = ArchiveSearchQuery(); q.kind = .foldersOnly
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/"])
    }

    @Test func encryptedOnlyFiltersToEncryptedEntries() {
        var q = ArchiveSearchQuery(); q.encryptedOnly = true
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/util.swift"])
    }

    @Test func sizeBoundsExcludeDirectoriesAndOutOfRange() {
        var q = ArchiveSearchQuery(); q.minSize = 1_000
        let result = ArchiveSearch.filter(items, with: q)
        // 仅 README.md (2000) 与 logo.PNG (10000)；目录无大小被排除。
        #expect(Set(result.map(\.name)) == ["README.md", "assets/logo.PNG"])

        var q2 = ArchiveSearchQuery(); q2.minSize = 60; q2.maxSize = 5_000
        let r2 = ArchiveSearch.filter(items, with: q2)
        #expect(Set(r2.map(\.name)) == ["src/main.swift", "README.md"])
    }

    @Test func conditionsAreAndedTogether() {
        var q = ArchiveSearchQuery()
        q.text = ".swift"; q.scope = .fullPath; q.encryptedOnly = true
        let result = ArchiveSearch.filter(items, with: q)
        #expect(result.map(\.name) == ["src/util.swift"])
    }

    @Test func isEmptyReflectsActiveConstraints() {
        #expect(ArchiveSearchQuery().isEmpty)
        var q = ArchiveSearchQuery(); q.encryptedOnly = true
        #expect(!q.isEmpty)
        var q2 = ArchiveSearchQuery(); q2.text = "  "
        #expect(q2.isEmpty) // 纯空白文本不算约束
    }
}
