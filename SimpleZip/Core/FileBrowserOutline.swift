//
//  FileBrowserOutline.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/31.
//
//  0.2.0「隐藏文件折叠分组」的纯逻辑：把扁平的 [FileItem] 拆成「顶层可见叶子 + 一个隐藏分组」，
//  以及决定某个文件夹的隐藏分组初始是否展开。放在 Core 是为了能被 SwiftPM 单测覆盖 ——
//  NSOutlineView 的 UI 交互（FileTable.swift）只负责把这里的结论画出来。
//

import Foundation

enum FileBrowserOutline {
    /// 隐藏分组的折叠记忆策略。用户在 Settings → 浏览 里选，默认 `.alwaysCollapsed`。
    enum CollapseMode: String, CaseIterable {
        /// 每次进文件夹都重新折叠（零持久化，最可预期）。
        case alwaysCollapsed
        /// 记住每个文件夹上次的展开/折叠状态。
        case rememberPerFolder
        /// 全局记一个：展开过就一直展开，直到再折叠。
        case globalSticky

        /// 容错解析：拿不到 / 不认识的字符串一律回落到默认 `.alwaysCollapsed`。
        static func parse(_ raw: String?) -> CollapseMode {
            guard let raw, let mode = CollapseMode(rawValue: raw) else { return .alwaysCollapsed }
            return mode
        }

        /// Settings 里 picker 显示用的本地化标题。
        var title: String {
            switch self {
            case .alwaysCollapsed: return L10n.text("settings.hiddenGroupCollapse.alwaysCollapsed")
            case .rememberPerFolder: return L10n.text("settings.hiddenGroupCollapse.rememberPerFolder")
            case .globalSticky: return L10n.text("settings.hiddenGroupCollapse.globalSticky")
            }
        }
    }

    /// 把完整的 fileItems（已排序）拆成可见叶子 + 隐藏条目两段，保持各自原有顺序。
    /// 不改变排序 —— 调用方先排好序，这里只按 `isHidden` 分流，让两段各自维持稳定次序。
    static func split(_ items: [FileItem]) -> (visible: [FileItem], hidden: [FileItem]) {
        var visible: [FileItem] = []
        var hidden: [FileItem] = []
        visible.reserveCapacity(items.count)
        for item in items {
            if item.isHidden {
                hidden.append(item)
            } else {
                visible.append(item)
            }
        }
        return (visible, hidden)
    }

    /// 决定某文件夹的隐藏分组初始展开状态。
    /// - `.alwaysCollapsed`：恒折叠；
    /// - `.rememberPerFolder`：该 folderKey 出现在已展开集合里才展开；
    /// - `.globalSticky`：跟随全局开关。
    static func initialExpanded(
        mode: CollapseMode,
        folderKey: String,
        perFolderExpanded: Set<String>,
        globalExpanded: Bool
    ) -> Bool {
        switch mode {
        case .alwaysCollapsed:
            return false
        case .rememberPerFolder:
            return perFolderExpanded.contains(folderKey)
        case .globalSticky:
            return globalExpanded
        }
    }

    /// 用户在某文件夹切换展开状态后，算出新的「已展开文件夹」集合（只对 `.rememberPerFolder` 有意义）。
    /// 其它模式返回原集合不动，避免无谓写入。
    static func updatedPerFolderExpanded(
        _ current: Set<String>,
        folderKey: String,
        expanded: Bool,
        mode: CollapseMode
    ) -> Set<String> {
        guard mode == .rememberPerFolder else { return current }
        var next = current
        if expanded {
            next.insert(folderKey)
        } else {
            next.remove(folderKey)
        }
        return next
    }
}
