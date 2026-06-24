//
//  SimpleZipAppIntents.swift
//  SimpleZip
//
//  Shortcuts / Siri 接入(App Intents)中**能在非沙箱宿主下正常工作**的那部分。
//
//  ⚠️ 拿外部文件(IntentFile)或回传值(ReturnsValue)的归档动作(解压/创建/哈希/测试/分析/
//  比较/搜索/检查/发布打包…)已全部移除:非沙箱宿主下结构性地回传失败(NSCocoaError 4101 ——
//  沙箱化的 Shortcuts runner 拿不到对非沙箱 app bundle 的 `app-sandbox.read` 读扩展,解不出
//  返回类型;`OpenIntent` 又只接 AppEntity、接不了 IntentFile,逐跳实测+本地公证均证实)。这些动作
//  改由 **URL scheme** 驱动(`simplezip://extract?path=…`,见 AppDelegate / SimpleZipURLCommand),
//  Shortcuts 用「打开 URL」即可,不经 App Intents、无 4101。
//
//  这里只留**不拿外部文件**的:开关设置(AppEntity)、按文件名找归档(String)。「在活动中心打开任务」
//  是 OpenIntent(在 ArchiveTaskEntity.swift,实测可正常通信)。
//
//  本地化口径:静态元数据(标题 / 参数名 / 描述)是字面 LocalizedStringResource ——
//  英文字面量即键,各 .lproj 补译,由系统按 Shortcuts 进程语言解析;运行期 dialog / 错误消息走
//  app 自己的 L10n(intent.* 键)。
//

import AppIntents
import Foundation

/// Intent 执行错误:消息原样展示给 Shortcuts 用户(已本地化)。
struct SimpleZipIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

// MARK: - 直接开关设置(0.4.4 #31)

/// 经 Siri / Spotlight **不打开 app** 直接开 / 关一个安全布尔设置。
///
/// 红线:参数类型是 `ToggleableSettingEntity`(只含 `isToggleable == true` 的目录项)——Siri / Shortcuts
/// 的参数选择面根本列不出安全 / 破坏类设置。perform 里再用 `SettingToggleRegistry.accessor` 复核一次;
/// 拿不到访问器(非白名单)就明确拒绝、绝不改任何值。口令 / 删除确认 / GPG 启用 / 路径策略永远改不到。
struct ChangeSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Change a Setting"
    static let description = IntentDescription(
        "Turns a SimpleZip setting on or off without opening the app. Only safe, convenience toggles can be changed this way — settings that affect deleting files, encryption or archive path safety are never voice-controllable."
    )

    @Parameter(title: "Setting")
    var setting: ToggleableSettingEntity

    @Parameter(title: "State", default: .toggle)
    var state: SettingToggleState

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$state) \(\.$setting)")
    }

    // 稳定返回契约(发版后不得改类型/语义):ReturnsValue<Bool> = 切换后的新状态;
    // dialog 用大白话确认「X 现在已开 / 关」。
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        // 复核闸:目录项存在且 isToggleable,且 registry 有访问器 —— 任一不满足就拒绝,绝不写任何值。
        guard let item = SettingsCatalog.item(id: setting.id), item.isToggleable,
              let accessor = SettingToggleRegistry.accessor(for: setting.id) else {
            throw SimpleZipIntentError(message: L10n.format("intent.setting.notToggleable", setting.name))
        }
        let newValue: Bool
        switch state {
        case .on: newValue = true
        case .off: newValue = false
        case .toggle: newValue = !accessor.get()
        }
        accessor.set(newValue)
        let stateWord = L10n.text(newValue ? "intent.setting.on" : "intent.setting.off")
        return .result(
            value: newValue,
            dialog: IntentDialog("\(L10n.format("intent.setting.result", setting.name, stateWord))")
        )
    }
}

// MARK: - Siri / Spotlight 建议

/// App Shortcuts:让三个 intent 不用用户手动建快捷指令就出现在 Shortcuts app /
/// Spotlight / Siri 建议里。`shortTitle` / `systemImageName` 形态的初始化器要 macOS 14;
/// macOS 13 上 intent 本身照常可用,只是不预注册建议。
@available(macOS 14.0, *)
struct SimpleZipAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 拿外部文件 / 回传值的归档动作(extract/create/test/verify/compare/search/inspect/
        // createReleasePackage…)已移除 —— 非沙箱宿主下回传必 4101,改由 URL scheme 驱动(simplezip://…)。
        // 这里只留不拿外部文件、能正常通信的:按文件名找归档、开关设置。
        AppShortcut(
            intent: FindArchiveContainingFileIntent(),
            phrases: [
                "Find which archive contains a file with \(.applicationName)",
                "Find an archive containing a file with \(.applicationName)"
            ],
            shortTitle: "Find Archive Containing File",
            systemImageName: "rectangle.and.text.magnifyingglass"
        )
        AppShortcut(
            intent: ChangeSettingIntent(),
            phrases: [
                "Change a \(.applicationName) setting",
                "Turn on a \(.applicationName) setting",
                "Turn off a \(.applicationName) setting",
                "Toggle a \(.applicationName) setting"
            ],
            shortTitle: "Change a Setting",
            systemImageName: "switch.2"
        )
        // #31 的 macOS 26 交互式 snippet(SettingSwitchSnippet)刻意不进这里:AppShortcutsBuilder 不支持
        // `if #available` 分支(会产出 [AppShortcut] 而非变参),而整个 provider 是 macOS 14 下限。
        // SnippetIntent 默认 isDiscoverable=true,系统会在 macOS 26 Spotlight / 快捷指令里自行收录它;
        // Siri 语音「开关设置」的短语已由上面的 ChangeSettingIntent 覆盖,无需在此重复。
    }
}
