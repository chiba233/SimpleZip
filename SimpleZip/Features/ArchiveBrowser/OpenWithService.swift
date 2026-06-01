//
//  OpenWithService.swift
//  SimpleZip
//
//  Created by Codex on 2026/06/01.
//

import AppKit
import UniformTypeIdentifiers

enum OpenWithService {
    static func commonApplicationURLs(toOpen urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        let remainingAppPathSets = urls.dropFirst().map { url in
            Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.path))
        }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: first).filter { appURL in
            let path = appURL.path
            guard seen.insert(path).inserted else { return false }
            return remainingAppPathSets.allSatisfy { $0.contains(path) }
        }
    }

    static func open(_ urls: [URL], withApplicationAt appURL: URL) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    static func chooseApplicationAndOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("button.choose")
        if panel.runModal() == .OK, let appURL = panel.url {
            open(urls, withApplicationAt: appURL)
        }
    }
}
