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

nonisolated struct AIDevToolsPipelineProductCounts: Equatable, Sendable {
    let summary: Int
    let openWith: Int
    let urlOpen: Int
    let install: Int
    let activity: Int
    let archiveEntry: Int
    let archiveKind: Int
    let folderGroup: Int
    let organize: Int
    let inspect: Int
    let test: Int
    let hash: Int
    let security: Int
    let compress: Int
    let convert: Int
    let inlineResult: Int
    /// 建议六 v2 模块⑤:活动中心 AI 工作台「建议筛选」chip 的模型排序产物数(各分类已排序 chip id 总数)。
    let workbenchChipRanking: Int
    /// 建议六 v2 模块1:活动中心「需要处理」卡 AI 解读缓存数(各分类已解读条数)。
    let workbenchNeedsAttention: Int
    /// 建议六 v2 模块①:活动中心失败任务「失败解释」缓存数(已解释的失败任务条数)。
    let workbenchFailureExplanation: Int
    /// 建议六 v2「真建议」:模型命名的真实聚集 chip 缓存数(各分类已命名 chip 总数)。
    let workbenchClusterChips: Int
    /// 建议七 Phase2:工具栏动作 AI 排序缓存数(文件级 + 类型级已烘焙的序总数)。
    let toolbarRanking: Int
    /// 解压速览预烘焙缓存数(前台 XPC 按需烘焙写入的 `extractAdvisoryByPath` 条数;已索引归档的定性走「包定性」)。
    let extractAdvisory: Int

    init(summary: Int, openWith: Int, urlOpen: Int, install: Int, activity: Int,
         archiveEntry: Int, archiveKind: Int, folderGroup: Int, organize: Int,
         inspect: Int, test: Int, hash: Int, security: Int, compress: Int,
         convert: Int, inlineResult: Int, workbenchChipRanking: Int = 0,
         workbenchNeedsAttention: Int = 0, workbenchFailureExplanation: Int = 0,
         workbenchClusterChips: Int = 0, toolbarRanking: Int = 0, extractAdvisory: Int = 0) {
        self.summary = summary
        self.openWith = openWith
        self.urlOpen = urlOpen
        self.install = install
        self.activity = activity
        self.archiveEntry = archiveEntry
        self.archiveKind = archiveKind
        self.folderGroup = folderGroup
        self.organize = organize
        self.inspect = inspect
        self.test = test
        self.hash = hash
        self.security = security
        self.compress = compress
        self.convert = convert
        self.inlineResult = inlineResult
        self.workbenchChipRanking = workbenchChipRanking
        self.workbenchNeedsAttention = workbenchNeedsAttention
        self.workbenchFailureExplanation = workbenchFailureExplanation
        self.workbenchClusterChips = workbenchClusterChips
        self.toolbarRanking = toolbarRanking
        self.extractAdvisory = extractAdvisory
    }
}

nonisolated struct AIDevToolsPipelineRow: Equatable, Sendable {
    let name: String
    let passName: String?
    let cachedProductCount: Int
}

nonisolated enum AIDevToolsPipelineCatalog {
    static func rows(for counts: AIDevToolsPipelineProductCounts) -> [AIDevToolsPipelineRow] {
        [
            AIDevToolsPipelineRow(name: "摘要", passName: "摘要", cachedProductCount: counts.summary),
            AIDevToolsPipelineRow(name: "打开方式", passName: "摘要", cachedProductCount: counts.openWith),
            AIDevToolsPipelineRow(name: "网页", passName: "网页", cachedProductCount: counts.urlOpen),
            AIDevToolsPipelineRow(name: "装App", passName: "装App", cachedProductCount: counts.install),
            AIDevToolsPipelineRow(name: "活动", passName: "活动", cachedProductCount: counts.activity),
            AIDevToolsPipelineRow(name: "包内", passName: "包内", cachedProductCount: counts.archiveEntry),
            AIDevToolsPipelineRow(name: "包定性", passName: "包定性", cachedProductCount: counts.archiveKind),
            AIDevToolsPipelineRow(name: "解压速览", passName: "包定性", cachedProductCount: counts.extractAdvisory),
            AIDevToolsPipelineRow(name: "文件组", passName: "文件组", cachedProductCount: counts.folderGroup),
            AIDevToolsPipelineRow(name: "整理", passName: "整理", cachedProductCount: counts.organize),
            AIDevToolsPipelineRow(name: "检测", passName: "包定性", cachedProductCount: counts.inspect),
            AIDevToolsPipelineRow(name: "测试", passName: "包定性", cachedProductCount: counts.test),
            AIDevToolsPipelineRow(name: "哈希", passName: "包定性", cachedProductCount: counts.hash),
            AIDevToolsPipelineRow(name: "安全", passName: "包定性", cachedProductCount: counts.security),
            AIDevToolsPipelineRow(name: "压缩", passName: "摘要", cachedProductCount: counts.compress),
            AIDevToolsPipelineRow(name: "转换", passName: "包定性", cachedProductCount: counts.convert),
            AIDevToolsPipelineRow(name: "内联结果", passName: nil, cachedProductCount: counts.inlineResult),
            AIDevToolsPipelineRow(name: "筛选排序", passName: "筛选排序", cachedProductCount: counts.workbenchChipRanking),
            AIDevToolsPipelineRow(name: "需要处理解读", passName: "需要处理解读", cachedProductCount: counts.workbenchNeedsAttention),
            AIDevToolsPipelineRow(name: "失败解释", passName: "失败解释", cachedProductCount: counts.workbenchFailureExplanation),
            AIDevToolsPipelineRow(name: "真建议", passName: "真建议", cachedProductCount: counts.workbenchClusterChips),
            AIDevToolsPipelineRow(name: "工具栏序", passName: "工具栏序", cachedProductCount: counts.toolbarRanking)
        ]
    }
}
