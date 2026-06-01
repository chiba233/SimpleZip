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
                withTitle: localized("finder.extension.addToArchive"),
                action: #selector(addToArchive),
                keyEquivalent: ""
            )

            // 「用 SimpleZip 创建 ▸ ZIP / 7z / TAR.GZ」—— 按默认设置一键出包，无对话框。
            // 子菜单收纳各格式，避免右键菜单顶层堆太多项。格式名直接用通用写法，不必本地化。
            let createParent = NSMenuItem(title: localized("finder.extension.create"), action: nil, keyEquivalent: "")
            let createMenu = NSMenu()
            for (title, sel) in [("ZIP", #selector(createZip)), ("7z", #selector(create7z)), ("TAR.GZ", #selector(createTarGz))] {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                createMenu.addItem(item)
            }
            createParent.submenu = createMenu
            menu.addItem(createParent)

            menu.addItem(
                withTitle: localized("finder.extension.extract"),
                action: #selector(extractArchive),
                keyEquivalent: ""
            )
            menu.addItem(
                withTitle: localized("finder.extension.hash"),
                action: #selector(calculateHash),
                keyEquivalent: ""
            )
            return menu
        default:
            return nil
        }
    }

    /// 扩展是独立进程，只能看到「系统语言」，看不到主 app 的「应用内语言覆盖」（写在主 app 偏好域的
    /// `AppleLanguages`），所以菜单一直是英文。两端都没沙盒，这里用 CFPreferences 跨域读主 app 的
    /// 语言覆盖，命中就加载扩展 bundle 里对应的 `.lproj` 来取词；主 app 是「跟随系统」时读不到覆盖，
    /// 回退到默认 bundle（= 系统语言），行为与原来一致。
    private func localized(_ key: String) -> String {
        localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 每次取菜单时重新解析 —— 扩展进程长驻，用户中途改语言也能立刻跟上（一次右键的开销可忽略）。
    private var localizationBundle: Bundle {
        // 扩展 id 形如 "<app-id>.FinderExtension"，去掉后缀即主 app 偏好域。
        let appDomain = (Bundle.main.bundleIdentifier ?? "").replacingOccurrences(of: ".FinderExtension", with: "")
        guard !appDomain.isEmpty,
              let langs = CFPreferencesCopyAppValue("AppleLanguages" as CFString, appDomain as CFString) as? [String],
              let code = langs.first else {
            return .main
        }
        // 先精确匹配（zh-Hans / zh-Hant 这种带地区的也走这里），再退两字母前缀（en-US → en）。
        for candidate in [code, String(code.prefix(2))] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }

    @objc private func addToArchive() {
        sendAction("addToArchive")
    }

    @objc private func extractArchive() {
        sendAction("extract")
    }

    @objc private func createZip() {
        sendAction("createZip")
    }

    @objc private func create7z() {
        sendAction("create7z")
    }

    @objc private func createTarGz() {
        sendAction("createTarGz")
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
