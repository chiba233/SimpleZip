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

    nonisolated var hasDifferences: Bool { !added.isEmpty || !removed.isEmpty || !changed.isEmpty }
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

        // 修改时间给 2 秒容差:zip 的 DOS 时间戳只有 2 秒分辨率,文件夹 vs 归档(0.4.2 #25)
        // 不容差会把每个文件都误标「已修改」。两侧都缺时间不比。
        if let beforeModified = before.modified, let afterModified = after.modified {
            if abs(beforeModified.timeIntervalSince(afterModified)) > 2 { fields.insert(.modified) }
        } else if (before.modified == nil) != (after.modified == nil) {
            // 单侧缺时间(文件夹快照 vs 不记时间的格式)→ 不算差异,避免系统性误报。
        }
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

// MARK: - 导出（0.4.2）

/// 比较结果的**机器可读**导出：JSON / CSV。字段名固定英文（交换格式不跟 UI 语言走），
/// 输出确定性（条目已排序 + JSON sortedKeys + ISO8601 时间）—— 同一结果导两次逐字节一致，可单测。
/// 默认**只导差异项**（added/removed/changed），unchanged 只进 summary 计数 —— 用户要的是差异报告。
/// 人看的 Markdown 报告在 app 侧（`ArchiveDiffReport`，跟着 UI 语言）。
enum ArchiveDiffExport {

    /// JSON 里的一条条目快照。`nonisolated`:纯数据,Codable conformance 须可在后台编码。
    private nonisolated struct EntrySnapshot: Codable {
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let crc: String?
        let modified: Date?
        let encrypted: Bool
    }

    private nonisolated struct ChangeRecord: Codable {
        let path: String
        let fields: [String]
        let before: EntrySnapshot
        let after: EntrySnapshot
    }

    private nonisolated struct Report: Codable {
        let left: String
        let right: String
        let summary: [String: Int]
        let added: [EntrySnapshot]
        let removed: [EntrySnapshot]
        let changed: [ChangeRecord]
    }

    nonisolated private static func snapshot(_ item: ArchiveItem) -> EntrySnapshot {
        EntrySnapshot(
            path: ArchiveDiff.normalizedPath(item.name),
            isDirectory: item.isDirectory,
            size: item.isDirectory ? nil : item.size,
            crc: item.crc.isEmpty ? nil : item.crc,
            modified: item.modified,
            encrypted: item.isEncrypted
        )
    }

    /// 字段集 → 稳定排序的英文名数组（按 CaseIterable 声明序，保证输出确定性）。
    nonisolated private static func fieldNames(_ fields: Set<ArchiveDiffField>) -> [String] {
        ArchiveDiffField.allCases.filter(fields.contains).map(\.rawValue)
    }

