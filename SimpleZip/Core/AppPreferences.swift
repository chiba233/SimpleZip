//
//  AppPreferences.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation
import Security

/// App 内语言选择。system 表示跟随 macOS，其它值对应本地化目录名。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case french
    case german
    case korean
    case russian
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
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .korean:
            return "ko"
        case .russian:
            return "ru"
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
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .korean:
            return "ko"
        case .russian:
            return "ru"
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
        case .spanish:
            return L10n.text("settings.language.es")
        case .french:
            return L10n.text("settings.language.fr")
        case .german:
            return L10n.text("settings.language.de")
        case .korean:
            return L10n.text("settings.language.ko")
        case .russian:
            return L10n.text("settings.language.ru")
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
///
/// `documents` / `movies` / `music` / `pictures` 都是 macOS 自动建好的用户常用目录，
/// 默认列出来比让用户每次选 Custom 再翻文件夹更顺手。
/// `custom` 表示用户在设置里挑了一个任意路径，实际路径放在 `Key.startupCustomLocationPath`。
enum StartupLocation: String, CaseIterable, Identifiable {
    case home
    case downloads
    case desktop
    case documents
    case movies
    case music
    case pictures
    case lastFolder
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return L10n.text("settings.startup.home")
        case .downloads:
            return L10n.text("settings.startup.downloads")
        case .desktop:
            return L10n.text("settings.startup.desktop")
        case .documents:
            return L10n.text("settings.startup.documents")
        case .movies:
            return L10n.text("settings.startup.movies")
        case .music:
            return L10n.text("settings.startup.music")
        case .pictures:
            return L10n.text("settings.startup.pictures")
        case .lastFolder:
            return L10n.text("settings.startup.lastFolder")
        case .custom:
            return L10n.text("settings.startup.custom")
        }
    }
}

/// 解压遇到同名文件时的默认处理方式。
enum OverwriteBehavior: String, CaseIterable, Identifiable {
    case ask
    case overwrite
    case skipExisting
    case replaceIfDifferent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:
            return L10n.text("settings.overwrite.ask")
        case .overwrite:
            return L10n.text("settings.overwrite.overwrite")
        case .skipExisting:
            return L10n.text("settings.overwrite.skipExisting")
        case .replaceIfDifferent:
            return L10n.text("conflict.replaceIfDifferent")
        }
    }
}

enum ArchiveSecurityDecision: String, CaseIterable, Identifiable {
    case ask
    case allow
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:
            return L10n.text("settings.security.ask")
        case .allow:
            return L10n.text("settings.security.allow")
        case .deny:
            return L10n.text("settings.security.deny")
        }
    }
}

/// 7-Zip 命令行后端来源。
/// 用户在「压缩」设置里选的 7-Zip 来源 —— 是「选择」不是「后端实现」。
/// 真正的 backend 实现在 `SevenZipBackend` (Core/Backends)。
enum SevenZipBackendChoice: String, CaseIterable, Identifiable {
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

/// 用户在「压缩」设置里选的 RAR 来源 —— 是「选择」不是「后端实现」。
/// 真正的 backend 实现将来在 `RarBackend` (Core/Backends，Phase 4 step 3c)。
enum RarBackendChoice: String, CaseIterable, Identifiable {
    case automatic
    case bundled
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return L10n.text("settings.rar.automatic")
        case .bundled:
            return L10n.text("settings.rar.bundled")
        case .system:
            return L10n.text("settings.rar.system")
        }
    }
}

/// UserDefaults 读写封装，集中管理偏好键，避免字符串散落在业务代码里。
enum AppPreferences {
    private nonisolated static var defaults: UserDefaults { UserDefaults.standard }

