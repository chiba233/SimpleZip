//
//  AppBundleInstall.swift
//  SimpleZipCore
//
//  文件浏览器「移到应用程序」确定性建议的检测:一行是**不在应用程序目录里**的 .app,读它的 Info.plist
//  (CFBundleDisplayName / CFBundleName + CFBundleShortVersionString)得出预设文案所需的显示名。
//  纯死读、零模型;读不出可执行名的目录不算可安装 App(残缺/伪装包不出建议)。
//

import Foundation

nonisolated struct AppBundleInstallSuggestion: Equatable, Sendable {
    /// 建议行文案里的名字:App 名(优先 CFBundleDisplayName,次 CFBundleName,再退文件名)+ 版本(有则带)。
    let displayName: String

    /// Info.plist 大小上限:.app 是不可信输入,正常 Info.plist 几 KB,超限直接放弃。
    private static let maxInfoPlistBytes = 1 << 20

    /// 检测一个文件行是否该出「移到应用程序」建议。门槛从廉价到贵:后缀/目录/符号链接(纯内存)→
    /// 已在应用程序目录(字符串前缀)→ 读 Info.plist(一次小 IO,调用方按节点缓存结果)。不满足 → nil。
    static func detect(url: URL, isDirectory: Bool, isSymbolicLink: Bool,
                       fileManager: FileManager = .default) -> AppBundleInstallSuggestion? {
        guard isDirectory, !isSymbolicLink, url.pathExtension.lowercased() == "app" else { return nil }
        let standardized = url.standardizedFileURL.path
        for root in applicationRoots(fileManager: fileManager)
        where standardized == root || standardized.hasPrefix(root + "/") {
            return nil
        }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let attrs = try? fileManager.attributesOfItem(atPath: plistURL.path),
              let size = attrs[.size] as? Int, size > 0, size <= maxInfoPlistBytes,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
        let baseName = nonEmpty(plist["CFBundleDisplayName"])
            ?? nonEmpty(plist["CFBundleName"])
            ?? url.deletingPathExtension().lastPathComponent
        let version = nonEmpty(plist["CFBundleShortVersionString"])
        return AppBundleInstallSuggestion(displayName: version.map { "\(baseName) \($0)" } ?? baseName)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// 已经算「装好了」的位置:/Applications(含子层级,如 /Applications/Utilities)与 ~/Applications。
    private static func applicationRoots(fileManager: FileManager) -> [String] {
        ["/Applications", fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    }
}
