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
//  0.4.2 #5 搜索增强：搜索框文本支持 token 语法（`ArchiveSearchQuery.parse`）——
//      *.swift  size:>1MB  ext:pdf  encrypted:true  crc:A1B2C3D4  comment:草稿
//      path:src/  modified:<7d  regex:^docs/.*\.md$
//  普通词照旧子串匹配；带 `*` / `?` 的词按 glob（fnmatch）匹配。
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
    /// 仅显示**未**加密条目（`encrypted:false`）。与 encryptedOnly 同时为 true 时无匹配（用户自相矛盾）。
    var excludeEncrypted: Bool = false
    /// 原始大小下限（字节，含）。nil = 不限。目录（size 为 nil）在设了大小约束时一律不匹配。
    var minSize: Int64?
    /// 原始大小上限（字节，含）。nil = 不限。
    var maxSize: Int64?
    /// 修改时间下限（含）。nil = 不限。无修改时间的条目在设了约束时不匹配。
    var modifiedAfter: Date?
    /// 扩展名过滤（不带点、已小写）。目录在设了扩展名时不匹配。
    var fileExtension: String?
    /// CRC 精确匹配（已大写、去空白）。无 CRC 的条目在设了约束时不匹配。
    var crc: String?
    /// 条目注释子串（大小写不敏感）。
    var commentText: String?
    /// 完整路径子串（大小写不敏感）—— `path:` token；与 `text` 互不影响。
    var pathText: String?
    /// glob 模式（fnmatch，大小写不敏感）。多个 = 全部都要匹配。
    /// 模式含 `/` 时对完整路径匹配，否则只对当前层级名匹配。
    var namePatterns: [String] = []
    /// 正则（大小写不敏感）对完整路径匹配。**无效正则按普通子串退化**（边打边搜不报错）。
    var nameRegex: String?

    enum Scope: String, CaseIterable, Hashable { case name, fullPath }
    enum Kind: String, CaseIterable, Hashable { case any, filesOnly, foldersOnly }

    /// 没有任何有效约束 —— 调用方可据此跳过过滤、直接展示全部。
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && kind == .any
            && !encryptedOnly
            && !excludeEncrypted
            && minSize == nil
            && maxSize == nil
            && modifiedAfter == nil
            && fileExtension == nil
            && crc == nil
            && commentText == nil
            && pathText == nil
            && namePatterns.isEmpty
            && nameRegex == nil
    }

    // MARK: - token 语法解析（0.4.2）

    /// 把搜索框原始文本解析成查询。按空白切词；`key:value` 形式的已知 token 进对应字段，
    /// 带 `*` / `?` 通配符的词按 glob，其余普通词合并回 `text` 子串（保持旧行为）。
    /// `now` 注入是为了 `modified:<7d` 可测。
    nonisolated static func parse(_ raw: String, now: Date = Date()) -> ArchiveSearchQuery {
        var query = ArchiveSearchQuery()
        var plainWords: [String] = []

        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                if !value.isEmpty, applyToken(key: key, value: value, to: &query, now: now) {
                    continue
                }
            }
            if token.contains("*") || token.contains("?") {
                query.namePatterns.append(token)
            } else {
                plainWords.append(token)
            }
        }
        query.text = plainWords.joined(separator: " ")
        return query
    }

    /// 已知 token → 字段。返回 false = 不认识的 key，整个词回落为普通文本。
    nonisolated private static func applyToken(key: String, value: String, to query: inout ArchiveSearchQuery, now: Date) -> Bool {
        switch key {
        case "ext", "extension":
            query.fileExtension = value.hasPrefix(".") ? String(value.dropFirst()).lowercased() : value.lowercased()
            return true
        case "size":
            return applySizeToken(value, to: &query)
        case "encrypted":
            switch value.lowercased() {
            case "true", "yes", "1": query.encryptedOnly = true
            case "false", "no", "0": query.excludeEncrypted = true
            default: return false
            }
            return true
        case "crc":
            query.crc = value.uppercased()
            return true
        case "comment":
            query.commentText = value
            return true
        case "path":
            query.pathText = value
            return true
        case "modified":
            guard let interval = parseAgeInterval(value) else { return false }
            query.modifiedAfter = now.addingTimeInterval(-interval)
            return true
        case "regex", "re":
            query.nameRegex = value
            return true
        case "kind", "type":
            switch value.lowercased() {
            case "file", "files": query.kind = .filesOnly
            case "folder", "folders", "dir", "dirs": query.kind = .foldersOnly
            case "any": query.kind = .any
            default: return false
            }
            return true
        default:
            return false
        }
    }

    /// `>1mb` / `>=500k` / `<2gb` / `=10mb`（= 同时设上下限）。单位 1024 进制，缺省字节。
    nonisolated private static func applySizeToken(_ value: String, to query: inout ArchiveSearchQuery) -> Bool {
        var rest = Substring(value)
        var op = ">="
        for candidate in [">=", "<=", ">", "<", "="] where rest.hasPrefix(candidate) {
            op = candidate
            rest = rest.dropFirst(candidate.count)
            break
        }
        guard let bytes = parseByteCount(String(rest)) else { return false }
        switch op {
        case ">": query.minSize = bytes + 1
        case ">=": query.minSize = bytes
        case "<": query.maxSize = max(0, bytes - 1)
        case "<=": query.maxSize = bytes
        case "=": query.minSize = bytes; query.maxSize = bytes
        default: return false
        }
        return true
    }

    /// `1mb` / `500k` / `2GiB` / `1234` → 字节数（1024 进制）。
    nonisolated static func parseByteCount(_ text: String) -> Int64? {
        let lower = text.lowercased()
        let units: [(suffix: String, factor: Int64)] = [
            ("tib", 1 << 40), ("tb", 1 << 40), ("t", 1 << 40),
            ("gib", 1 << 30), ("gb", 1 << 30), ("g", 1 << 30),
            ("mib", 1 << 20), ("mb", 1 << 20), ("m", 1 << 20),
            ("kib", 1 << 10), ("kb", 1 << 10), ("k", 1 << 10),
            ("b", 1)
        ]
        for unit in units where lower.hasSuffix(unit.suffix) {
            let number = lower.dropLast(unit.suffix.count)
            guard let value = Double(number), value >= 0 else { return nil }
            return Int64(value * Double(unit.factor))
        }
        guard let value = Double(lower), value >= 0 else { return nil }
        return Int64(value)
    }

    /// `<7d` / `7d` / `<24h` / `2w` → 秒。单位 h / d / w。
    nonisolated private static func parseAgeInterval(_ value: String) -> TimeInterval? {
        var rest = Substring(value.lowercased())
        if rest.hasPrefix("<") { rest = rest.dropFirst() }
        guard let unit = rest.last else { return nil }
        let factor: TimeInterval
        switch unit {
        case "h": factor = 3600
        case "d": factor = 86_400
        case "w": factor = 7 * 86_400
        default: return nil
        }
        guard let number = Double(rest.dropLast()), number > 0 else { return nil }
        return number * factor
    }
}

