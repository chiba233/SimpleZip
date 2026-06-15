//
//  AIFilenameEncoding.swift
//  SimpleZip
//
//  0.4.5 #80:乱码文件名候选编码确定性评分(白皮书 Feat 24「AI 乱码终结者」)。不能把乱码字符串丢给模型猜 ——
//  应分两层:① App 从 ZIP central directory 读 raw filename bytes(`ZipFilenameEncodingAnalyzer`,App 侧);
//  ② 这里用 Shift-JIS / EUC / GBK / Big5 / CP437 / UTF-8 等候选**确定性解码 + 评分**,模型只在候选间排序 / 解释,
//  **绝不发明新文件名**。
//
//  评分靠脚本一致性(假名 / 谚文 / 汉字集中 = 编码对了)+ replacement / 控制字符 / CP437 制表符乱码惩罚;
//  ZIP 明确标了 UTF-8 flag 时 UTF-8 直接置顶。解压时只在 staging 重命名,真实归档不被改。
//  纯函数、确定性(无 `Date` / 随机),SwiftPM 可断言。
//
//  **红线**:加密条目名没有样本,不参与(头加密归档不生成样本)。
//

import Foundation

/// 一个归档条目文件名的候选编码样本。`rawBytes` 由 App 从 central directory 读取。
nonisolated struct ArchiveFilenameEncodingSample: Codable, Equatable, Sendable {
    /// 单个候选编码的解码结果 + 确定性分数。
    nonisolated struct CandidateDecode: Codable, Equatable, Sendable {
        let encodingID: String
        let decodedName: String
        let replacementCharacterCount: Int
        /// 解码结果里出现的脚本:latin / han / kana / hangul / cyrillic / control / box-drawing。
        let scriptHints: [String]
        let deterministicScore: Double
    }

    let entryID: String
    let rawHexPrefix: String
    let currentDisplayName: String
    let utf8FlagPresent: Bool
    let candidateDecodes: [CandidateDecode]
}

/// 乱码修复计划。AI 只在 App 已生成的候选间选编码,不发明文件名。
nonisolated struct MojibakeRepairPlan: Codable, Equatable, Sendable {
    let archiveID: String
    let selectedEncodingID: String
    let confidence: Double
    /// entryID → 该编码下的解码名(供用户预览 rename diff)。
    let sampleFixes: [String: String]
    /// `relist-with-codepage`(后端支持 codepage 时)/ `rename-in-staging`(只在 staging 重命名)。
    let applyMode: String
    let requiresUserConfirmation: Bool
}