    nonisolated static func json(result: ArchiveDiffResult, leftName: String, rightName: String) throws -> String {
        let report = Report(
            left: leftName,
            right: rightName,
            summary: [
                "added": result.added.count,
                "removed": result.removed.count,
                "changed": result.changed.count,
                "unchanged": result.unchanged.count
            ],
            added: result.added.map(snapshot),
            removed: result.removed.map(snapshot),
            changed: result.changed.map { change in
                ChangeRecord(
                    path: change.path,
                    fields: fieldNames(change.fields),
                    before: snapshot(change.before),
                    after: snapshot(change.after)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    /// CSV：一行一条差异。`status` = added / removed / changed；before/after 成对列，
    /// added 只填 after 侧、removed 只填 before 侧。RFC4180 转义（引号包裹 + 内部引号翻倍）。
    nonisolated static func csv(result: ArchiveDiffResult, leftName: String, rightName: String) -> String {
        var lines = [
            "status,path,is_directory,fields,size_before,size_after,crc_before,crc_after,modified_before,modified_after,encrypted_before,encrypted_after"
        ]
        let iso = ISO8601DateFormatter()
        func field(_ raw: String) -> String {
            if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
                return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return raw
        }
        func row(status: String, path: String, isDirectory: Bool, fields: String,
                 before: ArchiveItem?, after: ArchiveItem?) -> String {
            // 列值先落显式类型的局部变量再拼数组 —— 12 个混合 optional 链的字面量会让
            // CI 的稳定版编译器类型检查超时（"unable to type-check in reasonable time"）。
            let sizeBefore: String = before?.size.map(String.init) ?? ""
            let sizeAfter: String = after?.size.map(String.init) ?? ""
            let crcBefore: String = field(before?.crc ?? "")
            let crcAfter: String = field(after?.crc ?? "")
            let modifiedBefore: String = before?.modified.map(iso.string(from:)) ?? ""
            let modifiedAfter: String = after?.modified.map(iso.string(from:)) ?? ""
            let encryptedBefore: String = before.map { $0.isEncrypted ? "true" : "false" } ?? ""
            let encryptedAfter: String = after.map { $0.isEncrypted ? "true" : "false" } ?? ""
            let columns: [String] = [
                status,
                field(path),
                isDirectory ? "true" : "false",
                field(fields),
                sizeBefore,
                sizeAfter,
                crcBefore,
                crcAfter,
                modifiedBefore,
                modifiedAfter,
                encryptedBefore,
                encryptedAfter
            ]
            return columns.joined(separator: ",")
        }
        for item in result.removed {
            lines.append(row(status: "removed", path: ArchiveDiff.normalizedPath(item.name),
                             isDirectory: item.isDirectory, fields: "", before: item, after: nil))
        }
        for item in result.added {
            lines.append(row(status: "added", path: ArchiveDiff.normalizedPath(item.name),
                             isDirectory: item.isDirectory, fields: "", before: nil, after: item))
        }
        for change in result.changed {
            lines.append(row(status: "changed", path: change.path,
                             isDirectory: change.after.isDirectory,
                             fields: fieldNames(change.fields).joined(separator: "+"),
                             before: change.before, after: change.after))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - 垃圾过滤视图（0.4.2 #16）

extension ArchiveDiffResult {
    /// 过滤掉 macOS / Windows 元数据垃圾（.DS_Store / __MACOSX / ._* / Thumbs.db / desktop.ini）后的
    /// 结果视图 —— 比较两个包时这些噪音常淹没真实差异。纯过滤，不改原结果。
    func filteringJunk() -> ArchiveDiffResult {
        ArchiveDiffResult(
            added: added.filter { !ArchiveJunkFiles.isJunkPath($0.name) },
            removed: removed.filter { !ArchiveJunkFiles.isJunkPath($0.name) },
            changed: changed.filter { !ArchiveJunkFiles.isJunkPath($0.path) },
            unchanged: unchanged.filter { !ArchiveJunkFiles.isJunkPath($0.name) }
        )
    }
}

// MARK: - 重复文件检测（0.4.2 #24）

/// 一组内容重复的条目（按 大小 + CRC 配组）。`paths` ≥ 2、升序。
nonisolated struct DuplicateFileGroup: Identifiable, Equatable {
    let size: Int64
    let crc: String
    let paths: [String]
    var id: String { "\(size)-\(crc)" }

    /// 这组里「多出来」的浪费字节（保留一份，其余都算浪费）。
    var wastedBytes: Int64 { Int64(paths.count - 1) * size }
}

enum ArchiveDuplicates {

    /// 找包内重复文件：按 (原始大小, CRC) 分组，两者都有效才参与 —— 没有 CRC 的格式 / 条目
    /// 没法可靠判重，宁可漏报不误报。空文件（size 0）也跳过（CRC 全一样，全是噪音）。
    /// 结果按浪费空间降序（最值得清的排前面）。
    nonisolated static func findDuplicates(in items: [ArchiveItem]) -> [DuplicateFileGroup] {
        var groups: [String: (size: Int64, crc: String, paths: [String])] = [:]
        for item in items {
            guard !item.isDirectory, let size = item.size, size > 0 else { continue }
            let crc = item.crc.trimmingCharacters(in: .whitespaces).uppercased()
            guard !crc.isEmpty, !crc.allSatisfy({ $0 == "0" }) else { continue }
            let key = "\(size)-\(crc)"
            groups[key, default: (size, crc, [])].paths.append(ArchiveDiff.normalizedPath(item.name))
        }
        return groups.values
            .filter { $0.paths.count >= 2 }
            .map { DuplicateFileGroup(size: $0.size, crc: $0.crc, paths: $0.paths.sorted()) }
            .sorted { lhs, rhs in
                if lhs.wastedBytes != rhs.wastedBytes { return lhs.wastedBytes > rhs.wastedBytes }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - 文件夹快照（0.4.2 #25）

extension ArchiveDiff {
    /// 把文件夹快照成可比对的条目列表：相对路径 / 目录标记 / 大小 / 修改时间。
    /// 文件系统不存 CRC → CRC 维度自动不参与（compare 对空 CRC 跳过）。符号链接按条目记录、不跟随。
    nonisolated static func folderItems(at root: URL, fileManager: FileManager = .default) -> [ArchiveItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var items: [ArchiveItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let isSymlink = values?.isSymbolicLink == true
            let isDirectory = values?.isDirectory == true && !isSymlink
            let size = Int64(values?.fileSize ?? 0)
            items.append(ArchiveItem(
                name: relative,
                isDirectory: isDirectory,
                size: isDirectory ? nil : size,
                modified: values?.contentModificationDate,
                sizeText: isDirectory ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                modifiedText: "",
                method: "",
                symlinkTarget: isSymlink ? ((try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? "") : ""
            ))
        }
        return items
    }
}
