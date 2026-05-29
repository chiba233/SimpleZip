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
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            control()
        }
        .padding(.vertical, 3)
    }
}

/// 右侧固定是开关的快捷版本。
///
/// 直接复用 `SettingsControlRow` 的布局，避免之前两个组件里各写一份 HStack/VStack 而出现样式漂移。
struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(title: title, description: description) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
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
    let buttonTitle: String
    var role: ButtonRole?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
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
        .padding(.vertical, 5)
    }
}
