//
//  FinderServicesRegistry.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  Finder 右键服务（NSServices）的激活管理。macOS 对第三方服务**默认不激活**，
//  用户得去 系统设置 → 键盘 → 键盘快捷键 → 服务 手动勾选（用户反馈「这真的很蠢」）。
//  激活状态存在 `pbs` 偏好域的 `NSServicesStatus` 字典里，
//  键 = "bundleID - 菜单名 - message"（格式已对照本机 `defaults read pbs` 确认），
//  值带 enabled_context_menu / enabled_services_menu 两个位。
//  这里直接读写该字典并 NSUpdateDynamicServices() 让 pbs 立即重读 ——
//  与在系统设置里勾选完全等效，用户在 app 里就能选择激活哪些集成。
//

import AppKit

enum FinderServicesRegistry {
    struct Service: Identifiable {
        /// NSMessage（Info.plist 服务声明 + pbs 键的一部分）。
        let message: String
        /// NSMenuItem 的 default 串（pbs 键的一部分，**非本地化**，必须与 Info.plist 完全一致）。
        let menuName: String
        /// 设置行标题的 L10n key。
        let titleKey: String
        let systemImage: String
        var id: String { message }
    }

    /// 与 Info.plist NSServices 一一对应；菜单名是 pbs 键的组成部分，改 Info.plist 必须同步这里。
    static let services: [Service] = [
        Service(message: "addToArchiveFromFinder", menuName: "Add to Archive with SimpleZip", titleKey: "settings.finderService.addToArchive", systemImage: "plus.square.on.square"),
        Service(message: "extractFromFinder", menuName: "Extract with SimpleZip", titleKey: "settings.finderService.extract", systemImage: "arrow.down.doc"),
        Service(message: "createZipFromFinder", menuName: "Create ZIP with SimpleZip", titleKey: "settings.finderService.createZip", systemImage: "doc.zipper"),
        Service(message: "createSevenZipFromFinder", menuName: "Create 7z with SimpleZip", titleKey: "settings.finderService.createSevenZip", systemImage: "archivebox"),
        Service(message: "createTarGzFromFinder", menuName: "Create TAR.GZ with SimpleZip", titleKey: "settings.finderService.createTarGz", systemImage: "shippingbox"),
        Service(message: "calculateHashFromFinder", menuName: "Calculate Hash with SimpleZip", titleKey: "settings.finderService.hash", systemImage: "number.square")
    ]

    private static let pbsDomain = "pbs" as CFString
    private static let statusKey = "NSServicesStatus" as CFString

    private static func serviceKey(_ service: Service) -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "yumeka.SimpleZip-in-mac"
        return "\(bundleID) - \(service.menuName) - \(service.message)"
    }

    /// 该服务当前是否激活（出现在右键菜单）。pbs 里没有记录 = macOS 默认未激活 → false。
    static func isEnabled(_ service: Service) -> Bool {
        guard let status = CFPreferencesCopyAppValue(statusKey, pbsDomain) as? [String: Any],
              let entry = status[serviceKey(service)] as? [String: Any] else { return false }
        return (entry["enabled_context_menu"] as? Bool)
            ?? ((entry["enabled_context_menu"] as? Int).map { $0 != 0 })
            ?? false
    }

    /// 激活 / 停用一个服务并让 pbs 立即重读。右键菜单与服务菜单一起开关 —— 分开没有用户价值。
    static func setEnabled(_ enabled: Bool, for service: Service) {
        var status = (CFPreferencesCopyAppValue(statusKey, pbsDomain) as? [String: Any]) ?? [:]
        var entry = (status[serviceKey(service)] as? [String: Any]) ?? [:]
        entry["enabled_context_menu"] = enabled
        entry["enabled_services_menu"] = enabled
        entry["presentation_modes"] = [
            "ContextMenu": enabled,
            "ServicesMenu": enabled
        ]
        status[serviceKey(service)] = entry
        CFPreferencesSetAppValue(statusKey, status as CFDictionary, pbsDomain)
        CFPreferencesAppSynchronize(pbsDomain)
        NSUpdateDynamicServices()
    }
}
