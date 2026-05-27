//
//  L10n.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import Foundation

/// 本地化工具：统一封装字符串读取和带参数格式化，避免界面里直接散落 key。
enum L10n {
    nonisolated static func text(_ key: String) -> String {
        if let bundle = selectedLanguageBundle {
            let localized = NSLocalizedString(key, bundle: bundle, comment: "")
            if localized != key {
                return localized
            }
        }
        let localized = NSLocalizedString(key, comment: "")
        if localized != key {
            return localized
        }
        return NSLocalizedString(key, bundle: englishBundle ?? .main, comment: "")
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    private nonisolated static var selectedLanguageBundle: Bundle? {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        guard let language = AppLanguage(rawValue: rawValue), let code = language.localizationCode else {
            return nil
        }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    private nonisolated static var englishBundle: Bundle? {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
