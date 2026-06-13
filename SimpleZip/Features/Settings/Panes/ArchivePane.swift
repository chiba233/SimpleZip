//
//  ArchivePane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// 压缩相关偏好：解压安全策略 + 7-Zip 后端 + RAR 后端。
///
/// 这三块在视觉上是同一个 pane 的三个 Section，但行为差异很大：
/// - 安全策略：纯 @AppStorage，无副作用
/// - 7-Zip / RAR：需要异步探测版本、显示安装提示，所以独立成 section view
struct ArchivePane: View {
    @AppStorage(AppPreferences.Key.suspiciousPathPolicy) private var suspiciousPathPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.symbolicLinkPolicy) private var symbolicLinkPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.activeContentOpenPolicy) private var activeContentOpenPolicy = ArchiveSecurityDecision.ask.rawValue
    // 0.4.3 #7:写入后自动验证。改写族(高风险)默认开;创建/转换默认关(大包测试耗时)。
    @AppStorage(AppPreferences.Key.verifyAfterArchiveRewrite) private var verifyAfterArchiveRewrite = true
    @AppStorage(AppPreferences.Key.verifyAfterArchiveCreate) private var verifyAfterArchiveCreate = false

    /// 「复制 brew 命令」的反馈文案。两个后端共用一个 state，
    /// 因为用户一次只会盯着一处反馈，不需要拆成两份。
    @State private var systemInstallMessage: String?

    var body: some View {
        Form {
            securitySection

            // #115 按格式默认值：每格式一套完整可复用选项（新写的编辑器，不复用创建对话框 UI）。
            CompressionDefaultsSection()

            SevenZipBackendSection(systemInstallMessage: $systemInstallMessage)

            RarBackendSection(systemInstallMessage: $systemInstallMessage)
        }
        .formStyle(.grouped)
        .controlSize(.small)
        // #30:深链 / Spotlight 跳转能滚到本页某设置项并高亮。
        .settingsScrollAnchors()
    }

    private var securitySection: some View {
        Section(L10n.text("settings.section.security")) {
            Text(L10n.text("settings.security.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            securityPickerRow(
                title: L10n.text("settings.security.suspiciousPaths"),
                description: L10n.text("settings.security.suspiciousPaths.description"),
                systemImage: "exclamationmark.triangle", iconTint: .orange,
                selection: $suspiciousPathPolicy
            )

            securityPickerRow(
                title: L10n.text("settings.security.symbolicLinks"),
                description: L10n.text("settings.security.symbolicLinks.description"),
                systemImage: "link", iconTint: .purple,
                selection: $symbolicLinkPolicy
            )

            securityPickerRow(
                title: L10n.text("settings.security.activeContent"),
                description: L10n.text("settings.security.activeContent.description"),
                systemImage: "checkmark.shield", iconTint: .green,
                selection: $activeContentOpenPolicy
            )

            SettingsToggleRow(
                title: L10n.text("settings.verifyAfterRewrite"),
                description: L10n.text("settings.verifyAfterRewrite.description"),
                systemImage: "checkmark.seal", iconTint: .blue,
                isOn: $verifyAfterArchiveRewrite
            )
            .settingsAnchor("archive.verifyAfterRewrite")

            SettingsToggleRow(
                title: L10n.text("settings.verifyAfterCreate"),
                description: L10n.text("settings.verifyAfterCreate.description"),
                systemImage: "checkmark.seal.fill", iconTint: .indigo,
                isOn: $verifyAfterArchiveCreate
            )
            .settingsAnchor("archive.verifyAfterCreate")
        }
    }

    /// 三个安全策略的下拉是同一种结构，抽个小辅助避免重复代码。
    private func securityPickerRow(title: String, description: String, systemImage: String, iconTint: Color? = nil, selection: Binding<String>) -> some View {
        SettingsControlRow(title: title, description: description, systemImage: systemImage, iconTint: iconTint) {
            Picker("", selection: selection) {
                ForEach(ArchiveSecurityDecision.allCases) { decision in
                    Text(decision.title).tag(decision.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(minWidth: 160, alignment: .trailing)
        }
    }

}
