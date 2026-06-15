//
//  ArchivePasswordContextHint.swift
//  SimpleZip
//
//  0.4.5 #80:密码上下文提示(白皮书 Feat 26「密码提示只做非 AI、手动确认的上下文辅助」)。
//
//  **这不是 AI 功能,也不进 AI 数据底座** —— 密码 / 口令 / passphrase 是硬红线,绝不进 AI prompt / 缓存 /
//  日志 / 习惯摘要。所以它归在 Core 根的「安全设计」里,不在 `Core/AI/`。它只在用户**打开密码输入 UI**时,
//  给「可能的密码来源」线索(归档名 token / 目录 token / where-from 域名),帮用户回忆;**绝不自动尝试、
//  绝不读剪贴板、绝不把候选密码喂模型、绝不从文本里抽取 `password: xxx` 当建议**。
//
//  防御核心:`hints(...)` 只接受低敏 token / 域名,并**主动拒绝任何疑似密码值**的输入(含 `=`/`:` 赋值形态、
//  含 password/secret/token/key 字样、或高熵长串)—— 即使调用方误传,也不会把疑似口令显示出来。
//  `requiresUserClick` 恒 true。纯函数、确定性,SwiftPM 可断言。
//

import Foundation

/// 一条密码上下文线索(只含低敏来源,绝不含疑似口令值)。
nonisolated struct ArchivePasswordContextHint: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Equatable, Sendable {
        case domainToken = "domain-token"
        case filenameToken = "filename-token"
        case folderToken = "folder-token"
        case siblingReadme = "sibling-readme"
    }

    let archiveID: String
    let hintKind: Kind
    /// 展示文本 —— 只含低敏 token / 域名,绝不含任何疑似密码值。
    let displayText: String
    /// 这条线索来自哪(稳定英文短描述)。
    let sourceDescription: String
    /// 恒 true —— 永远只提示、需用户手动操作,绝不自动尝试。
    let requiresUserClick: Bool

    init(archiveID: String, hintKind: Kind, displayText: String, sourceDescription: String) {
        self.archiveID = archiveID
        self.hintKind = hintKind
        self.displayText = displayText
        self.sourceDescription = sourceDescription
        self.requiresUserClick = true // 不可由调用方关闭
    }
}

nonisolated enum ArchivePasswordContextHintBuilder {
    /// 从允许的低敏来源生成提示。任何**疑似密码值**的输入被确定性拒绝(不产生提示)。
    /// - filenameTokens / folderTokens:归档名 / 目录名拆出的 token。
    /// - whereFromDomains:macOS quarantine / where-from URL 的域名(如 `moe-anime.com`)。
    static func hints(
        archiveID: String,
        filenameTokens: [String] = [],
        folderTokens: [String] = [],
        whereFromDomains: [String] = []
    ) -> [ArchivePasswordContextHint] {
        var result: [ArchivePasswordContextHint] = []
        var seen = Set<String>()
        func add(_ kind: ArchivePasswordContextHint.Kind, _ text: String, _ source: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !looksLikeSecret(trimmed) else { return }
            let dedupKey = "\(kind.rawValue)|\(trimmed.lowercased())"
            guard seen.insert(dedupKey).inserted else { return }
            result.append(ArchivePasswordContextHint(
                archiveID: archiveID, hintKind: kind, displayText: trimmed, sourceDescription: source))
        }
        for domain in whereFromDomains { add(.domainToken, domain, "where-from URL domain") }
        for token in filenameTokens { add(.filenameToken, token, "archive file name token") }
        for token in folderTokens { add(.folderToken, token, "enclosing folder token") }
        return result
    }

    /// 保守判断一个字符串是否「像密码值」—— 命中即拒绝显示。宁可漏掉一条无害线索,也绝不显示疑似口令。
    static func looksLikeSecret(_ token: String) -> Bool {
        let lower = token.lowercased()
        // 赋值形态 `key=value` / `key: value`,典型 `password=...` / `token: ...`。
        if let eq = token.firstIndex(where: { $0 == "=" || $0 == ":" }),
           token.index(after: eq) < token.endIndex,
           !token[token.index(after: eq)...].trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        // 含敏感字样。
        let markers = ["password", "passwd", "passphrase", "secret", "token", "apikey", "api_key", "privatekey", "private_key"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        // 高熵长串:长度 ≥ 20 且同时含字母、数字、且含非字母数字符号(典型随机口令 / 密钥片段)。
        if token.count >= 20 {
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            let hasSymbol = token.contains { !$0.isLetter && !$0.isNumber }
            if hasLetter && hasDigit && hasSymbol { return true }
        }
        return false
    }
}
