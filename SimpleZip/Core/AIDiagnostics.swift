//
//  AIDiagnostics.swift
//  SimpleZip
//
//  0.4.5 #80:失败诊断的**确定性分类器**(路线图建议十一 + 建议八)。先由 App 给标签,AI 只解释标签 ——
//  不让模型从原始日志里猜「权限 / 缺卷 / 口令 / 损坏 / 磁盘空间」这些根因。
//
//  `AIDiagnosticTag` 是比现成 `ArchiveTestFailureKind`(只管归档完整性 test)更广的 AI 面向标签集:覆盖所有
//  操作失败(解压 / 创建 / 校验 …)。判别上**复用 `ArchiveService.classifyTestFailure` 的完整性子集**
//  (A2 不重造 encrypted/missingVolume/corrupted/unsupported 的判别),只新增它不覆盖的更广标签。
//  rawValue 用稳定英文 token(对齐路线图,不随 UI 语言走)。纯函数,SwiftPM 可断言。
//

import Foundation

/// 给 AI 的诊断标签。稳定英文 token —— prompt / 测试 / 活动索引 / 筛选共用。
nonisolated enum AIDiagnosticTag: String, Codable, Equatable, CaseIterable, Sendable {
    case permissionDenied = "permission-denied"
    case missingVolume = "missing-volume"
    case needsPassword = "needs-password"
    case corruptArchive = "corrupt-archive"
    case unsupportedFormat = "unsupported-format"
    case diskSpace = "disk-space"
    case destinationConflict = "destination-conflict"
    case signatureProblem = "signature-problem"
    case checksumMismatch = "checksum-mismatch"
    case cancelledByUser = "cancelled-by-user"
    case interruptedPreviousSession = "interrupted-previous-session"
}

nonisolated enum AIDiagnosticsClassifier {
    /// 把失败文本(message + 抽出的错误行)确定性归类成一组诊断标签(有序、去重)。匹配不上返回空数组。
    /// 启发式匹配 7zz / unzip / gpg 的英文诊断词(后端输出不本地化)。
    static func classify(message: String, errorLines: [String] = []) -> [AIDiagnosticTag] {
        let haystack = ([message] + errorLines).joined(separator: "\n").lowercased()
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var tags: [AIDiagnosticTag] = []
        func add(_ tag: AIDiagnosticTag) { if !tags.contains(tag) { tags.append(tag) } }

        // 1) 复用现成归档完整性分类器(不重造 encrypted/missingVolume/corrupted/unsupported)。
        switch ArchiveService.classifyTestFailure(haystack) {
        case .encrypted:
            add(.needsPassword)
        case .missingVolume:
            add(.missingVolume)
        case .unsupported:
            add(.unsupportedFormat)
        case .corrupted:
            // CRC / data error → 比 corrupt 更具体的 checksumMismatch;其余结构损坏 → corruptArchive。
            if haystack.contains("crc failed") || haystack.contains("data error") {
                add(.checksumMismatch)
            } else {
                add(.corruptArchive)
            }
        case .other:
            break
        }

        // 2) classifyTestFailure 不覆盖的、更广的操作失败标签。

        // 权限:7zz「Can not create output directory : Permission denied」/ POSIX 拒绝。
        if haystack.contains("permission denied")
            || haystack.contains("operation not permitted")
            || haystack.contains("access is denied")
            || haystack.contains("read-only file system") {
            add(.permissionDenied)
        }

        // 磁盘空间。
        if haystack.contains("no space left")
            || haystack.contains("not enough space")
            || haystack.contains("insufficient space")
            || haystack.contains("disk full")
            || haystack.contains("enospc") {
            add(.diskSpace)
        }

        // 目标冲突 / 覆盖。
        if haystack.contains("already exists")
            || haystack.contains("file exists")
            || haystack.contains("would overwrite")
            || (haystack.contains("destination") && haystack.contains("conflict")) {
            add(.destinationConflict)
        }

        // 签名 / 验签问题(gpg / .szs / .siz)。
        if haystack.contains("bad signature")
            || haystack.contains("signature is invalid")
            || haystack.contains("invalid signature")
            || haystack.contains("verification failed")
            || haystack.contains("not trusted")
            || haystack.contains("no public key") {
            add(.signatureProblem)
        }

        // 显式校验不符(SHA256SUMS / verify 失败,非归档 CRC 路径)。
        if !tags.contains(.checksumMismatch),
           (haystack.contains("checksum") && haystack.contains("mismatch"))
            || (haystack.contains("sha256") && (haystack.contains("mismatch") || haystack.contains("does not match")))
            || haystack.contains("hash mismatch") {
            add(.checksumMismatch)
        }

        // 用户取消。整词匹配(审计 #13:避免误命中 "cancellation" / 其它子串)。
        if containsWord("cancelled", in: haystack) || containsWord("canceled", in: haystack) {
            add(.cancelledByUser)
        }

        // 上次会话中断的残留。"interrupted" 整词匹配(审计 #13:避免误命中 "uninterrupted")。
        if containsWord("interrupted", in: haystack)
            || haystack.contains("incomplete from a previous")
            || (haystack.contains("previous session") && haystack.contains("leftover")) {
            add(.interruptedPreviousSession)
        }

        return tags
    }

    /// 整词匹配(`\bword\b`)。正则构造失败(理论上不会)时退回子串包含。
    private static func containsWord(_ word: String, in haystack: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return haystack.contains(word) }
        return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }
}
