//
//  ArchiveDiff.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/06.
//
//  #111 Archive Diff —— **纯 Core 比对引擎**：给两个已列好的 `[ArchiveItem]`（左=旧 / 右=新），
//  按归一化后的条目路径配对，算出 新增 / 删除 / 修改 / 未变。无后端、无 UI、无副作用，
//  完全可单测。UI 侧（选两个包 → 列出 → 喂进来 → 展示结果）另行接入，不在此文件。
//

import Foundation

/// 某条目「改了什么」。一条修改可能同时命中多项（比如内容变了 → size + crc 都变）。
enum ArchiveDiffField: String, CaseIterable, Hashable {
    case type        // 文件 ↔ 文件夹
    case size        // 原始大小
    case crc         // CRC（仅文件、两边都有 CRC 时才比）
    case modified    // 修改时间
    case encryption  // 是否加密
    case comment     // 条目注释（zip per-entry Comment；0.4.2 起参与比对）
}

/// 同一路径在两个包里都存在、但有差异的一条修改。`before` / `after` 分别是左 / 右两侧条目。
struct ArchiveEntryChange: Hashable {
    let path: String
    let before: ArchiveItem
    let after: ArchiveItem
    let fields: Set<ArchiveDiffField>
}

/// 两个压缩包的比对结果。各列表按归一化路径升序，保证确定性（方便测试 + 稳定展示）。
struct ArchiveDiffResult: Hashable {
    /// 只在右（新）包里 —— 新增。
    let added: [ArchiveItem]
    /// 只在左（旧）包里 —— 删除。
    let removed: [ArchiveItem]
    /// 两边都有但有差异 —— 修改。
    let changed: [ArchiveEntryChange]
    /// 两边都有且完全一致 —— 未变（右侧条目）。UI 通常折叠或忽略，保留以便统计与导出。
    let unchanged: [ArchiveItem]

    var hasDifferences: Bool { !added.isEmpty || !removed.isEmpty || !changed.isEmpty }
}

// 纯比对逻辑，可从任意 actor 调用 —— app target 默认 MainActor 隔离下，
// 不标 nonisolated 会让 `sorted(by:)`/`filter` 传入这些静态方法时报「main actor-isolated ... in nonisolated context」。
enum ArchiveDiff {

    /// 比对两个已列出的条目集合。
    ///
    /// 配对键 = 归一化路径（去掉前导 `./`、去掉首尾 `/`），所以 `dir/` 与 `dir` 视为同一路径
    /// （类型差异由 `.type` 字段单独标出）。同一侧若出现重复路径（理论上不该发生），后者覆盖前者。
    nonisolated static func compare(left: [ArchiveItem], right: [ArchiveItem]) -> ArchiveDiffResult {
        let leftByPath = indexByPath(left)
        let rightByPath = indexByPath(right)

        var added: [ArchiveItem] = []
        var removed: [ArchiveItem] = []
        var changed: [ArchiveEntryChange] = []
        var unchanged: [ArchiveItem] = []

        // 右侧独有 = 新增；两侧都有 = 比字段。
        for (path, rightItem) in rightByPath {
            guard let leftItem = leftByPath[path] else {
                added.append(rightItem)
                continue
            }
            let fields = changedFields(before: leftItem, after: rightItem)
            if fields.isEmpty {
                unchanged.append(rightItem)
            } else {
                changed.append(ArchiveEntryChange(path: path, before: leftItem, after: rightItem, fields: fields))
            }
        }
        // 左侧独有 = 删除。用 String key 判存在（`keys.contains`），不要 `rightByPath[path] == nil`——
        // 后者会用到 ArchiveItem 的 Equatable，而 app target 默认 MainActor 隔离下该 conformance 是 main-actor 的，
        // 在本 nonisolated 方法里用会触发 Swift 6「main actor-isolated conformance ... in nonisolated context」。
        for (path, leftItem) in leftByPath where !rightByPath.keys.contains(path) {
            removed.append(leftItem)
        }

        return ArchiveDiffResult(
            added: added.sorted(by: byNormalizedName),
            removed: removed.sorted(by: byNormalizedName),
            changed: changed.sorted { normalizedPath($0.path) < normalizedPath($1.path) },
            unchanged: unchanged.sorted(by: byNormalizedName)
        )
    }

    /// 归一化条目路径：去前导 `./`、去首尾 `/`。供配对与展示用。
    nonisolated static func normalizedPath(_ name: String) -> String {
        var path = name
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - 内部

    nonisolated private static func indexByPath(_ items: [ArchiveItem]) -> [String: ArchiveItem] {
        var map: [String: ArchiveItem] = [:]
        for item in items {
            let key = normalizedPath(item.name)
            guard !key.isEmpty else { continue } // 根条目（空路径）跳过，避免把「整个包」当成一条目。
            map[key] = item
        }
        return map
    }

    /// 算出 before→after 改了哪些字段。空集合 = 未变。
    nonisolated private static func changedFields(before: ArchiveItem, after: ArchiveItem) -> Set<ArchiveDiffField> {
        var fields: Set<ArchiveDiffField> = []
        if before.isDirectory != after.isDirectory { fields.insert(.type) }
        if before.isEncrypted != after.isEncrypted { fields.insert(.encryption) }
        // 注释目录也能有（zip 允许），放在目录早退之前。
        if before.comment != after.comment { fields.insert(.comment) }

        // 目录没有有意义的 size/crc/mtime 对比（很多后端对目录留空），只比类型/加密。
        guard !before.isDirectory, !after.isDirectory else { return fields }

        if before.size != after.size { fields.insert(.size) }

        // CRC 只在两边都给了非空值时才比 —— 某些格式 / 条目没有 CRC，空值不该误判为「改了」。
        let beforeCRC = normalizedCRC(before.crc)
        let afterCRC = normalizedCRC(after.crc)
        if !beforeCRC.isEmpty, !afterCRC.isEmpty, beforeCRC != afterCRC { fields.insert(.crc) }

        if before.modified != after.modified { fields.insert(.modified) }
        return fields
    }

    /// CRC 归一化：去空白、统一大写、丢掉无意义占位（空 / 全 0）。
    nonisolated private static func normalizedCRC(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.isEmpty { return "" }
        if trimmed.allSatisfy({ $0 == "0" }) { return "" }
        return trimmed
    }

    nonisolated private static func byNormalizedName(_ a: ArchiveItem, _ b: ArchiveItem) -> Bool {
        normalizedPath(a.name) < normalizedPath(b.name)
    }
}
