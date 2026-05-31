import Foundation
import Testing
@testable import SimpleZipCore

/// 覆盖 0.2.0 Group By 的 Core 纯逻辑：泛型分组 + 枚举解析。
struct BrowserGroupingTests {
    /// 用一个轻量结构体当被分组的 Item，验证 group() 的泛型行为，不绑 FileItem / ArchiveItem。
    private struct Row {
        let name: String
        let kind: String
    }

    @Test
    func groupBucketsByKeyAndSortsSectionsByTitle() {
        let rows = [
            Row(name: "b.txt", kind: "Text"),
            Row(name: "a.png", kind: "Image"),
            Row(name: "c.txt", kind: "Text"),
            Row(name: "d.png", kind: "Image")
        ]
        let sections = BrowserGrouping.group(rows, by: \.kind)
        // section 按标题本地化升序：Image < Text。
        #expect(sections.map(\.title) == ["Image", "Text"])
        // 组内保持入参顺序（稳定）。
        #expect(sections[0].items.map(\.name) == ["a.png", "d.png"])
        #expect(sections[1].items.map(\.name) == ["b.txt", "c.txt"])
    }

    @Test
    func groupEmptyInputYieldsNoSections() {
        let sections = BrowserGrouping.group([Row]()) { $0.kind }
        #expect(sections.isEmpty)
    }

    @Test
    func groupSingleKindYieldsOneSection() {
        let rows = [Row(name: "a", kind: "K"), Row(name: "b", kind: "K")]
        let sections = BrowserGrouping.group(rows, by: \.kind)
        #expect(sections.count == 1)
        #expect(sections[0].title == "K")
        #expect(sections[0].items.count == 2)
    }

    @Test
    func groupByParseAndIsGrouping() {
        #expect(BrowserGrouping.GroupBy.parse(nil) == .none)
        #expect(BrowserGrouping.GroupBy.parse("garbage") == .none)
        #expect(BrowserGrouping.GroupBy.parse("kind") == .kind)
        #expect(BrowserGrouping.GroupBy.none.isGrouping == false)
        #expect(BrowserGrouping.GroupBy.kind.isGrouping == true)
    }

    @Test
    func hiddenWithGroupingParseFallsBackToFold() {
        #expect(BrowserGrouping.HiddenWithGrouping.parse(nil) == .foldIntoGroups)
        #expect(BrowserGrouping.HiddenWithGrouping.parse("garbage") == .foldIntoGroups)
        #expect(BrowserGrouping.HiddenWithGrouping.parse("separateGroup") == .separateGroup)
    }
}
