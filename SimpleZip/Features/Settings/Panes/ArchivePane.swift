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

    /// 「复制 brew 命令」的反馈文案。两个后端共用一个 state，
    /// 因为用户一次只会盯着一处反馈，不需要拆成两份。
    @State private var systemInstallMessage: String?

    var body: some View {
        Form {
            securitySection

            SevenZipBackendSection(systemInstallMessage: $systemInstallMessage)

            RarBackendSection(systemInstallMessage: $systemInstallMessage)
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    private var securitySection: some View {
        Section(L10n.text("settings.section.security")) {
            Text(L10n.text("settings.security.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            securityPickerRow(
                title: L10n.text("settings.security.suspiciousPaths"),
                description: L10n.text("settings.security.suspiciousPaths.description"),
                selection: $suspiciousPathPolicy
            )

            securityPickerRow(
                title: L10n.text("settings.security.symbolicLinks"),
                description: L10n.text("settings.security.symbolicLinks.description"),
                selection: $symbolicLinkPolicy
            )

            securityPickerRow(
                title: L10n.text("settings.security.activeContent"),
                description: L10n.text("settings.security.activeContent.description"),
                selection: $activeContentOpenPolicy
            )
        }
    }

    /// 三个安全策略的下拉是同一种结构，抽个小辅助避免重复代码。
    private func securityPickerRow(title: String, description: String, selection: Binding<String>) -> some View {
        SettingsControlRow(title: title, description: description) {
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
