//
//  RarInstallSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 触发安装或升级两种 review。
///
/// 用枚举区分而不是用 bool，是因为标题、按钮文案在两种路径下都不一样，
/// switch 比 if 更难漏改文案。
enum RarInstallAction: String, Identifiable {
    case install
    case update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install:
            return L10n.text("settings.rar.installReviewTitle")
        case .update:
            return L10n.text("settings.rar.updateReviewTitle")
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .install:
            return L10n.text("settings.rar.downloadAndInstall")
        case .update:
            return L10n.text("settings.rar.downloadAndUpdate")
        }
    }
}

/// 给 sheet 用的不可变载荷：包含动作类型 + 读到的协议 / README 原文。
///
/// 协议文本提前读出来一次再传进 sheet，避免 sheet 渲染过程中再去碰文件系统。
struct RarInstallReview: Identifiable {
    let id = UUID()
    let action: RarInstallAction
    let licenseText: String
    let readmeText: String
}

/// 协议 / README 滚动展示 + 「我已阅读」勾选。
///
/// 单独抽出是因为安装路径要同时展示两份文档，每份都要独立的「已阅读」状态，
/// 通过 @Binding 把状态交给 sheet 持有，避免组件内部重复维护。
struct RarInstallDocumentView: View {
    let title: String
    let text: String
    let checkboxTitle: String
    @Binding var isRead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HeightCappedScrollView(maxHeight: 540) {
                // 空字符串会让 Text 折叠成 0 行，给个空格保留最小高度。
                Text(text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary)
            }
            .frame(minHeight: 190)

            Toggle(checkboxTitle, isOn: $isRead)
        }
    }
}

/// 完整的 review sheet。
///
/// 把 sheet 抽到独立组件后，RarSection 只管「弹起 / 关闭」，
/// 文档展示和按钮 disabled 规则都收敛在这里。
struct RarInstallReviewSheet: View {
    let review: RarInstallReview
    let isInstalling: Bool
    let onCancel: () -> Void
    let onConfirm: (RarInstallAction) -> Void

    @State private var hasReadLicense = false
    @State private var hasReadReadme = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.action.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                RarInstallDocumentView(
                    title: L10n.text("settings.rar.licenseHeading"),
                    text: review.licenseText,
                    checkboxTitle: L10n.text("settings.rar.licenseReadCheckbox"),
                    isRead: $hasReadLicense
                )

                RarInstallDocumentView(
                    title: L10n.text("settings.rar.readmeHeading"),
                    text: review.readmeText,
                    checkboxTitle: L10n.text("settings.rar.readmeReadCheckbox"),
                    isRead: $hasReadReadme
                )
            }

            HStack {
                Spacer()
                Button(L10n.text("button.cancel"), action: onCancel)
                Button(review.action.confirmButtonTitle) {
                    onConfirm(review.action)
                }
                // 用户必须双勾才能确认 —— 协议没读就装下去会带来许可纠纷。
                .disabled(!hasReadLicense || !hasReadReadme || isInstalling)
            }
        }
        .padding(20)
        // sheet 是模态弹层，没有可拖动的窗口边来「涨到 idealHeight」，
        // 用 min/ideal 会被实际渲染成 minHeight，导致两份 ScrollView + 复选框 + 按钮行被裁。
        // 这里保留固定尺寸，跟重构前一致。
        .frame(width: 680)
    }
}