    enum Key {
        nonisolated static let startupLocation = "startupLocation"
        /// 当 `startupLocation == .custom` 时启动应该打开的具体文件夹路径。
        /// 与 `lastFolderPath` 不同 —— 这个是用户在设置里固定挑的位置，不会被「记住上次打开的文件夹」覆盖。
        /// 同时是 custom 历史列表里的「当前选中」指针。
        nonisolated static let startupCustomLocationPath = "startupCustomLocationPath"
        /// 用户挑过的所有 custom 路径（MRU 排序），让 Menu 有「记忆」功能。
        /// 容量受 Menu 总项数 cap 10 约束 —— 加新的会从末尾驱逐。
        nonisolated static let startupCustomLocationHistory = "startupCustomLocationHistory"
        nonisolated static let overwriteBehavior = "overwriteBehavior"
        nonisolated static let suspiciousPathPolicy = "suspiciousPathPolicy"
        nonisolated static let symbolicLinkPolicy = "symbolicLinkPolicy"
        nonisolated static let activeContentOpenPolicy = "activeContentOpenPolicy"
        nonisolated static let confirmBeforeDeletingFiles = "confirmBeforeDeletingFiles"
        nonisolated static let showHiddenFiles = "showHiddenFiles"
        nonisolated static let showSymbolicLinks = "showSymbolicLinks"
        nonisolated static let followFinderStructure = "followFinderApplicationStructure"
        nonisolated static let hiddenSuffixesEnabled = "hiddenSuffixesEnabled"
        nonisolated static let hiddenRecommendedSuffixes = "hiddenRecommendedSuffixes"
        nonisolated static let hiddenCustomSuffixes = "hiddenCustomSuffixes"
        nonisolated static let rememberLastFolder = "rememberLastFolder"
        nonisolated static let lastFolderPath = "lastFolderPath"
        nonisolated static let showFileSizeColumn = "showFileSizeColumn"
        nonisolated static let showFileTypeColumn = "showFileTypeColumn"
        nonisolated static let showFileApplicationColumn = "showFileApplicationColumn"
        nonisolated static let showFileLastOpenedColumn = "showFileLastOpenedColumn"
        nonisolated static let showFileDateAddedColumn = "showFileDateAddedColumn"
        nonisolated static let showFileModifiedColumn = "showFileModifiedColumn"
        nonisolated static let showFileCreatedColumn = "showFileCreatedColumn"
        nonisolated static let showArchiveKindColumn = "showArchiveKindColumn"
        nonisolated static let showArchiveSizeColumn = "showArchiveSizeColumn"
        nonisolated static let showArchiveModifiedColumn = "showArchiveModifiedColumn"
        nonisolated static let showArchiveMethodColumn = "showArchiveMethodColumn"
        nonisolated static let appLanguage = "appLanguage"
        nonisolated static let sevenZipBackend = "sevenZipBackend"
        nonisolated static let rarBackend = "rarBackend"
        nonisolated static let pinnedSidebarPaths = "pinnedSidebarPaths"
        nonisolated static let recentSidebarPaths = "recentSidebarPaths"
        nonisolated static let fileColumnOrder = "fileColumnOrder"
        nonisolated static let archiveColumnOrder = "archiveColumnOrder"
        // 用户级便捷选项：
        // - finderOpenAutoExtract: Finder 双击打开压缩包时直接解压而不开浏览主窗口；
        // - presetPasswordEnabled: 「预设密码」开关，bool 放 UserDefaults 安全；
        //   实际密码内容存在 Keychain（见 PresetPasswordStore），不再放 UserDefaults。
        nonisolated static let finderOpenAutoExtract = "finderOpenAutoExtract"
        nonisolated static let presetPasswordEnabled = "presetPasswordEnabled"
        /// 欢迎助手是否已经完成过一次 —— 控制「首次启动自动弹」逻辑。
        /// 用户从「SimpleZip 菜单 → 重新运行欢迎助手」入口可以重置回 false 让它再弹一次。
        nonisolated static let welcomeAssistantCompleted = "welcomeAssistantCompleted"

        // GPG 集成主开关 —— 关 → 创建 / 解压 / 状态徽章里所有 GPG 入口隐藏；设置 pane 始终可见让用户能开它。
        nonisolated static let gpgEnabled = "gpgEnabled"
        // 智能卡 / OpenPGP 硬件 token 支持（GPG 高级特性，默认关）——
        // 多数用户不用智能卡，开启会显示「我的密钥（智能卡）」分组 + 「从智能卡导入公钥」按钮 + 一些卡相关错误提示。
        // 没有这把开关时如果用户的 keyring 里恰好有卡 stub，UI 仍然能看到（不会丢数据），只是不出现卡操作入口。
        nonisolated static let gpgSmartcardEnabled = "gpgSmartcardEnabled"
        // 默认签名密钥 fingerprint（40 字符 hex）—— 用户在 GPG 设置里手动指定。
        // 创建压缩包 / 签 .siz / 签 .szs 时若未显式选签名者，fallback 到这把。空 = 未设置，用 gpg default-key。
        nonisolated static let gpgDefaultSigningKeyFingerprint = "gpgDefaultSigningKeyFingerprint"
        // 签名密钥选择策略：false (默认) = 静默使用默认签名密钥；true = 每次创建压缩包时弹 picker 让用户选。
        // 多密钥用户（工作 / 私人 / 项目分别用不同 key）通常希望开启 ask 模式。单密钥用户保持静默更顺手。
        nonisolated static let gpgPromptForSigningKey = "gpgPromptForSigningKey"
    }

