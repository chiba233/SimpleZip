//
//  DialogChrome.swift
//  SimpleZip
//
//  0.4.1 弹窗体例的共享组件：创建 / 解压 / 权限等 sheet 共用。
//  为什么不用 Form(.grouped)：grouped Form 底下是 List，**贪婪布局** —— sheet 必须写死高度，
//  内容短时下面一大片固定空白（用户点名的问题）。这里手绘同款分区卡片外观，高度贴内容。
//

import SwiftUI

/// 弹窗顶部 hero：渐变图标瓦片 + 标题 + 可选副标题。
struct DialogHero: View {
    let systemImage: String
    let colors: [Color]
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

/// 弹窗分区卡片：小节标题 + 圆角卡片，视觉对齐系统设置的 grouped form，但高度自适应内容。
struct DialogSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
            // 行间距放宽到 16(原 12)—— 用户报「间距太小、重叠」。卡片内边距同步加大。
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
    }
}

/// 抽屉分区：不常用选项收进可展开的卡片（默认收起）—— 保护常用路径的界面密度。
/// 头部 = 彩色小图标 + 标题 + 旋转 chevron；展开后内容在同一张卡片里。
struct DialogDrawer<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    @State private var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        systemImage: String,
        color: Color,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(title)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

/// 弹窗钉底操作栏：bar 材质，左侧自定义内容（详情开关 / 校验信息），右侧取消 + prominent 主按钮。
struct DialogFooter<Leading: View>: View {
    let confirmTitle: String
    let confirmDisabled: Bool
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack {
            leading()
            Spacer()
            Button(L10n.text("button.cancel"), action: cancel)
            Button(confirmTitle, action: confirm)
                .buttonStyle(.borderedProminent)
                .disabled(confirmDisabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
