//
//  AppPreferences.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// App 内语言选择。system 表示跟随 macOS，其它值对应本地化目录名。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case thai

    var id: String { rawValue }

    nonisolated var localizationCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .japanese:
            return "ja"
        case .thai:
            return "th"
        }
    }

    nonisolated var appleLanguageCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .japanese:
            return "ja"
        case .thai:
            return "th"
        }
    }

    var title: String {
        switch self {
        case .system:
            return L10n.text("settings.language.system")
        case .english:
            return L10n.text("settings.language.en")
        case .simplifiedChinese:
            return L10n.text("settings.language.zhHans")
        case .traditionalChinese:
            return L10n.text("settings.language.zhHant")
        case .japanese:
            return L10n.text("settings.language.ja")
        case .thai:
            return L10n.text("settings.language.th")
        }
    }
}

/// 启动时默认打开的位置。
enum StartupLocation: String, CaseIterable, Identifiable {
    case home
    case downloads
    case desktop
    case lastFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return L10n.text("settings.startup.home")
        case .downloads:
            return L10n.text("settings.startup.downloads")
        case .desktop:
            return L10n.text("settings.startup.desktop")
        case .lastFolder:
            return L10n.text("settings.startup.lastFolder")
        }
    }
}

/// 解压时默认使用的位置。
enum DefaultExtractLocation: String, CaseIterable, Identifiable {
    case askEveryTime
    case archiveFolder
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime:
            return L10n.text("settings.extract.askEveryTime")
        case .archiveFolder:
            return L10n.text("settings.extract.archiveFolder")
        case .downloads:
            return L10n.text("settings.extract.downloads")
        }
    }
}

/// 解压遇到同名文件时的默认处理方式。
enum OverwriteBehavior: String, CaseIterable, Identifiable {
    case overwrite
    case skipExisting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite:
            return L10n.text("settings.overwrite.overwrite")
        case .skipExisting:
            return L10n.text("settings.overwrite.skipExisting")
        }
    }
}

/// 7-Zip 命令行后端来源。
enum SevenZipBackend: String, CaseIterable, Identifiable {
    case automatic
    case bundled
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("settings.7zip.automatic")
        case .bundled:
            return L10n.text("settings.7zip.bundled")
        case .system:
            return L10n.text("settings.7zip.system")
        }
    }
}

/// UserDefaults 读写封装，集中管理偏好键，避免字符串散落在业务代码里。
enum AppPreferences {
    private static let defaults = UserDefaults.standard

    enum Key {
        static let startupLocation = "startupLocation"
        static let defaultExtractLocation = "defaultExtractLocation"
        static let overwriteBehavior = "overwriteBehavior"
        static let showHiddenFiles = "showHiddenFiles"
        static let rememberLastFolder = "rememberLastFolder"
        static let lastFolderPath = "lastFolderPath"
        static let showFileSizeColumn = "showFileSizeColumn"
        static let showFileTypeColumn = "showFileTypeColumn"
        static let showFileModifiedColumn = "showFileModifiedColumn"
        static let showArchiveSizeColumn = "showArchiveSizeColumn"
        static let showArchiveModifiedColumn = "showArchiveModifiedColumn"
        static let showArchiveMethodColumn = "showArchiveMethodColumn"
        static let appLanguage = "appLanguage"
        static let sevenZipBackend = "sevenZipBackend"
        static let pinnedSidebarPaths = "pinnedSidebarPaths"
        static let recentSidebarPaths = "recentSidebarPaths"
        static let fileColumnOrder = "fileColumnOrder"
        static let archiveColumnOrder = "archiveColumnOrder"
    }

    static var startupLocation: StartupLocation {
        StartupLocation(rawValue: defaults.string(forKey: Key.startupLocation) ?? "") ?? .home
    }

    static var appLanguage: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
    }

    static var defaultExtractLocation: DefaultExtractLocation {
        DefaultExtractLocation(rawValue: defaults.string(forKey: Key.defaultExtractLocation) ?? "") ?? .askEveryTime
    }

    static var overwriteBehavior: OverwriteBehavior {
        OverwriteBehavior(rawValue: defaults.string(forKey: Key.overwriteBehavior) ?? "") ?? .overwrite
    }

    static var sevenZipBackend: SevenZipBackend {
        SevenZipBackend(rawValue: defaults.string(forKey: Key.sevenZipBackend) ?? "") ?? .automatic
    }

    static var showHiddenFiles: Bool {
        defaults.bool(forKey: Key.showHiddenFiles)
    }

    static var rememberLastFolder: Bool {
        if defaults.object(forKey: Key.rememberLastFolder) == nil {
            return true
        }
        return defaults.bool(forKey: Key.rememberLastFolder)
    }

    static var showFileSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileSizeColumn)
    }

    static var showFileTypeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileTypeColumn)
    }

    static var showFileModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileModifiedColumn)
    }

    static var showArchiveSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveSizeColumn)
    }

    static var showArchiveModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveModifiedColumn)
    }

    static var showArchiveMethodColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveMethodColumn)
    }

    static var lastFolderURL: URL? {
        guard let path = defaults.string(forKey: Key.lastFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func rememberLastFolder(_ url: URL) {
        guard rememberLastFolder else { return }
        defaults.set(url.path, forKey: Key.lastFolderPath)
        rememberRecentFolder(url)
    }

    static var pinnedSidebarURLs: [URL] {
        urls(forKey: Key.pinnedSidebarPaths)
    }

    static var recentSidebarURLs: [URL] {
        urls(forKey: Key.recentSidebarPaths)
    }

    static func pinSidebarURL(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: Key.pinnedSidebarPaths)
    }

    static func unpinSidebarURL(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: Key.pinnedSidebarPaths)
    }

    static func stringArray(forKey key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func setStringArray(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    static func defaultStartupURL(fileManager: FileManager = .default) -> URL {
        switch startupLocation {
        case .home:
            return fileManager.homeDirectoryForCurrentUser
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fileManager.homeDirectoryForCurrentUser
        case .lastFolder:
            return lastFolderURL ?? fileManager.homeDirectoryForCurrentUser
        }
    }

    static func defaultExtractURL(for archiveURL: URL, fileManager: FileManager = .default) -> URL? {
        switch defaultExtractLocation {
        case .askEveryTime:
            return nil
        case .archiveFolder:
            return archiveURL.deletingLastPathComponent()
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? archiveURL.deletingLastPathComponent()
        }
    }

    private static func defaultTrueBool(forKey key: String) -> Bool {
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    private static func rememberRecentFolder(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.recentSidebarPaths) ?? []
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(8)), forKey: Key.recentSidebarPaths)
    }

    private static func urls(forKey key: String) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }
}
