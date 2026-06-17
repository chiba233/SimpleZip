//
//  AISettingsPane.swift
//  SimpleZip
//
//  0.4.5 #80:「AI 与智能建议」设置页(白皮书工程补充三「用户开关」/ 建议)。AI 功能的统一开关入口 ——
//  从「自动化」页搬来 AI 助手主开关(单一归属,不留两处),给 AI 一个独立的家,后续数据控制开关在此扩展。
//
//  A4 例外:本页是 AI 主开关的唯一开启入口,**始终可见**(关掉 AI 后主界面其它 AI 入口才隐藏,但这页要让用户能再开回来)。
//  复用现成的、**已接线**的控件与 L10n key —— 不在没有消费者时新增「空开关」(A8)。
//

import AppKit
import SwiftUI

struct AISettingsPane: View {
    /// AI 报告助手主开关。关 → 主界面所有 AI 入口隐藏(各处读 `AppPreferences.aiAssistantEnabled` / `AIReportAssistant.isReady`)。
    @AppStorage(AppPreferences.Key.aiAssistantEnabled) private var aiAssistant = true
    /// AI 建议子开关。关 → 文件浏览器 AI 抽屉不显示 + 后台自动总结模块停跑。
    @AppStorage(AppPreferences.Key.aiSuggestionEnabled) private var aiSuggestion = true

    var body: some View {
        Form {
            // AI 助手主开关 + 能力状态。开但模型不可用(旧系统 / 没开 Apple Intelligence / 没下完)→ 说明文案。
            Section(L10n.text("settings.automation.ai.section")) {
                SettingsToggleRow(
                    title: L10n.text("settings.automation.ai.title"),
                    description: L10n.text("settings.automation.ai.description"),
                    systemImage: "sparkles", iconTint: .purple,
                    isOn: $aiAssistant
                )
                if aiAssistant, !AIReportAssistant.isReady {
                    Text(AIReportAssistant.unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // AI 建议子开关(主开关开启时才显示)。关 → 文件浏览器抽屉不显示 + 后台自动总结停跑。
                if aiAssistant {
                    SettingsToggleRow(
                        title: L10n.text("settings.ai.suggestion.title"),
                        description: L10n.text("settings.ai.suggestion.desc"),
                        systemImage: "text.line.first.and.arrowtriangle.forward", iconTint: .purple,
                        isOn: $aiSuggestion
                    )
                }
            }
            .settingsAnchor("automation.ai")

            // 0.4.5 #89:后台发现与 opt-in 白名单文件预索引(AI 主开关开启时才显示)。
            if aiAssistant {
                AIBackgroundDiscoverySection()
            }

            // 隐私说明:AI 全部在本机运行,涉密内容绝不进入。文案复用现有键(本就全 10 语种)。
            Section(L10n.text("settings.ai.privacy.section")) {
                Label(L10n.text("settings.ai.privacy.note"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .settingsScrollAnchors()
    }
}
