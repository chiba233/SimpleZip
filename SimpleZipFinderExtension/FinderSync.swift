//
//  FinderSync.swift
//  SimpleZipFinderExtension
//
//  Created by HoshinoYumeka on 2026/05/28.
//

import AppKit
import FinderSync
import Foundation

private struct FinderActionPayload: Encodable {
    let fileURLs: [String]
}

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .toolbarItemMenu:
            let menu = NSMenu(title: "SimpleZip")
            menu.addItem(
                withTitle: NSLocalizedString("finder.extension.addToArchive", comment: ""),
                action: #selector(addToArchive),
                keyEquivalent: ""
            )
            menu.addItem(
                withTitle: NSLocalizedString("finder.extension.hash", comment: ""),
                action: #selector(calculateHash),
                keyEquivalent: ""
            )
            return menu
        default:
            return nil
        }
    }

    @objc private func addToArchive() {
        sendAction("addToArchive")
    }

    @objc private func calculateHash() {
        sendAction("hash")
    }

    private func sendAction(_ action: String) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }

        do {
            let payload = FinderActionPayload(fileURLs: urls.map(\.path))
            let payloadURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimpleZipFinderAction-\(UUID().uuidString).json")
            let data = try JSONEncoder().encode(payload)
            try data.write(to: payloadURL, options: .atomic)

            var components = URLComponents()
            components.scheme = "simplezip"
            components.host = "finder-action"
            components.queryItems = [
                URLQueryItem(name: "action", value: action),
                URLQueryItem(name: "payload", value: payloadURL.path)
            ]

            guard let callbackURL = components.url else { return }
            NSWorkspace.shared.open(callbackURL)
        } catch {
            NSLog("SimpleZip Finder action failed: \(error.localizedDescription)")
        }
    }

    private func selectedURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selectedURLs = controller.selectedItemURLs(), !selectedURLs.isEmpty {
            return selectedURLs
        }
        if let targetedURL = controller.targetedURL() {
            return [targetedURL]
        }
        return []
    }
}
