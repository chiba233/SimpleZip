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

    // MARK: - 维度感知分组（种类 / 时间 / 文件vs文件夹）

    private struct G: GroupableItem {
        var typeDescription: String
        var isDirectory: Bool
        var modified: Date?
    }

    private func fixedNow() -> (Calendar, Date) {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        return (cal, now)
    }

    @Test
    func dateBucketClassifiesRelativeToNow() {
        let (cal, now) = fixedNow()
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        #expect(BrowserGrouping.dateBucket(for: now, now: now, calendar: cal) == .today)
        #expect(BrowserGrouping.dateBucket(for: daysAgo(1), now: now, calendar: cal) == .yesterday)
        #expect(BrowserGrouping.dateBucket(for: daysAgo(5), now: now, calendar: cal) == .past7Days)
        #expect(BrowserGrouping.dateBucket(for: daysAgo(20), now: now, calendar: cal) == .past30Days)
        #expect(BrowserGrouping.dateBucket(for: daysAgo(100), now: now, calendar: cal) == .pastYear)
        #expect(BrowserGrouping.dateBucket(for: daysAgo(400), now: now, calendar: cal) == .earlier)
        #expect(BrowserGrouping.dateBucket(for: nil, now: now, calendar: cal) == .unknown)
    }

    @Test
    func groupByDateModifiedOrdersNewestBucketFirst() {
        let (cal, now) = fixedNow()
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        let items = [
            G(typeDescription: "x", isDirectory: false, modified: daysAgo(400)),
            G(typeDescription: "x", isDirectory: false, modified: now),
            G(typeDescription: "x", isDirectory: false, modified: daysAgo(20))
        ]
        let sections = BrowserGrouping.group(items, by: .dateModified, now: now, calendar: cal)
        #expect(sections.map(\.title) == [
            BrowserGrouping.DateBucket.today.title,
            BrowserGrouping.DateBucket.past30Days.title,
            BrowserGrouping.DateBucket.earlier.title
        ])
    }

    @Test
    func groupByFileKindPutsFoldersBeforeFiles() {
        let items = [
            G(typeDescription: "a", isDirectory: false, modified: nil),
            G(typeDescription: "b", isDirectory: true, modified: nil)
        ]
        let sections = BrowserGrouping.group(items, by: .fileKind, now: Date())
        #expect(sections.count == 2)
        #expect(sections[0].items.allSatisfy { $0.isDirectory })
        #expect(sections[1].items.allSatisfy { !$0.isDirectory })
    }

    @Test
    func groupByNoneReturnsEmpty() {
        let items = [G(typeDescription: "a", isDirectory: false, modified: nil)]
        #expect(BrowserGrouping.group(items, by: .none, now: Date()).isEmpty)
    }

    @Test
    func selectableCasesExcludesNone() {
        #expect(!BrowserGrouping.GroupBy.selectableCases.contains(.none))
        #expect(BrowserGrouping.GroupBy.selectableCases.contains(.kind))
        #expect(BrowserGrouping.GroupBy.selectableCases.contains(.dateModified))
        #expect(BrowserGrouping.GroupBy.selectableCases.contains(.fileKind))
    }
}
