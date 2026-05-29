//
//  SettingsPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 设置窗口侧栏的分页。
///
/// 用枚举集中描述 pane 的标题、图标，避免 SettingsView 里到处散落 magic string。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case archive
    case browser
    case fileAssociations
    case columns
    case gpg
    case health
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return L10n.text("settings.section.general")
        case .archive:
            return L10n.text("settings.section.archive")
        case .browser:
            return L10n.text("settings.section.browser")
        case .fileAssociations:
            return L10n.text("settings.section.fileAssociations")
        case .columns:
            return L10n.text("settings.section.columns")
        case .gpg:
            return L10n.text("settings.section.gpg")
        case .health:
            return L10n.text("settings.section.health")
        case .backup:
            return L10n.text("settings.section.backup")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .archive:
            return "archivebox"
        case .browser:
            return "folder"
        case .fileAssociations:
            return "doc.badge.gearshape"
        case .columns:
            return "tablecells"
        case .gpg:
            return "key.fill"
        case .health:
            return "heart.text.square"
        case .backup:
            return "arrow.up.arrow.down.square"
        }
    }
}

/// 侧栏单个选项按钮。
///
/// 使用 `.accentColor` 语义色而非硬编码颜色，自动跟随系统强调色和深色模式。
struct SettingsPaneSidebarButton: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
        .help(pane.title)
    }
}