    nonisolated static var startupLocation: StartupLocation {
        StartupLocation(rawValue: defaults.string(forKey: Key.startupLocation) ?? "") ?? .home
    }

    nonisolated static var appLanguage: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
    }

    nonisolated static var overwriteBehavior: OverwriteBehavior {
        OverwriteBehavior(rawValue: defaults.string(forKey: Key.overwriteBehavior) ?? "") ?? .ask
    }

    nonisolated static var confirmBeforeDeletingFiles: Bool {
        defaultTrueBool(forKey: Key.confirmBeforeDeletingFiles)
    }

    nonisolated static var suspiciousPathPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.suspiciousPathPolicy) ?? "") ?? .ask
    }

    nonisolated static var symbolicLinkPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.symbolicLinkPolicy) ?? "") ?? .ask
    }

    nonisolated static var activeContentOpenPolicy: ArchiveSecurityDecision {
        ArchiveSecurityDecision(rawValue: defaults.string(forKey: Key.activeContentOpenPolicy) ?? "") ?? .ask
    }

    nonisolated static var sevenZipBackend: SevenZipBackendChoice {
        SevenZipBackendChoice(rawValue: defaults.string(forKey: Key.sevenZipBackend) ?? "") ?? .automatic
    }

    nonisolated static var rarBackend: RarBackendChoice {
        RarBackendChoice(rawValue: defaults.string(forKey: Key.rarBackend) ?? "") ?? .automatic
    }

    nonisolated static var showHiddenFiles: Bool {
        defaults.bool(forKey: Key.showHiddenFiles)
    }

    nonisolated static var showSymbolicLinks: Bool {
        defaultTrueBool(forKey: Key.showSymbolicLinks)
    }

    nonisolated static var followFinderStructure: Bool {
        defaults.bool(forKey: Key.followFinderStructure)
    }

    nonisolated static var hiddenSuffixesEnabled: Bool {
        defaultTrueBool(forKey: Key.hiddenSuffixesEnabled)
    }

    nonisolated static let recommendedHiddenSuffixes = ["app", "prefPane", "framework", "bundle", "plugin"]

    nonisolated static var hiddenRecommendedSuffixes: [String] {
        if defaults.object(forKey: Key.hiddenRecommendedSuffixes) == nil {
            return recommendedHiddenSuffixes
        }
        let configured = normalizedHiddenSuffixes(defaults.stringArray(forKey: Key.hiddenRecommendedSuffixes) ?? [])
        return recommendedHiddenSuffixes.filter { configured.contains($0.lowercased()) }
    }

    nonisolated static var hiddenCustomSuffixes: [String] {
        let recommended = Set(recommendedHiddenSuffixes.map { $0.lowercased() })
        return normalizedHiddenSuffixes(defaults.stringArray(forKey: Key.hiddenCustomSuffixes) ?? [])
            .filter { !recommended.contains($0.lowercased()) }
    }

    nonisolated static var hiddenDisplaySuffixes: [String] {
        guard hiddenSuffixesEnabled else { return [] }
        return normalizedHiddenSuffixes(hiddenRecommendedSuffixes + hiddenCustomSuffixes)
    }

    nonisolated static var rememberLastFolder: Bool {
        if defaults.object(forKey: Key.rememberLastFolder) == nil {
            return true
        }
        return defaults.bool(forKey: Key.rememberLastFolder)
    }

    nonisolated static var showFileSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileSizeColumn)
    }

    nonisolated static var showFileTypeColumn: Bool {
        defaultTrueBool(forKey: Key.showFileTypeColumn)
    }

    nonisolated static var showFileApplicationColumn: Bool {
        defaultTrueBool(forKey: Key.showFileApplicationColumn)
    }

    nonisolated static var showFileLastOpenedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileLastOpenedColumn)
    }

    nonisolated static var showFileDateAddedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileDateAddedColumn)
    }

    nonisolated static var showFileModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileModifiedColumn)
    }

    nonisolated static var showFileCreatedColumn: Bool {
        defaultTrueBool(forKey: Key.showFileCreatedColumn)
    }

    nonisolated static var showArchiveKindColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveKindColumn)
    }

    nonisolated static var showArchiveSizeColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveSizeColumn)
    }

    nonisolated static var showArchiveModifiedColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveModifiedColumn)
    }

    nonisolated static var showArchiveMethodColumn: Bool {
        defaultTrueBool(forKey: Key.showArchiveMethodColumn)
    }

    nonisolated static var lastFolderURL: URL? {
        guard let path = defaults.string(forKey: Key.lastFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func rememberLastFolder(_ url: URL) {
        guard rememberLastFolder else { return }
        defaults.set(url.path, forKey: Key.lastFolderPath)
        rememberRecentFolder(url)
    }

    nonisolated static var pinnedSidebarURLs: [URL] {
        urls(forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static var recentSidebarURLs: [URL] {
        urls(forKey: Key.recentSidebarPaths)
    }

    nonisolated static func pinSidebarURL(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static func unpinSidebarURL(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = (defaults.stringArray(forKey: Key.pinnedSidebarPaths) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: Key.pinnedSidebarPaths)
    }

    nonisolated static func stringArray(forKey key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    nonisolated static func setStringArray(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    nonisolated static func setHiddenRecommendedSuffixes(_ value: [String]) {
        let configured = Set(normalizedHiddenSuffixes(value))
        defaults.set(
            recommendedHiddenSuffixes.filter { configured.contains($0.lowercased()) },
            forKey: Key.hiddenRecommendedSuffixes
        )
    }

    nonisolated static func setHiddenCustomSuffixes(_ value: [String]) {
        let blocked = Set(recommendedHiddenSuffixes.map { $0.lowercased() })
        defaults.set(
            normalizedHiddenSuffixes(value).filter { !blocked.contains($0.lowercased()) },
            forKey: Key.hiddenCustomSuffixes
        )
    }

    nonisolated static func normalizedHiddenSuffix(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        return result.lowercased()
    }

    /// Finder 双击 / Services 等外部入口打开压缩包时是否直接解压而不开浏览窗口。
    /// 默认关，遵循「不出意外行为」的原则。
    nonisolated static var finderOpenAutoExtract: Bool {
        defaults.bool(forKey: Key.finderOpenAutoExtract)
    }

    /// 是否启用「预设密码」便捷功能。开启后：
    /// 1) 创建压缩包时若选了加密会自动填入；
    /// 2) 打开 / 解压压缩包时会先用预设尝试一次，失败再弹密码框。
    nonisolated static var presetPasswordEnabled: Bool {
        defaults.bool(forKey: Key.presetPasswordEnabled)
    }

    /// 是否启用 GPG 集成功能（**主开关**）。关 → 创建对话框 / 打开压缩包流程 / 所有相关入口隐藏；
    /// 设置 → GPG pane 始终可见，让用户在里面开它。默认 false（首次用户不会被打扰）。
    nonisolated static var gpgEnabled: Bool {
        defaults.bool(forKey: Key.gpgEnabled)
    }

    /// 是否启用智能卡 / OpenPGP 硬件 token 支持。默认 false —— 多数用户不用卡，避免 UI 多一堆「卡上密钥」「从智能卡导入」入口让人困惑。
    /// 开启时 GPGPane 高级区出现智能卡相关按钮 + 卡 stub 密钥单独分组。
    nonisolated static var gpgSmartcardEnabled: Bool {
        defaults.bool(forKey: Key.gpgSmartcardEnabled)
    }

    /// 默认签名密钥 fingerprint（40 字符）。空 = 未设置（fallback 到 gpg default-key）。
    /// 写入：用户在 GPG pane 点「设为默认」时 set；点「清除」时 set 成空串。
    nonisolated static var gpgDefaultSigningKeyFingerprint: String {
        defaults.string(forKey: Key.gpgDefaultSigningKeyFingerprint) ?? ""
    }

    /// 签名密钥选择策略 —— false 静默用默认密钥 / true 每次创建压缩包时弹 picker。
    /// 默认 false（单密钥用户体验保持不变）；多密钥用户在 GPG pane → 默认值 子项里改成 true。
    nonisolated static var gpgPromptForSigningKey: Bool {
        defaults.bool(forKey: Key.gpgPromptForSigningKey)
    }

    /// 预设密码的实际内容。空字符串等于「未配置」。
    /// 存储已迁到 Keychain（见 `PresetPasswordStore`）。本属性是业务侧（创建/解压自动填）
    /// 的静默读取入口，不会触发 Touch ID。
    nonisolated static var presetPassword: String {
        PresetPasswordStore.load()
    }

    /// 「预设密码」便捷功能是否真的可用 —— 必须既开启又填了内容。
    /// UI 用这个属性灰按钮，业务层 (auto-fill / auto-try) 用这个判断是否走预设路径。
    nonisolated static var hasUsablePresetPassword: Bool {
        presetPasswordEnabled && !presetPassword.isEmpty
    }

    /// 返回 true 表示 Keychain 真的落盘成功。
    /// UI 必须根据返回值显示「保存成功 / 失败」 —— 旧版本无脑显示成功，
    /// 失败时下次启动 load 仍然为空，把失败伪装成成功。
    @discardableResult
    nonisolated static func setPresetPassword(_ value: String) -> Bool {
        PresetPasswordStore.save(value) == errSecSuccess
    }

    /// 返回 true 表示 Keychain 真的删除成功（含「本来就不存在」）。
    /// UI 必须根据返回值显示「清除成功 / 失败」 —— 删失败时不能让 UI 误以为已经清了，
    /// 否则下次启动旧密码还在但 UI 状态对不上。
    @discardableResult
    nonisolated static func clearPresetPassword() -> Bool {
        PresetPasswordStore.clear() == errSecSuccess
    }

    /// 欢迎助手是否完成过一次。
    /// false → 首次启动时 ContentView 自动弹起助手；
    /// true  → 不再自动弹，只在用户点「重新运行欢迎助手」时才打开。
    nonisolated static var welcomeAssistantCompleted: Bool {
        defaults.bool(forKey: Key.welcomeAssistantCompleted)
    }

    /// 助手走完最后一步 / 用户点「开始使用」时调用。
    nonisolated static func markWelcomeAssistantCompleted() {
        defaults.set(true, forKey: Key.welcomeAssistantCompleted)
    }

    /// 用户在设置里挑的「当前活跃」自定义启动路径。空表示尚未挑选。
    /// 也是 history 列表里被点亮的那一项 —— 二者保持一致。
    nonisolated static var startupCustomLocationURL: URL? {
        guard let path = defaults.string(forKey: Key.startupCustomLocationPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func setStartupCustomLocation(_ url: URL?) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: Key.startupCustomLocationPath)
        } else {
            defaults.removeObject(forKey: Key.startupCustomLocationPath)
        }
    }

    /// 用户挑过的所有 custom 路径，按 MRU 顺序。
    nonisolated static var startupCustomLocationHistory: [URL] {
        (defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// 把一个新 / 已有的 custom 路径加进历史并设为当前活跃。
    /// 行为：移到列表头部（最近使用），若超过 `keepingAtMost` 项就裁掉末尾。
    nonisolated static func recordCustomStartupLocation(_ url: URL, keepingAtMost limit: Int) {
        let canonical = url.standardizedFileURL.path
        var paths = (defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? [])
        paths.removeAll { $0 == canonical }
        paths.insert(canonical, at: 0)
        if paths.count > limit {
            paths = Array(paths.prefix(limit))
        }
        defaults.set(paths, forKey: Key.startupCustomLocationHistory)
        defaults.set(canonical, forKey: Key.startupCustomLocationPath)
    }

    /// 从历史里移除一条（用户主动「忘记」某条），同时若它是当前活跃的也顺手清掉。
    nonisolated static func removeCustomStartupLocation(_ url: URL) {
        let canonical = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Key.startupCustomLocationHistory) ?? []
        paths.removeAll { $0 == canonical }
        defaults.set(paths, forKey: Key.startupCustomLocationHistory)
        if defaults.string(forKey: Key.startupCustomLocationPath) == canonical {
            defaults.removeObject(forKey: Key.startupCustomLocationPath)
        }
    }

    /// 把启动配置恢复到默认（home）+ 清掉 custom 相关状态。
    /// 启动时弹窗里「重置」按钮、设置面板里未来可能的「恢复默认」入口都会用。
    // MARK: - 备份 / 还原

    /// 可以参与导出 / 导入 / 全部恢复默认的 key 名单。
    ///
    /// 故意手动登记 ——
    /// 1. 隐私字段（lastFolderPath / pinnedSidebarPaths / recentSidebarPaths）会暴露用户真实
    ///    本机路径，不导出；
    /// 2. 安全字段（旧版本可能存在的 legacy `presetPassword`）属于密码本身，绝不导出；
    /// 3. 导入时只接受登记过的 key，防止恶意 JSON 写不属于 SimpleZip 的 UserDefaults key
    ///    （比如 AppleLanguages 这种全局系统 key）。
    /// 添加新 settings key 时，记得来这里登记一下 + 同步更新 release-checklist.md。
    nonisolated static let exportableUserDefaultsKeys: [String] = [
        Key.appLanguage,
        Key.startupLocation,
        Key.startupCustomLocationPath,
        Key.startupCustomLocationHistory,
        Key.rememberLastFolder,
        Key.overwriteBehavior,
        Key.confirmBeforeDeletingFiles,
        Key.finderOpenAutoExtract,
        // 注意：只导 presetPasswordEnabled 开关，密码本身永远在 Keychain，不进导出文件。
        Key.presetPasswordEnabled,
        // GPG 集成主开关 + 智能卡支持开关 + 默认签名密钥 fingerprint；私钥 / 公钥都在 ~/.gnupg/ 或 SimpleZip 私有 ring，
        // 不进偏好导出文件。fingerprint 字符串属于「指向密钥的标识」，不是密钥本身，可导出。
        Key.gpgEnabled,
        Key.gpgSmartcardEnabled,
        Key.gpgDefaultSigningKeyFingerprint,
        Key.gpgPromptForSigningKey,
        Key.suspiciousPathPolicy,
        Key.symbolicLinkPolicy,
        Key.activeContentOpenPolicy,
        Key.sevenZipBackend,
        Key.rarBackend,
        Key.showHiddenFiles,
        Key.showSymbolicLinks,
        Key.followFinderStructure,
        Key.hiddenSuffixesEnabled,
        Key.hiddenRecommendedSuffixes,
        Key.hiddenCustomSuffixes,
        Key.showFileSizeColumn,
        Key.showFileTypeColumn,
        Key.showFileApplicationColumn,
        Key.showFileLastOpenedColumn,
        Key.showFileDateAddedColumn,
        Key.showFileModifiedColumn,
        Key.showFileCreatedColumn,
        Key.showArchiveKindColumn,
        Key.showArchiveSizeColumn,
        Key.showArchiveModifiedColumn,
        Key.showArchiveMethodColumn,
        Key.fileColumnOrder,
        Key.archiveColumnOrder
    ]

    /// 拼一份当前所有可导出 key 的 payload，可直接 JSONSerialization 序列化。
    nonisolated static func exportablePayload() -> [String: Any] {
        var values: [String: Any] = [:]
        for key in exportableUserDefaultsKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            }
        }
        return PreferencesPayloadCodec.makePayload(values: values)
    }

    /// 把一份外部 payload 写回 UserDefaults。
    ///
    /// 语义是「还原备份」，不是「打补丁」：先把所有白名单 key 抹掉，让没出现在 payload 里的
    /// 项目回落到代码默认值，再写 payload 里有的 key。
    /// 旧实现只覆盖 payload 里有的 key，没出现的就保留导入前的旧值，导致用户「换了一个
    /// 简化版备份」之后还是带着上次的零散设置，根本对不上备份原状态。
    /// 只接受白名单里的 key（防御 payload 里出现 AppleLanguages 这种全局系统 key）。
    /// 导入完成后调用方应让相关 UI 刷新。
    nonisolated static func importPayload(_ payload: [String: Any]) throws {
        let values = try PreferencesPayloadCodec.decode(payload)
        let allowed = Set(exportableUserDefaultsKeys)
        for key in exportableUserDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values where allowed.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    /// 把所有可导出 key 全部抹掉 + 顺手把 Keychain 里的预设密码也清掉。
    /// 「全部恢复默认」按钮调；用户应该被警告这是不可逆操作。
    nonisolated static func restoreAllDefaultsToFactory() {
        for key in exportableUserDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        PresetPasswordStore.clear()
    }

    nonisolated static func resetStartupLocationToDefault() {
        defaults.set(StartupLocation.home.rawValue, forKey: Key.startupLocation)
        defaults.removeObject(forKey: Key.startupCustomLocationPath)
        defaults.removeObject(forKey: Key.startupCustomLocationHistory)
    }

    /// 给定一个枚举 case，返回它对应的具体 URL（不带「不存在时回落到 home」语义）。
    /// .custom 用当前活跃 custom 路径，.lastFolder 用上次打开的文件夹。
    /// 返回 nil 表示对应的具体路径没配过 / 当前不可解析。
    nonisolated static func resolvedURL(for location: StartupLocation, fileManager: FileManager = .default) -> URL? {
        switch location {
        case .home:
            return fileManager.homeDirectoryForCurrentUser
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        case .movies:
            return fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
        case .music:
            return fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
        case .pictures:
            return fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .lastFolder:
            return lastFolderURL
        case .custom:
            return startupCustomLocationURL
        }
    }

    /// app 启动时校验：当前 startupLocation 是否指向一个不可达目录？
    /// .lastFolder 还没配过（首次启动）不算「失效」—— 静默回落到 home 即可，不打扰用户。
    /// 其它 case 路径配过但消失了 = 失效。
    nonisolated static var startupLocationIsMissing: Bool {
        let location = startupLocation
        switch location {
        case .lastFolder:
            guard let url = lastFolderURL else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        case .custom:
            guard let url = startupCustomLocationURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        default:
            guard let url = resolvedURL(for: location) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// 启动早期（`SimpleZipApp.init()`）调一次：把当前 `appLanguage` 偏好同步写到
    /// `AppleLanguages`，让 AppKit 在构造顶部菜单栏（File / Edit / Window / Help…）和
    /// Quit / Hide / Services 这些 native 项时就拿到正确语言。
    /// 用户在「通用 → 语言」里改值并重启后，下次启动这一步会用新值，菜单栏自然跟随。
    nonisolated static func applyAppleLanguagesOverrideAtLaunch() {
        let language = appLanguage
        if let code = language.appleLanguageCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            // .system 分支：清掉强制覆盖，让 AppKit 回到系统语言。
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    nonisolated static func defaultStartupURL(fileManager: FileManager = .default) -> URL {
        // 各分支统一回落到 home 目录 —— 即便对应系统目录被用户手动删了 / 自定义路径已经
        // 不存在了，app 也要起得来，而不是崩在「没法打开任何位置」。
        let fallback = fileManager.homeDirectoryForCurrentUser
        switch startupLocation {
        case .home:
            return fallback
        case .downloads:
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fallback
        case .desktop:
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fallback
        case .documents:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fallback
        case .movies:
            return fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fallback
        case .music:
            return fileManager.urls(for: .musicDirectory, in: .userDomainMask).first ?? fallback
        case .pictures:
            return fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first ?? fallback
        case .lastFolder:
            return lastFolderURL ?? fallback
        case .custom:
            // 自定义路径可能在用户改完之后又被外部删了 / 移走了；找不到时回落而不是报错。
            if let url = startupCustomLocationURL,
               fileManager.fileExists(atPath: url.path) {
                return url
            }
            return fallback
        }
    }

    private nonisolated static func defaultTrueBool(forKey key: String) -> Bool {
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    private nonisolated static func normalizedHiddenSuffixes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalizedHiddenSuffix(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private nonisolated static func rememberRecentFolder(_ url: URL) {
        var paths = defaults.stringArray(forKey: Key.recentSidebarPaths) ?? []
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(8)), forKey: Key.recentSidebarPaths)
    }

    private nonisolated static func urls(forKey key: String) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }
}
