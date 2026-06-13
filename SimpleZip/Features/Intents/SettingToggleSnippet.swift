//
//  SettingToggleSnippet.swift
//  SimpleZip
//
//  0.4.4 #31:macOS 26「交互式 snippet」—— 在 Spotlight 里搜一个安全布尔设置,运行后浮出一张卡片,
//  卡片里有一个**真开关**,点一下就地翻转、卡片原地刷新成新状态,全程不打开 app、不离开 Spotlight。
//
//  仅 macOS 26+(`SnippetIntent` / 交互式 snippet 的下限);旧系统上这些类型不参与编译路径(整文件 @available 门控),
//  Siri 直接开关(ChangeSettingIntent,#31 主体)与「点结果跳到设置」(#30)仍是全系统可用的回退。
//
//  红线不变:参数类型是 `ToggleableSettingEntity`(只含 isToggleable 项),翻转走同一个三道闸的
//  `SettingToggleRegistry`,安全 / 破坏类设置永远进不来。
//

import AppIntents
import SwiftUI

// MARK: - 交互式 snippet 本体(运行后展示带开关的卡片)

@available(macOS 26.0, *)
struct SettingSwitchSnippet: SnippetIntent {
    static let title: LocalizedStringResource = "Setting Switch"

    @Parameter(title: "Setting")
    var setting: ToggleableSettingEntity

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: SettingSwitchSnippetView(setting: setting))
    }
}

// MARK: - 卡片里的开关按钮所触发的翻转动作(翻转 + 让 snippet 重新渲染)

/// 不可发现(`isDiscoverable = false`)—— 它只是 snippet 卡片里那个开关按钮的后端,不单独出现在 Shortcuts 列表。
@available(macOS 26.0, *)
struct FlipSettingSwitchIntent: AppIntent {
    static let title: LocalizedStringResource = "Flip Setting"
    static let isDiscoverable = false

    @Parameter(title: "Setting")
    var setting: ToggleableSettingEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // 复核闸:只认 registry 给得出访问器的(= 目录里 isToggleable)项,否则不动任何值。
        if let accessor = SettingToggleRegistry.accessor(for: setting.id) {
            accessor.set(!accessor.get())
        }
        // 让卡片重新渲染,读到翻转后的新状态。
        SettingSwitchSnippet.reload()
        return .result()
    }
}

// MARK: - 卡片视图

@available(macOS 26.0, *)
struct SettingSwitchSnippetView: View {
    let setting: ToggleableSettingEntity

    var body: some View {
        let isOn = SettingToggleRegistry.accessor(for: setting.id)?.get() ?? false
        HStack(spacing: 12) {
            Image(systemName: "switch.2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(setting.name)
                    .font(.headline)
                    .lineLimit(2)
                if let paneTitle = SettingsPane(rawValue: setting.paneRaw)?.title {
                    Text(paneTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            // 真开关:点一下走 FlipSettingSwitchIntent 翻转 + reload,卡片刷新成新状态。
            Button(intent: flipIntent) {
                switchGraphic(isOn: isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(setting.name)
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .padding(14)
    }

    private var flipIntent: FlipSettingSwitchIntent {
        let intent = FlipSettingSwitchIntent()
        intent.setting = setting
        return intent
    }

    private func switchGraphic(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 46, height: 28)
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .padding(3)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}