enum ArchiveSearch {

    /// 过滤：返回满足全部条件的条目（保持输入顺序）。空条件返回原数组（拷贝）。
    /// 正则在这里一次性编译（无效正则退化为子串），避免逐条目重编译。
    static func filter(_ items: [ArchiveItem], with query: ArchiveSearchQuery) -> [ArchiveItem] {
        guard !query.isEmpty else { return items }
        let compiledRegex = compileRegex(query.nameRegex)
        return items.filter { matches($0, query, compiledRegex: compiledRegex) }
    }

    /// 单条目是否满足条件（独立调用版 —— 自行编译正则）。各维度 AND。
    static func matches(_ item: ArchiveItem, _ query: ArchiveSearchQuery) -> Bool {
        matches(item, query, compiledRegex: compileRegex(query.nameRegex))
    }

    /// nil = 没设正则；`.regex` = 编译成功；`.fallbackText` = 无效正则退化为子串。
    private enum CompiledRegex {
        case regex(NSRegularExpression)
        case fallbackText(String)
    }

    private static func compileRegex(_ source: String?) -> CompiledRegex? {
        guard let source else { return nil }
        if let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) {
            return .regex(regex)
        }
        return .fallbackText(source)
    }

    private static func matches(_ item: ArchiveItem, _ query: ArchiveSearchQuery, compiledRegex: CompiledRegex?) -> Bool {
        switch query.kind {
        case .any: break
        case .filesOnly: if item.isDirectory { return false }
        case .foldersOnly: if !item.isDirectory { return false }
        }

        if query.encryptedOnly, !item.isEncrypted { return false }
        if query.excludeEncrypted, item.isEncrypted { return false }

        if query.minSize != nil || query.maxSize != nil {
            // 大小约束只对有大小的条目（文件）有意义；目录 / 无大小条目在设了约束时排除。
            guard let size = item.size else { return false }
            if let minSize = query.minSize, size < minSize { return false }
            if let maxSize = query.maxSize, size > maxSize { return false }
        }

        if let modifiedAfter = query.modifiedAfter {
            guard let modified = item.modified, modified >= modifiedAfter else { return false }
        }

        if let fileExtension = query.fileExtension {
            guard !item.isDirectory,
                  (item.displayName as NSString).pathExtension.lowercased() == fileExtension else { return false }
        }

        if let crc = query.crc {
            let itemCRC = item.crc.trimmingCharacters(in: .whitespaces).uppercased()
            guard !itemCRC.isEmpty, itemCRC == crc else { return false }
        }

        if let commentText = query.commentText {
            guard item.comment.localizedCaseInsensitiveContains(commentText) else { return false }
        }

        let fullPath = ArchiveDiff.normalizedPath(item.name)

        if let pathText = query.pathText {
            guard fullPath.localizedCaseInsensitiveContains(pathText) else { return false }
        }

        for pattern in query.namePatterns {
            // 模式带路径分隔 → 整路径匹配；否则匹配当前层级名（直觉行为：`*.swift` 不关心目录）。
            let target = pattern.contains("/") ? fullPath : item.displayName
            guard fnmatch(pattern, target, FNM_CASEFOLD) == 0 else { return false }
        }

        if let compiledRegex {
            switch compiledRegex {
            case .regex(let regex):
                let range = NSRange(fullPath.startIndex..<fullPath.endIndex, in: fullPath)
                guard regex.firstMatch(in: fullPath, range: range) != nil else { return false }
            case .fallbackText(let fallback):
                guard fullPath.localizedCaseInsensitiveContains(fallback) else { return false }
            }
        }

        let needle = query.text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let haystack = query.scope == .name ? item.displayName : item.name
            if !haystack.localizedCaseInsensitiveContains(needle) { return false }
        }

        return true
    }
}

