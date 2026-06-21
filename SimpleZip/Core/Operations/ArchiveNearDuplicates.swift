//
//  ArchiveNearDuplicates.swift
//  SimpleZip
//
//  0.4.4 #69:归档里的**近似重复**文件识别 —— 不是字节相同(那是精确重复 `ArchiveDuplicates` 的活),而是
//  「同一份东西的不同版本 / 改名 / 副本」:把文件名归一化(去掉「副本 / (1) / _v2 / final」这类修订标记 +
//  扩展名)后落到同一个键、且不止一个的,归为一组。纯确定性、按名字 + 大小;AI 只在结果上**解释**。
//
//  红线:只看非加密条目名(头加密归档列不出名字)。不读内容。
//

import Foundation

nonisolated struct NearDuplicateGroup: Equatable, Identifiable {
    struct Entry: Equatable {
        let path: String
        let sizeText: String
        let size: Int64?
        let crc: String        // 空 = 无;同 crc = 字节相同
    }
    /// 归一化键(同组共享)。
    let id: String
    /// 给人看的代表名(组里第一个的文件名)。
    let displayName: String
    /// 组内成员(≥2)。
    let entries: [Entry]
    /// 组内是否有**字节完全相同**的(同非空 crc)—— 解释里区分「版本不同」vs「纯改名同源」。
    let hasByteIdentical: Bool
}

nonisolated struct NearDuplicateResult: Equatable {
    let groups: [NearDuplicateGroup]
    let scannedFileCount: Int
    var isEmpty: Bool { groups.isEmpty }
}

nonisolated enum ArchiveNearDuplicates {
    /// 找近似重复组。输入 = 归档全部条目(目录会被跳过)。
    static func find(_ items: [ArchiveItem]) -> NearDuplicateResult {
        var buckets: [String: [NearDuplicateGroup.Entry]] = [:]
        var order: [String] = []
        var scanned = 0
        for item in items where !item.isDirectory {
            let base = lastComponent(item.name)
            guard !base.isEmpty else { continue }
            scanned += 1
            let key = normalizedKey(base)
            guard !key.isEmpty else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(
                NearDuplicateGroup.Entry(path: item.name, sizeText: item.sizeText, size: item.size,
                                         crc: item.crc.trimmingCharacters(in: .whitespaces))
            )
        }
        let groups: [NearDuplicateGroup] = order.compactMap { key in
            guard let entries = buckets[key], entries.count >= 2 else { return nil }
            // 路径完全相同的不算(理论上不会,防御)。
            let uniqueByPath = Dictionary(grouping: entries, by: { $0.path }).compactMap { $0.value.first }
            guard uniqueByPath.count >= 2 else { return nil }
            let nonEmptyCRCs = uniqueByPath.map { $0.crc.lowercased() }.filter { !$0.isEmpty }
            let hasIdentical = Set(nonEmptyCRCs).count < nonEmptyCRCs.count
            return NearDuplicateGroup(
                id: key,
                displayName: lastComponent(uniqueByPath[0].path),
                entries: uniqueByPath,
                hasByteIdentical: hasIdentical
            )
        }
        return NearDuplicateResult(groups: groups, scannedFileCount: scanned)
    }

    /// 文件名归一化:小写 → 拆出扩展名 → 反复剥掉修订/副本标记 → 重新拼上扩展名。
    /// 不剥裸数字结尾(否则 chapter1/chapter2 等会被过度合并)。
    static func normalizedKey(_ rawBase: String) -> String {
        let base = rawBase.lowercased()
        let ext = fileExtension(base)
        var stem = stemWithoutExtension(base)
        var changed = true
        while changed {
            changed = false
            for pattern in revisionSuffixes {
                // `$` 锚定结尾 → first match 即末尾那段;再核对 upperBound 到结尾,稳妥。
                if let range = stem.range(of: pattern, options: [.regularExpression]),
                   range.upperBound == stem.endIndex, range.lowerBound != stem.startIndex {
                    stem.removeSubrange(range)
                    stem = stem.trimmingCharacters(in: trimChars)
                    changed = true
                }
            }
        }
        stem = stem.trimmingCharacters(in: trimChars)
        guard !stem.isEmpty else { return "" }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static let trimChars = CharacterSet(charactersIn: " _-.")

    /// 末尾修订/副本标记(锚定到结尾、不区分大小写已在 lowercased 处理)。覆盖中英德法常见说法。
    private static let revisionSuffixes: [String] = [
        #"[ _-]*\(\d+\)$"#,                        // " (1)" / "(2)"
        #"[ _-]*(copy|copies|kopie|copie|副本)( ?\d+)?$"#,  // copy / 副本 / kopie / copie
        #"[ _-]*v(ersion)?[ _-]?\d+$"#,             // _v2 / version 3
        #"[ _-]*(final|draft|rev|revision)[ _-]?\d*$"#,     // final / draft / rev2
    ]

    // MARK: - 纯文件名工具

    private static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    private static func fileExtension(_ base: String) -> String {
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[base.index(after: dot)...])
    }

    private static func stemWithoutExtension(_ base: String) -> String {
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        return String(base[..<dot])
    }
}