/// 候选编码确定性解码 + 评分。
nonisolated enum MojibakeEncodingScorer {
    /// 候选编码(稳定 id → `String.Encoding`),顺序即同分时的稳定 tie-break 基准之外的列举顺序。
    static let candidates: [(id: String, encoding: String.Encoding)] = [
        ("utf8", .utf8),
        ("shift_jis", .shiftJIS),
        ("euc_jp", .japaneseEUC),
        ("gb18030", cfEncoding(.GB_18030_2000)),
        ("big5", cfEncoding(.big5)),
        ("euc_kr", cfEncoding(.EUC_KR)),
        ("cp437", cfEncoding(.dosLatinUS)),
    ]

    /// 对一段 raw bytes 在所有候选编码下解码 + 评分,按分数降序、同分按 id 升序。解码失败的编码被跳过。
    static func decode(rawBytes: [UInt8], utf8FlagPresent: Bool) -> [ArchiveFilenameEncodingSample.CandidateDecode] {
        guard !rawBytes.isEmpty else { return [] }
        let data = Data(rawBytes)
        var results: [ArchiveFilenameEncodingSample.CandidateDecode] = []
        for candidate in candidates {
            guard let decoded = String(data: data, encoding: candidate.encoding) else { continue }
            let replacements = decoded.unicodeScalars.lazy.filter { $0 == "\u{FFFD}" }.count
            let hints = scriptHints(decoded)
            let score = score(id: candidate.id, hints: hints, replacements: replacements, utf8FlagPresent: utf8FlagPresent)
            results.append(.init(
                encodingID: candidate.id, decodedName: decoded,
                replacementCharacterCount: replacements, scriptHints: hints, deterministicScore: score))
        }
        return results.sorted {
            $0.deterministicScore != $1.deterministicScore
                ? $0.deterministicScore > $1.deterministicScore
                : $0.encodingID < $1.encodingID
        }
    }

    /// 从一个条目的 raw bytes 构建完整样本。
    static func sample(entryID: String, currentDisplayName: String, rawBytes: [UInt8],
                       utf8FlagPresent: Bool) -> ArchiveFilenameEncodingSample {
        ArchiveFilenameEncodingSample(
            entryID: entryID,
            rawHexPrefix: rawBytes.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "),
            currentDisplayName: currentDisplayName,
            utf8FlagPresent: utf8FlagPresent,
            candidateDecodes: decode(rawBytes: rawBytes, utf8FlagPresent: utf8FlagPresent))
    }

    /// 跨多个条目样本选最佳编码(各编码平均分最高者)。confidence = 该编码平均分。无候选返回 nil。
    static func bestEncoding(across samples: [ArchiveFilenameEncodingSample]) -> (encodingID: String, confidence: Double)? {
        var totals: [String: (sum: Double, count: Int)] = [:]
        for sample in samples {
            for candidate in sample.candidateDecodes {
                var entry = totals[candidate.encodingID] ?? (0, 0)
                entry.sum += candidate.deterministicScore
                entry.count += 1
                totals[candidate.encodingID] = entry
            }
        }
        guard !totals.isEmpty else { return nil }
        let ranked = totals
            .map { (id: $0.key, avg: $0.value.sum / Double($0.value.count)) }
            .sorted { $0.avg != $1.avg ? $0.avg > $1.avg : $0.id < $1.id }
        guard let best = ranked.first else { return nil }
        return (best.id, best.avg)
    }

    // MARK: -

    private static func score(id: String, hints: [String], replacements: Int, utf8FlagPresent: Bool) -> Double {
        // ZIP 明确标了 UTF-8 flag 且 UTF-8 解码成功 → 满分置顶。其他候选上限 0.95,确保此时 UTF-8 严格领先
        // (否则 GB18030 这类全字节兼容编码会把 UTF-8 字节乱解成含假名 / 汉字的串、并列到同分被 tie-break 抢前)。
        if id == "utf8" && utf8FlagPresent { return 1.0 }
        var score = 0.5
        let set = Set(hints)
        if set.contains("kana") || set.contains("hangul") { score += 0.35 } // 强东亚信号
        if set.contains("han") { score += 0.1 }
        if set.contains("control") { score -= 0.4 }
        if set.contains("box-drawing") { score -= 0.25 } // CP437 把 UTF-8 高位字节解成制表符的典型乱码
        if id == "utf8" { score += 0.05 } // UTF-8 是现代默认,纯 ASCII 时优先
        score -= 0.1 * Double(replacements)
        return min(max(score, 0), 0.95)
    }

    /// 解码结果里出现的脚本类别(稳定英文 token)。
    private static func scriptHints(_ string: String) -> [String] {
        var hits = Set<String>()
        for scalar in string.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x00...0x1F where v != 0x09: hits.insert("control")
            case 0x3040...0x30FF: hits.insert("kana")          // 平/片假名
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: hits.insert("han")
            case 0xAC00...0xD7A3: hits.insert("hangul")
            case 0x0400...0x04FF: hits.insert("cyrillic")
            case 0x2500...0x259F: hits.insert("box-drawing")   // 制表符 / 方块元素
            case 0x20...0x7E, 0xA0...0xFF: hits.insert("latin")
            default: break
            }
        }
        return hits.sorted()
    }

    private static func cfEncoding(_ cf: CFStringEncodings) -> String.Encoding {
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        return String.Encoding(rawValue: ns)
    }
}
