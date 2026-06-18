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
}
