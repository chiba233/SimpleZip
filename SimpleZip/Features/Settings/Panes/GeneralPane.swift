//
//  GeneralPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 通用偏好：界面语言、启动位置、默认覆盖行为、删除前确认。
///
/// 设计上每个 pane 只持有自己用到的 @AppStorage：
/// SwiftUI 会自动让所有引用同一个 key 的视图共享值，不需要从父视图传 binding 下来，
/// 同时父 SettingsView 也不再被 30+ 个 @AppStorage 撑爆。
struct GeneralPane: View {
    @AppStorage(AppPreferences.Key.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.Key.startupLocation) private var startupLocation = StartupLocation.home.rawValue
    @AppStorage(AppPreferences.Key.rememberLastFolder) private var rememberLastFolder = true
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.ask.rawValue
    @AppStorage(AppPreferences.Key.confirmBeforeDeletingFiles) private var confirmBeforeDeletingFiles = true

    @State private var languageMessage: String?

    var body: some View {
        Form {
            Section(L10n.text("settings.section.general")) {
                SettingsControlRow(
                    title: L10n.text("settings.language"),
                    description: L10n.text("settings.language.description")
                ) {
                    Picker("", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // 之前是 .frame(width: 220)，长翻译会被截断。
                    // 改为 minWidth 后 Picker 会按内容自适应，同时不至于退化成极窄。
                    .frame(minWidth: 200, alignment: .trailing)
                    .onChange(of: appLanguage) { newValue in
                        applyLanguage(newValue)
                    }
                }

                if let languageMessage {
                    Text(languageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsControlRow(
                    title: L10n.text("settings.startupLocation"),
                    description: L10n.text("settings.startupLocation.description")
                ) {
                    Picker("", selection: $startupLocation) {
                        ForEach(StartupLocation.allCases) { location in
                            Text(location.title).tag(location.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.rememberLastFolder"),
                    description: L10n.text("settings.rememberLastFolder.description"),
                    isOn: $rememberLastFolder
                )
            }

            Section(L10n.text("settings.section.defaults")) {
                SettingsControlRow(
                    title: L10n.text("settings.overwriteBehavior"),
                    description: L10n.text("settings.overwriteBehavior.description")
                ) {
                    Picker("", selection: $overwriteBehavior) {
                        ForEach(OverwriteBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.confirmBeforeDeletingFiles"),
                    description: L10n.text("settings.confirmBeforeDeletingFiles.description"),
                    isOn: $confirmBeforeDeletingFiles
                )
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    /// 切换界面语言：写到 AppleLanguages、提示用户重启生效。
    ///
    /// `removeObject` 分支留给「跟随系统」选项 —— 让 AppleLanguages 回到系统默认。
    private func applyLanguage(_ rawValue: String) {
        let language = AppLanguage(rawValue: rawValue) ?? .system
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let restartHint = L10n.text("settings.languageRestartHint")
        DispatchQueue.main.async {
            languageMessage = restartHint
        }
    }
}