// MARK: - 保存的过滤器（0.4.2 #6）

/// 一条命名的搜索过滤器。`query` 就是搜索框字符串（token 语法），apply = 填回搜索框。
struct SavedSearchFilter: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var query: String

    init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// 保存的过滤器 + 最近搜索 的持久化仓库。UserDefaults 注入，方便测试用独立 suite。
/// 体例对齐 `CompressionPresetStore`。
final class SavedSearchFilterStore {
    private let defaults: UserDefaults
    private let filtersKey = "SimpleZip.SavedSearchFilters.v1"
    private let recentsKey = "SimpleZip.RecentSearchQueries.v1"
    /// 最近搜索保留条数。
    static let recentsLimit = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SavedSearchFilter] {
        guard let data = defaults.data(forKey: filtersKey) else { return [] }
        return (try? JSONDecoder().decode([SavedSearchFilter].self, from: data)) ?? []
    }

    func save(_ filters: [SavedSearchFilter]) {
        guard let data = try? JSONEncoder().encode(filters) else { return }
        defaults.set(data, forKey: filtersKey)
    }

    @discardableResult
    func add(_ filter: SavedSearchFilter) -> [SavedSearchFilter] {
        var all = load()
        all.append(filter)
        save(all)
        return all
    }

    @discardableResult
    func remove(id: UUID) -> [SavedSearchFilter] {
        let remaining = load().filter { $0.id != id }
        save(remaining)
        return remaining
    }

    func recents() -> [String] {
        defaults.stringArray(forKey: recentsKey) ?? []
    }

    /// 记一条最近搜索：去首尾空白、去重（提到最前）、截到 `recentsLimit` 条。空串不记。
    @discardableResult
    func recordRecent(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return recents() }
        var all = recents().filter { $0 != trimmed }
        all.insert(trimmed, at: 0)
        if all.count > Self.recentsLimit { all = Array(all.prefix(Self.recentsLimit)) }
        defaults.set(all, forKey: recentsKey)
        return all
    }
}
