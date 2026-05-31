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
    /// 隐藏文件的展示方式。用户在 Settings → 浏览 里选，默认 `.alwaysCollapsed`。
    /// `.inline` 是 opt-out —— 回到 0.2.0 之前「隐藏文件平铺混排」的老行为，给不想要分组的用户留退路；
    /// 其余三种都把隐藏文件收进一个可折叠分组，区别只在折叠记忆策略。
    enum CollapseMode: String, CaseIterable {
        /// 每次进文件夹都重新折叠（零持久化，最可预期）。
        case alwaysCollapsed
        /// 记住每个文件夹上次的展开/折叠状态。
        case rememberPerFolder
        /// 全局记一个：展开过就一直展开，直到再折叠。
        case globalSticky
        /// 不分组，隐藏文件平铺混在普通文件里（0.2.0 之前的行为）。
        case inline

        /// 容错解析：拿不到 / 不认识的字符串一律回落到默认 `.alwaysCollapsed`。
        static func parse(_ raw: String?) -> CollapseMode {
            guard let raw, let mode = CollapseMode(rawValue: raw) else { return .alwaysCollapsed }
            return mode
        }

        /// 是否把隐藏文件收进分组。`.inline` 时为 false（平铺），其余为 true。
        var groupsHiddenFiles: Bool { self != .inline }

        /// Settings 里 picker 显示用的本地化标题。
        var title: String {
            switch self {
            case .alwaysCollapsed: return L10n.text("settings.hiddenGroupCollapse.alwaysCollapsed")
            case .rememberPerFolder: return L10n.text("settings.hiddenGroupCollapse.rememberPerFolder")
            case .globalSticky: return L10n.text("settings.hiddenGroupCollapse.globalSticky")
            case .inline: return L10n.text("settings.hiddenGroupCollapse.inline")
            }
        }
    }

    /// 「什么算隐藏文件」的判定方式。用户在 Settings → 浏览 里选。
    /// macOS 既有 Unix 的 dotfile 约定，又有自己的 `UF_HIDDEN` chflags 标志（如 /etc、~/Library），
    /// 两种语义并存，所以做成可选。默认 `.dotfilesOnly`（Unix 习惯，最直观）。
    enum HiddenDetectionMode: String, CaseIterable {
        /// 仅名字以 `.` 开头的 dotfile 算隐藏。
        case dotfilesOnly
        /// dotfile + 带 macOS `UF_HIDDEN` 标志的项都算隐藏（含 /etc、~/Library 等符号链接 / 目录）。
        case macOSHidden

        static func parse(_ raw: String?) -> HiddenDetectionMode {
            guard let raw, let value = HiddenDetectionMode(rawValue: raw) else { return .dotfilesOnly }
            return value
        }

        /// 是否把 macOS 隐藏标志也算进来（`.dotfilesOnly` 为 false）。
        var includesMacOSHiddenFlag: Bool { self == .macOSHidden }

        var title: String {
            switch self {
            case .dotfilesOnly: return L10n.text("settings.hiddenDetection.dotfilesOnly")
            case .macOSHidden: return L10n.text("settings.hiddenDetection.macOSHidden")
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
        case .alwaysCollapsed, .inline:
            // `.inline` 不分组，没有 group 可展开 —— 返回什么都无所谓，给 false。
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
