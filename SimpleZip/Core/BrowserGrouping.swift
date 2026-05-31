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
    /// 分类维度。v1 只有「不分类」和「按种类」；日期 / 大小等分桶维度以后再加。
    enum GroupBy: String, CaseIterable {
        /// 不分类，平铺（默认）。
        case none
        /// 按种类（FileItem / ArchiveItem 的 typeDescription）分组。
        case kind

        /// 容错解析：拿不到 / 不认识的字符串一律回落到默认 `.none`。
        static func parse(_ raw: String?) -> GroupBy {
            guard let raw, let value = GroupBy(rawValue: raw) else { return .none }
            return value
        }

        /// 是否真的要分组。`.none` 时整张表保持扁平。
        var isGrouping: Bool { self != .none }

        /// View 菜单显示用的本地化标题。
        var title: String {
            switch self {
            case .none: return L10n.text("view.groupBy.none")
            case .kind: return L10n.text("view.groupBy.kind")
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
}
