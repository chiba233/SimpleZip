//
//  SettingsRowComponents.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 通用的「左侧标题 + 描述、右侧自定义控件」行。
///
/// 各 pane 几乎所有可选项都长这样，单独抽出一个组件可以：
/// 1) 保证不同 pane 之间留白、字号、对齐一致；
/// 2) 后续要做暗色模式或 Dynamic Type 调整时只改一处。
struct SettingsControlRow<Control: View>: View {
    let title: String
    let description: String
    var systemImage: String? = nil
    /// 一级行的彩色瓦片色;nil = 二级行单色(默认)。
    var iconTint: Color? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(systemImage: systemImage, tint: iconTint)

            VStack(alignment: .leading, spacing: 4) {
                // 0.3.3 设置右侧加深：标题升到正文字号、行距和上下留白放宽 ——
                // 跟系统设置的行密度对齐，不再挤成一团（用户点名「像老 macOS」的一部分）。
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            control()
        }
        .padding(.vertical, 6)
    }
}

/// 右侧固定是开关的快捷版本。
///
/// 直接复用 `SettingsControlRow` 的布局，避免之前两个组件里各写一份 HStack/VStack 而出现样式漂移。
struct SettingsToggleRow: View {
    let title: String
    let description: String
    var systemImage: String? = nil
    /// 一级行的彩色瓦片色;nil = 二级行单色(默认)。
    var iconTint: Color? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(title: title, description: description, systemImage: systemImage, iconTint: iconTint) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                // System Settings 同款小型 switch —— macOS Form 默认的 checkbox 是「老 macOS 感」
                // 的最大来源（用户点名）。一处改，全部 pane 的开关行生效。
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 带左侧图标 + 右侧按钮的操作行（例如「打开 README」「安装 RAR」）。
///
/// 因为左侧多一个 icon、整体高度更大，没法直接复用 `SettingsControlRow`，单独保留。
struct SettingsActionRow: View {
    let title: String
    let description: String
    let systemImage: String
    /// 一级行的彩色瓦片色;nil = 二级行单色(默认)。右侧按钮图标始终单色(规范)。
    var iconTint: Color? = nil
    let buttonTitle: String
    var role: ButtonRole?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(systemImage: systemImage, tint: iconTint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button(role: role, action: action) {
                Label(buttonTitle, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled)
        }
        .padding(.vertical, 7)
    }
}

struct SettingsRowIcon: View {
    let systemImage: String?
    /// 非 nil = **一级行**的彩色瓦片(纯色平涂 + 白色符号;box 不渐变是硬规矩);nil = **二级行**单色图标。
    var tint: Color? = nil

    var body: some View {
        Group {
            if let systemImage {
                if let tint {
                    // shape + overlay:符号在瓦片内绝对居中(直接给 Image 套 frame+background 会随字形偏移看着歪)。
                    // 饱和度压一档(0.75):侧栏图标保持高饱和,内容区行瓦片柔和一些 —— 用户拍板的层次。
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint)
                        .saturation(0.75)
                        .overlay(
                            Image(systemName: systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 22, alignment: .center)
        .accessibilityHidden(systemImage == nil)
    }
}
