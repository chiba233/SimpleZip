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

    /// 列出能打开「某种文件类型」的 app —— 用于归档内条目(还没解出来、没有真实 URL)。
    /// **关键**:`NSWorkspace.urlsForApplications(toOpen:)` 对**不存在的文件**会返回空(系统判不出类型),
    /// 所以这里先按扩展名建一个真实的临时空文件再查,查完即删 —— 否则「打开方式」永远只剩「其他…」。
    static func applicationURLs(forFileNamed fileName: String) -> [URL] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SimpleZip-OpenWithProbe-\(UUID().uuidString)", isDirectory: true)
        let ext = (fileName as NSString).pathExtension
        let probeName = ext.isEmpty ? "probe" : "probe.\(ext)"
        let probe = dir.appendingPathComponent(probeName)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? Data().write(to: probe)) != nil else {
            try? fm.removeItem(at: dir)
            return []
        }
        defer { try? fm.removeItem(at: dir) }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { seen.insert($0.path).inserted }
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
