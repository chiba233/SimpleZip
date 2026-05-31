import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 0.2.0「隐藏文件折叠分组」的 Core 纯逻辑：partition + 折叠记忆决策。
struct FileBrowserOutlineTests {
    private func item(_ name: String, hidden: Bool) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            displayName: name,
            isDirectory: false,
            isSymbolicLink: false,
            isHidden: hidden,
            size: 0,
            modified: nil,
            created: nil,
            dateAdded: nil,
            lastOpened: nil,
            typeDescription: "file",
            applicationName: "app"
        )
    }

    @Test
    func splitPartitionsByHiddenPreservingOrder() {
        let items = [
            item("a.txt", hidden: false),
            item(".git", hidden: true),
            item("b.txt", hidden: false),
            item(".DS_Store", hidden: true)
        ]
        let result = FileBrowserOutline.split(items)
        #expect(result.visible.map(\.name) == ["a.txt", "b.txt"])
        #expect(result.hidden.map(\.name) == [".git", ".DS_Store"])
    }

    @Test
    func splitWithNoHiddenLeavesHiddenEmpty() {
        let items = [item("a", hidden: false), item("b", hidden: false)]
        let result = FileBrowserOutline.split(items)
        #expect(result.visible.count == 2)
        #expect(result.hidden.isEmpty)
    }

    @Test
    func initialExpandedAlwaysCollapsedIgnoresState() {
        let expanded = FileBrowserOutline.initialExpanded(
            mode: .alwaysCollapsed,
            folderKey: "/Users/me",
            perFolderExpanded: ["/Users/me"],
            globalExpanded: true
        )
        #expect(expanded == false)
    }

    @Test
    func initialExpandedRememberPerFolderChecksMembership() {
        #expect(FileBrowserOutline.initialExpanded(
            mode: .rememberPerFolder,
            folderKey: "/Users/me",
            perFolderExpanded: ["/Users/me"],
            globalExpanded: false
        ) == true)
        #expect(FileBrowserOutline.initialExpanded(
            mode: .rememberPerFolder,
            folderKey: "/Users/other",
            perFolderExpanded: ["/Users/me"],
            globalExpanded: false
        ) == false)
    }

    @Test
    func initialExpandedGlobalStickyFollowsGlobalFlag() {
        #expect(FileBrowserOutline.initialExpanded(
            mode: .globalSticky, folderKey: "/x", perFolderExpanded: [], globalExpanded: true
        ) == true)
        #expect(FileBrowserOutline.initialExpanded(
            mode: .globalSticky, folderKey: "/x", perFolderExpanded: [], globalExpanded: false
        ) == false)
    }

    @Test
    func updatedPerFolderExpandedOnlyMutatesInRememberMode() {
        // remember 模式：插入 / 删除生效。
        var set = FileBrowserOutline.updatedPerFolderExpanded([], folderKey: "/a", expanded: true, mode: .rememberPerFolder)
        #expect(set == ["/a"])
        set = FileBrowserOutline.updatedPerFolderExpanded(set, folderKey: "/a", expanded: false, mode: .rememberPerFolder)
        #expect(set.isEmpty)

        // 其它模式：原样返回，不写入。
        let unchanged = FileBrowserOutline.updatedPerFolderExpanded(["/keep"], folderKey: "/a", expanded: true, mode: .globalSticky)
        #expect(unchanged == ["/keep"])
    }

    @Test
    func collapseModeParseFallsBackToAlwaysCollapsed() {
        #expect(FileBrowserOutline.CollapseMode.parse(nil) == .alwaysCollapsed)
        #expect(FileBrowserOutline.CollapseMode.parse("garbage") == .alwaysCollapsed)
        #expect(FileBrowserOutline.CollapseMode.parse("rememberPerFolder") == .rememberPerFolder)
        #expect(FileBrowserOutline.CollapseMode.parse("globalSticky") == .globalSticky)
        #expect(FileBrowserOutline.CollapseMode.parse("inline") == .inline)
    }

    @Test
    func groupsHiddenFilesIsFalseOnlyForInline() {
        #expect(FileBrowserOutline.CollapseMode.alwaysCollapsed.groupsHiddenFiles == true)
        #expect(FileBrowserOutline.CollapseMode.rememberPerFolder.groupsHiddenFiles == true)
        #expect(FileBrowserOutline.CollapseMode.globalSticky.groupsHiddenFiles == true)
        #expect(FileBrowserOutline.CollapseMode.inline.groupsHiddenFiles == false)
    }

    @Test
    func initialExpandedInlineIsFalse() {
        #expect(FileBrowserOutline.initialExpanded(
            mode: .inline, folderKey: "/x", perFolderExpanded: ["/x"], globalExpanded: true
        ) == false)
    }
}
