//
//  ArchiveSearch.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/06.
//
//  #113 归档内搜索 —— **纯 Core 过滤谓词**：对已列出的 `[ArchiveItem]` 按 文件名/路径、类型、
//  大小、加密状态 过滤。无后端、无 UI、无副作用，完全可单测。
//  搜索框 / 结果展示的 UI 接入另行处理，不在此文件。
//

import Foundation

/// 搜索条件。所有字段都「未设 = 不约束」，组合时取交集（AND）。空条件匹配全部。
struct ArchiveSearchQuery: Equatable {
    /// 大小写不敏感的子串匹配文本。空串 = 不按文本过滤。
    var text: String = ""
    /// 文本匹配范围：只看当前层级名（`displayName`）还是完整条目路径（`name`）。
    var scope: Scope = .name
    /// 限定条目类型。
    var kind: Kind = .any
    /// 仅显示加密条目。
    var encryptedOnly: Bool = false
    /// 原始大小下限（字节，含）。nil = 不限。目录（size 为 nil）在设了大小约束时一律不匹配。
    var minSize: Int64?
    /// 原始大小上限（字节，含）。nil = 不限。
    var maxSize: Int64?

    enum Scope: String, CaseIterable, Hashable { case name, fullPath }
    enum Kind: String, CaseIterable, Hashable { case any, filesOnly, foldersOnly }

    /// 没有任何有效约束 —— 调用方可据此跳过过滤、直接展示全部。
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && kind == .any
            && !encryptedOnly
            && minSize == nil
            && maxSize == nil
    }
}

enum ArchiveSearch {

    /// 过滤：返回满足全部条件的条目（保持输入顺序）。空条件返回原数组（拷贝）。
    static func filter(_ items: [ArchiveItem], with query: ArchiveSearchQuery) -> [ArchiveItem] {
        guard !query.isEmpty else { return items }
        return items.filter { matches($0, query) }
    }

    /// 单条目是否满足条件。各维度 AND。
    static func matches(_ item: ArchiveItem, _ query: ArchiveSearchQuery) -> Bool {
        switch query.kind {
        case .any: break
        case .filesOnly: if item.isDirectory { return false }
        case .foldersOnly: if !item.isDirectory { return false }
        }

        if query.encryptedOnly, !item.isEncrypted { return false }

        if query.minSize != nil || query.maxSize != nil {
            // 大小约束只对有大小的条目（文件）有意义；目录 / 无大小条目在设了约束时排除。
            guard let size = item.size else { return false }
            if let minSize = query.minSize, size < minSize { return false }
            if let maxSize = query.maxSize, size > maxSize { return false }
        }

        let needle = query.text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let haystack = query.scope == .name ? item.displayName : item.name
            if !haystack.localizedCaseInsensitiveContains(needle) { return false }
        }

        return true
    }
}
