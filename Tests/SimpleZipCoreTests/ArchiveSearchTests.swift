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

    @Test func modifiedAfterFiltersByDate() {
        let old = ArchiveItem(name: "old.txt", isDirectory: false, size: 1, modified: Date(timeIntervalSince1970: 1_000), sizeText: "1 B", modifiedText: "", method: "")
        let fresh = ArchiveItem(name: "fresh.txt", isDirectory: false, size: 1, modified: Date(timeIntervalSince1970: 2_000_000), sizeText: "1 B", modifiedText: "", method: "")
        let dated = ArchiveItem(name: "nodate.txt", isDirectory: false, size: 1, modified: nil, sizeText: "1 B", modifiedText: "", method: "")
        var query = ArchiveSearchQuery()
        query.modifiedAfter = Date(timeIntervalSince1970: 1_000_000)
        let result = ArchiveSearch.filter([old, fresh, dated], with: query)
        #expect(result.map(\.name) == ["fresh.txt"])
        #expect(!query.isEmpty)
    }
}

/// 0.4.2 #5:搜索 token 语法解析 + 新维度匹配。
struct ArchiveSearchQueryParseTests {

    private func file(_ name: String, size: Int64? = nil, crc: String = "", encrypted: Bool = false, comment: String = "") -> ArchiveItem {
        ArchiveItem(name: name, isDirectory: false, size: size, modified: nil, sizeText: "", modifiedText: "", method: "", isEncrypted: encrypted, crc: crc, comment: comment)
    }

    @Test func plainWordsStayAsSubstringText() {
        let query = ArchiveSearchQuery.parse("annual report")
        #expect(query.text == "annual report")
        #expect(query.namePatterns.isEmpty)
    }

    @Test func parsesSizeRangeAndUnits() {
        let query = ArchiveSearchQuery.parse("size:>1mb")
        #expect(query.minSize == 1_048_577)
        let upper = ArchiveSearchQuery.parse("size:<=500k")
        #expect(upper.maxSize == 512_000)
        let exact = ArchiveSearchQuery.parse("size:=1024")
        #expect(exact.minSize == 1024)
        #expect(exact.maxSize == 1024)
    }

    @Test func parsesGlobExtEncryptedCRCCommentPathRegex() {
        let query = ArchiveSearchQuery.parse("*.swift ext:pdf encrypted:true crc:a1b2 comment:草稿 path:src/ regex:^docs/")
        #expect(query.namePatterns == ["*.swift"])
        #expect(query.fileExtension == "pdf")
        #expect(query.encryptedOnly == true)
        #expect(query.crc == "A1B2")
        #expect(query.commentText == "草稿")
        #expect(query.pathText == "src/")
        #expect(query.nameRegex == "^docs/")
    }

    @Test func parsesModifiedAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let query = ArchiveSearchQuery.parse("modified:<7d", now: now)
        #expect(query.modifiedAfter == now.addingTimeInterval(-7 * 86_400))
    }

    @Test func unknownTokenFallsBackToPlainText() {
        let query = ArchiveSearchQuery.parse("foo:bar")
        #expect(query.text == "foo:bar")
    }

    @Test func encryptedFalseExcludesEncrypted() {
        let query = ArchiveSearchQuery.parse("encrypted:false")
        #expect(query.excludeEncrypted == true)
        let items = [file("a.txt", encrypted: true), file("b.txt", encrypted: false)]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["b.txt"])
    }

    @Test func globMatchesDisplayNameCaseInsensitively() {
        var query = ArchiveSearchQuery()
        query.namePatterns = ["*.SWIFT"]
        let items = [file("src/main.swift"), file("src/readme.md")]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["src/main.swift"])
    }

    @Test func globWithSlashMatchesFullPath() {
        var query = ArchiveSearchQuery()
        query.namePatterns = ["docs/*.md"]
        let items = [file("docs/a.md"), file("src/b.md")]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["docs/a.md"])
    }

    @Test func extensionAndCRCAndCommentMatch() {
        var query = ArchiveSearchQuery()
        query.fileExtension = "pdf"
        let items = [file("a.pdf"), file("b.txt")]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["a.pdf"])

        var crcQuery = ArchiveSearchQuery()
        crcQuery.crc = "A1B2C3D4"
        let crcItems = [file("x", crc: "a1b2c3d4"), file("y", crc: "FFFF0000"), file("z", crc: "")]
        #expect(ArchiveSearch.filter(crcItems, with: crcQuery).map(\.name) == ["x"])

        var commentQuery = ArchiveSearchQuery()
        commentQuery.commentText = "draft"
        let commentItems = [file("a", comment: "Final DRAFT v2"), file("b", comment: "")]
        #expect(ArchiveSearch.filter(commentItems, with: commentQuery).map(\.name) == ["a"])
    }

    @Test func regexMatchesFullPathAndInvalidRegexDegradesToSubstring() {
        var query = ArchiveSearchQuery()
        query.nameRegex = "^docs/.*\\.md$"
        let items = [file("docs/a.md"), file("docs/a.md.bak"), file("src/b.md")]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["docs/a.md"])

        var broken = ArchiveSearchQuery()
        broken.nameRegex = "[unclosed"
        let fallbackItems = [file("notes/[unclosed].txt"), file("other.txt")]
        #expect(ArchiveSearch.filter(fallbackItems, with: broken).map(\.name) == ["notes/[unclosed].txt"])
    }

    @Test func combinedTokensAreANDed() {
        let query = ArchiveSearchQuery.parse("*.log size:>1k encrypted:false")
        let items = [
            file("big.log", size: 2048, encrypted: false),
            file("small.log", size: 10, encrypted: false),
            file("big-secret.log", size: 4096, encrypted: true),
            file("big.txt", size: 4096, encrypted: false)
        ]
        #expect(ArchiveSearch.filter(items, with: query).map(\.name) == ["big.log"])
    }
}

/// 0.4.2 #6:保存的过滤器 / 最近搜索 持久化,kind: token。
struct SavedSearchFilterStoreTests {

    private func makeStore() -> SavedSearchFilterStore {
        let suite = UserDefaults(suiteName: "SavedSearchFilterStoreTests-\(UUID().uuidString)")!
        return SavedSearchFilterStore(defaults: suite)
    }

    @Test func addLoadRemoveRoundTrip() {
        let store = makeStore()
        #expect(store.load().isEmpty)
        let filter = SavedSearchFilter(name: "大加密文件", query: "size:>100mb encrypted:true")
        store.add(filter)
        #expect(store.load() == [filter])
        store.remove(id: filter.id)
        #expect(store.load().isEmpty)
    }

    @Test func recentsDedupePromoteAndCap() {
        let store = makeStore()
        store.recordRecent("a")
        store.recordRecent("b")
        store.recordRecent("a")          // 去重置顶
        #expect(store.recents() == ["a", "b"])
        store.recordRecent("   ")        // 空白不记
        #expect(store.recents() == ["a", "b"])
        for index in 0..<10 { store.recordRecent("q\(index)") }
        #expect(store.recents().count == SavedSearchFilterStore.recentsLimit)
        #expect(store.recents().first == "q9")
    }

    @Test func kindTokenParses() {
        #expect(ArchiveSearchQuery.parse("kind:files").kind == .filesOnly)
        #expect(ArchiveSearchQuery.parse("kind:folders").kind == .foldersOnly)
        #expect(ArchiveSearchQuery.parse("kind:nonsense").text == "kind:nonsense")
    }
}
