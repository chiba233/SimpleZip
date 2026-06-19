//
//  AIURLCandidateExtractor.swift
//  SimpleZip
//
//  Extracts real http(s) URLs from already-redacted preread text. Pure Core helper; no network, no filesystem.
//

import Foundation

nonisolated enum AIURLCandidateExtractor {
    private static let maximumCandidateLength = 2_048
    private static let trailingTrimCharacters = CharacterSet(charactersIn: ".,;:!?)]}>\"'")

    static func extract(from text: String, limit: Int = 12) -> [String] {
        guard limit > 0, !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`{}|\\^\[\]]+"#,
                                                   options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var output: [String] = []

        for match in regex.matches(in: text, options: [], range: range) {
            var raw = ns.substring(with: match.range)
            while let scalar = raw.unicodeScalars.last, trailingTrimCharacters.contains(scalar) {
                raw.removeLast()
            }
            guard raw.count <= maximumCandidateLength,
                  let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else { continue }
            let dedupeKey = raw.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            output.append(raw)
            if output.count >= limit { break }
        }
        return output
    }

    // MARK: - 高价值域名判定(从 AIBackgroundIndexer 下沉:URL 处理内聚一处,agent 复用 Core 时零拷贝可用)

    /// 确定性高价值域名(官方代码托管 / 包仓库 / 官方文档)—— 这些 URL 出现在 README/依赖清单里几乎总值得给「打开网页」。
    private static let highValueURLHosts: Set<String> = [
        "github.com", "gitlab.com",
        "pypi.org", "npmjs.com", "crates.io", "pkg.go.dev",
        "developer.apple.com", "developer.android.com",
        "docs.rs", "docs.python.org", "developer.mozilla.org",
        "stackoverflow.com"
    ]

    /// 命中高价值域名(精确或子域,如 docs.github.com → github.com)→ 跳过模型直接出建议。仍是抽出的**真实** URL,不造网址。
    static func isHighValueURL(_ rawURL: String) -> Bool {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return highValueURLHosts.contains(bare) || highValueURLHosts.contains(where: { bare.hasSuffix("." + $0) })
    }

    /// 从 URL 取「裸主机名」作为网页标签(去 www. 前缀);无 host 时回退原串。
    static func webPageLabel(for rawURL: String) -> String {
        guard let host = URLComponents(string: rawURL)?.host, !host.isEmpty else { return rawURL }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
