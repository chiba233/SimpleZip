//
//  BrowserGrouping.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/31.
//
//  0.2.0「Group By 多重分类」的纯逻辑：把扁平列表按某个分类键切成若干区块。
//  泛型设计 —— FileItem / ArchiveItem 通用，调用方只给一个「取分类键」闭包。
//  放在 Core 是为了能被 SwiftPM 单测覆盖；NSOutlineView（FileTable / ArchiveTable）只负责把区块画出来。
//

import Foundation

enum BrowserGrouping {
    /// 分类维度。`.none` = 不分类（平铺）。其余三种是「暂时先做这些」的维度。
    enum GroupBy: String, CaseIterable {
        /// 不分类，平铺。
        case none
        /// 按种类（typeDescription，如 PDF 文档 / 应用程序）。
        case kind
        /// 按修改时间分桶（今天 / 昨天 / 过去 7 天 / …）。
        case dateModified
        /// 按「文件夹 vs 文件」。
        case fileKind

        /// 容错解析：拿不到 / 不认识的字符串一律回落到默认 `.none`。
        static func parse(_ raw: String?) -> GroupBy {
            guard let raw, let value = GroupBy(rawValue: raw) else { return .none }
            return value
        }

        /// 可在 Settings / 菜单里给用户选的「真分组」维度（不含 `.none`）。
        static var selectableCases: [GroupBy] { allCases.filter { $0 != .none } }

        /// 是否真的要分组。`.none` 时整张表保持扁平。
        var isGrouping: Bool { self != .none }

        /// 显示用的本地化标题。
        var title: String {
            switch self {
            case .none: return L10n.text("view.groupBy.none")
            case .kind: return L10n.text("view.groupBy.kind")
            case .dateModified: return L10n.text("view.groupBy.dateModified")
            case .fileKind: return L10n.text("view.groupBy.fileKind")
            }
        }
    }

    /// 修改时间分桶。`order` 决定区块从新到旧的展示顺序。
    enum DateBucket: Int, CaseIterable {
        case today, yesterday, past7Days, past30Days, pastYear, earlier, unknown

        var title: String {
            switch self {
            case .today: return L10n.text("group.date.today")
            case .yesterday: return L10n.text("group.date.yesterday")
            case .past7Days: return L10n.text("group.date.past7Days")
            case .past30Days: return L10n.text("group.date.past30Days")
            case .pastYear: return L10n.text("group.date.pastYear")
            case .earlier: return L10n.text("group.date.earlier")
            case .unknown: return L10n.text("group.date.unknown")
            }
        }
    }

    /// 把一个日期归到分桶。`now` 显式传入以便纯函数测试。
    static func dateBucket(for date: Date?, now: Date, calendar: Calendar = .current) -> DateBucket {
        guard let date else { return .unknown }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if days < 0 { return .today }        // 未来时间 → 当今天处理
        if days <= 7 { return .past7Days }
        if days <= 30 { return .past30Days }
        if days <= 365 { return .pastYear }
        return .earlier
    }

    /// 分组范围：全局统一，还是每个文件夹各记各的（按文件夹时用右键「设定此文件夹的分组」覆盖）。
    enum GroupingScope: String, CaseIterable {
        case global
        case perFolder

        static func parse(_ raw: String?) -> GroupingScope {
            guard let raw, let value = GroupingScope(rawValue: raw) else { return .global }
            return value
        }

        var title: String {
            switch self {
            case .global: return L10n.text("settings.grouping.scope.global")
            case .perFolder: return L10n.text("settings.grouping.scope.perFolder")
            }
        }
    }

    /// Group By ≠ None 且开启「显示隐藏文件」时，隐藏文件怎么跟分类组共存。用户在 Settings 里选。
    enum HiddenWithGrouping: String, CaseIterable {
        /// 隐藏文件按同一分类键融进各组（按种类时，隐藏图片进「图片」组）。默认。
        case foldIntoGroups
        /// 隐藏文件始终单列一个「隐藏文件」组，跟分类组并列。
        case separateGroup

        static func parse(_ raw: String?) -> HiddenWithGrouping {
            guard let raw, let value = HiddenWithGrouping(rawValue: raw) else { return .foldIntoGroups }
            return value
        }

        var title: String {
            switch self {
            case .foldIntoGroups: return L10n.text("settings.hiddenWithGrouping.foldIntoGroups")
            case .separateGroup: return L10n.text("settings.hiddenWithGrouping.separateGroup")
            }
        }
    }

    /// 一个分类区块：标题 + 组内条目（组内保持入参顺序，即调用方当前的排序）。
    struct Section<Item> {
        let title: String
        let items: [Item]
    }

    /// 按 `keyOf` 提取的分类键把 `items` 切成区块。
    /// - 组内顺序：保持入参顺序（调用方已按当前排序排好，分组不打乱组内次序）；
    /// - 区块顺序：按标题做本地化自然排序（稳定、可预期）。
    static func group<Item>(_ items: [Item], by keyOf: (Item) -> String) -> [Section<Item>] {
        var firstSeenOrder: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = keyOf(item)
            if buckets[key] == nil {
                firstSeenOrder.append(key)
            }
            buckets[key, default: []].append(item)
        }
        return firstSeenOrder
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Section(title: $0, items: buckets[$0] ?? []) }
    }

    /// 按某个分类维度把条目切成区块，区块顺序按维度语义排（种类/文件vs文件夹按标题；时间按桶从新到旧）。
    /// `now` 显式传入以便纯函数测试（日期分桶用）。`.none` 返回空（调用方此时应保持扁平、不调本方法）。
    static func group<Item: GroupableItem>(
        _ items: [Item],
        by groupBy: GroupBy,
        now: Date,
        calendar: Calendar = .current
    ) -> [Section<Item>] {
        switch groupBy {
        case .none:
            return []
        case .kind:
            // 按 typeDescription，区块标题本地化自然排序。
            return group(items, by: { $0.typeDescription })
        case .fileKind:
            // 文件夹在前，文件在后。
            let folders = items.filter(\.isDirectory)
            let files = items.filter { !$0.isDirectory }
            var sections: [Section<Item>] = []
            if !folders.isEmpty { sections.append(Section(title: L10n.text("group.fileKind.folders"), items: folders)) }
            if !files.isEmpty { sections.append(Section(title: L10n.text("group.fileKind.files"), items: files)) }
            return sections
        case .dateModified:
            // 按修改时间分桶，区块从新到旧（DateBucket.allCases 的顺序）。
            var buckets: [DateBucket: [Item]] = [:]
            for item in items {
                buckets[dateBucket(for: item.modified, now: now, calendar: calendar), default: []].append(item)
            }
            return DateBucket.allCases.compactMap { bucket in
                guard let bucketItems = buckets[bucket], !bucketItems.isEmpty else { return nil }
                return Section(title: bucket.title, items: bucketItems)
            }
        }
    }
}

/// 能被 Group By 分类的条目所需的最小属性。FileItem / ArchiveItem 都已满足。
protocol GroupableItem {
    var typeDescription: String { get }
    var isDirectory: Bool { get }
    var modified: Date? { get }
}

extension FileItem: GroupableItem {}
extension ArchiveItem: GroupableItem {}
