//
//  BackendStatusBadge.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI

/// 「后端是否就绪」高对比度状态条。
///
/// 跟 macOS Settings 里 Privacy & Security 行的红 / 绿状态条同款语义强度 —— 大字号 + 高饱和色 + filled icon，
/// 让用户「一眼看出装好没」。SettingsControlRow 的灰字 caption 在状态判断场景下视觉权重太低，故抽出本组件。
///
/// 同一组件被 Welcome assistant 的后端步骤（`.prominent` 带圆角背景突出）和 Settings → GPG / RAR 的
/// 后端徽章（`.compact` 紧凑无背景嵌进 Form）共用。
struct BackendStatusBadge: View {
    enum Style {
        /// 紧凑：font 16 + 无背景，嵌进 SettingsForm Section 用。
        case compact
        /// 突出：font 18 + 圆角填充背景，作为独立卡片用（欢迎助手）。
        case prominent
    }

    let isOk: Bool
    let okText: String
    let failText: String
    var style: Style = .compact

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint)
            Text(isOk ? okText : failText)
                .font(textFont)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(backgroundShape)
    }

    private var tint: Color { isOk ? .green : .orange }

    private var iconSize: CGFloat { style == .prominent ? 18 : 16 }

    private var textFont: Font {
        style == .prominent ? .body.weight(.semibold) : .callout.weight(.semibold)
    }

    private var verticalPadding: CGFloat { style == .prominent ? 6 : 4 }
    private var horizontalPadding: CGFloat { style == .prominent ? 10 : 0 }

    @ViewBuilder
    private var backgroundShape: some View {
        if style == .prominent {
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.12))
        }
    }
}
