//
//  ArchiveSafety.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/18.
//

import Foundation

enum ArchiveSafety {
    nonisolated static func validateForExtraction(_ items: [ArchiveItem]) throws {
        try validateEntryNames(items.map(\.name))
    }

    nonisolated static func validateEntryNames(_ names: [String]) throws {
        let unsafeNames = unsafeEntryNames(in: names)
        guard unsafeNames.isEmpty else {
            throw ArchiveError.unsafeArchiveEntries(Array(unsafeNames.prefix(5)))
        }
    }

    nonisolated static func unsafeEntryNames(in items: [ArchiveItem]) -> [String] {
        unsafeEntryNames(in: items.map(\.name))
    }

    nonisolated static func unsafeEntryNames(in names: [String]) -> [String] {
        names.filter(isUnsafeEntryName)
    }

    nonisolated static func isUnsafeEntryName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return true }
        if trimmedName.hasPrefix("/") || trimmedName.hasPrefix("\\") || trimmedName.hasPrefix("~") {
            return true
        }
        if trimmedName.hasPrefix("//") || trimmedName.hasPrefix("\\\\") {
            return true
        }
        if trimmedName.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return true
        }

        let normalizedSeparators = trimmedName.replacingOccurrences(of: "\\", with: "/")
        return normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    nonisolated static func validateExtractedTree(at root: URL, fileManager: FileManager = .default) throws {
        let unsafeLinks = try unsafeLinks(in: root, fileManager: fileManager)
        guard unsafeLinks.isEmpty else {
            throw ArchiveError.unsafeArchiveLinks(Array(unsafeLinks.prefix(5)))
        }
    }

    nonisolated static func unsafeLinks(in root: URL, fileManager: FileManager = .default) throws -> [String] {
        var links: [String] = []
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath == rootPath || standardizedPath.hasPrefix(rootPath + "/") else {
                throw ArchiveError.unsafeArchiveEntries([url.path])
            }

            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                links.append(url.lastPathComponent)
            }
        }
        return links
    }

    nonisolated static func requiresExternalOpenConfirmation(_ item: ArchiveItem) -> Bool {
        guard !item.isDirectory else { return true }
        let trimmedName = item.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let displayName = trimmedName.split(separator: "/").last.map(String.init) ?? item.name
        let ext = URL(fileURLWithPath: displayName).pathExtension.lowercased()
        let riskyExtensions: Set<String> = [
            "app", "pkg", "mpkg", "dmg", "command", "tool", "sh", "bash", "zsh",
            "scpt", "applescript", "terminal", "workflow", "js", "html", "htm"
        ]
        return riskyExtensions.contains(ext)
    }
}
