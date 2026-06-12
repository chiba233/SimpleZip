//
//  DialogChrome.swift
//  SimpleZip
//
//  0.4.1 弹窗体例的共享组件：创建 / 解压 / 权限等 sheet 共用。
//  为什么不用 Form(.grouped)：grouped Form 底下是 List，**贪婪布局** —— sheet 必须写死高度，
//  内容短时下面一大片固定空白（用户点名的问题）。这里手绘同款分区卡片外观，高度贴内容。
//

import SwiftUI

/// 彩色图标瓦片(design system:IconTile)—— 圆角矩形底 + 居中白色 SF Symbol。
/// shape+overlay 结构保证宽字形也精确居中(设计准则);底色二选一:纯色(行级 22pt)或
/// 渐变(窗口层 44pt hero / 抽屉头)。降饱和版本属于设置/活动中心的侧栏窗口内容区,不在这里。
struct IconTile: View {
    enum Fill {
        case solid(Color)
        case gradient([Color])
        /// 单色系统渐变(`Color.gradient`,抽屉头在用)。
        case systemGradient(Color)
    }

    let systemImage: String
    let fill: Fill
    var size: CGFloat = 22
    /// 默认按行级瓦片(22pt → r6 / 图标 12);hero 等其他档位显式传,保持既有精确尺寸不漂移。
    var cornerRadius: CGFloat?
    var iconSize: CGFloat?

    var body: some View {
        shape
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: iconSize ?? 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var shape: some View {
        let rect = RoundedRectangle(cornerRadius: cornerRadius ?? 6, style: .continuous)
        switch fill {
        case .solid(let color):
            rect.fill(color)
        case .gradient(let colors):
            rect.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        case .systemGradient(let color):
            rect.fill(color.gradient)
        }
    }
}

/// 弹窗顶部 hero：渐变图标瓦片 + 标题 + 可选副标题。
/// 设计准则：hero 在窗口外层（不在卡片内），外层允许渐变；降饱和只属于带侧栏的窗口内容区。
struct DialogHero: View {
    let systemImage: String
    let colors: [Color]
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: systemImage, fill: .gradient(colors), size: 44, cornerRadius: 10, iconSize: 21)
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

/// 卡片内一级行的标签：彩色瓦片 + 标题（设计准则：一级行彩色瓦片；
/// 无侧栏的对话框不降饱和——降饱和只属于设置/活动中心这类带侧栏窗口的内容区）。
/// 预检概要那类信息行不用它，保持单色。`width` 给需要定宽对齐值列的行（解压对话框 180pt）。
struct DialogRowLabel: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    var width: CGFloat?

    init(_ title: String, subtitle: String? = nil, systemImage: String, tint: Color, width: CGFloat? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.width = width
    }

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemImage: systemImage, fill: .solid(tint))
            if let subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(title)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 卡片内一级开关行：彩色瓦片 + 标题(可带说明副标题)，复选框一律不靠左。
/// 默认**固定间距贴着文字**(创建对话框「使用已保存默认值」拍板)；带宽对齐值列的表单
/// (如创建 .szs)按需传 `pinsToTrailing: true` 钉到行尾——对齐方式看需求,用户原话。
struct DialogToggleRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    var pinsToTrailing: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DialogRowLabel(title, subtitle: subtitle, systemImage: systemImage, tint: tint)
            if pinsToTrailing {
                Spacer(minLength: 12)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 文本输入框在白色卡片上的描边增强 —— 系统 .roundedBorder 的浅灰描边几乎隐形
/// (用户报「密码输入框饱和度太低,几乎看不清」)。
extension View {
    func dialogFieldEmphasis() -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.22))
        )
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
                    IconTile(systemImage: systemImage, fill: .systemGradient(color))
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
                // 抽屉内容 = 二级，统一缩进 34（对齐设置区抽屉的层级制度）。
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .padding(.trailing, 18)
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

/// 层叠渐变手绘 chrome 卡(design system,0.4.4 #17):帮助页 / 欢迎助手 / 关于页的同款三层皮 ——
/// ① tint 斜向渐变底(0.16→0.05) ② 顶部白色高光(0.22→clear,玻璃厚度感) ③ 同色渐变描边
/// (1.2pt,亮左上隐右下),外加彩色软阴影。
/// **hover 是可选项且默认关**:高频重渲染的宿主(活动中心任务卡,progress 每秒多帧)绝不挂
/// hover @State;Help/Welcome/About 回迁时各自决定开不开。防抖动规则:本卡永不 scaleEffect、
/// 渐变层无动画 —— 纯静态绘制。
struct HeroChromeCard<Content: View>: View {
    let color: Color
    var cornerRadius: CGFloat = 18
    var enablesHover: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        // 用户拍板(0.4.4 #17 多轮):容器**纯色无任何渐变**——左深右浅的斜向渐变和白色高光层
        // 全部被「不是让你删渐变吗」打回;底色保持极浅,描边均匀同色。
        let card = content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(color.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 1.2)
            )
            .shadow(color: color.opacity(enablesHover && isHovering ? 0.16 : 0.06), radius: 7, y: 5)
        if enablesHover {
            card.onHover { hovering in
                withAnimation(.easeOut(duration: 0.18)) {
                    isHovering = hovering
                }
            }
        } else {
            card
        }
    }
}

/// 钉底操作栏的裸壳(design system:PinnedBottomBar):bar 材质 + 统一内边距(h20/v12),内容自定。
/// 标准「取消 + 确认」请用 DialogFooter;报告类弹窗(导出 / 过滤 / 复制 / 关闭)往里塞自己的控件,
/// 不再各写一份 padding / 材质。
struct PinnedBottomBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// 弹窗钉底操作栏：bar 材质，左侧自定义内容（详情开关 / 校验信息），右侧取消 + prominent 主按钮。
/// 设计准则：按钮带单色图标——取消统一 xmark，主操作图标由各对话框传（通常呼应 hero 图标）。
struct DialogFooter<Leading: View>: View {
    let confirmTitle: String
    var confirmSystemImage: String?
    let confirmDisabled: Bool
    /// 不可中断阶段(如 .szs 创建中,pinentry 已弹)把取消也禁掉。
    var cancelDisabled = false
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        PinnedBottomBar {
            leading()
            Spacer()
            Button(action: cancel) {
                Label(L10n.text("button.cancel"), systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .disabled(cancelDisabled)
            Button(action: confirm) {
                if let confirmSystemImage {
                    Label(confirmTitle, systemImage: confirmSystemImage)
                } else {
                    Text(confirmTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(confirmDisabled)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// 对话框骨架(design system:TaskDialogShell)—— hero + 内容滚动区 + Divider + 钉底操作栏,
/// 一个 sheet 一份声明,不再各自手拼 padding / Divider / footer(用户点名的病:
/// 「每个弹窗都差不多,但每个都自己写一份 padding / icon / color / footer」)。
/// 内容区自动带标准缩进(水平 20 / 底 16)与 18 行距;底栏即 DialogFooter(h20/v12 + .bar)。
struct TaskDialogShell<Content: View, FooterLeading: View>: View {
    let heroSystemImage: String
    let heroColors: [Color]
    let title: String
    var subtitle: String?
    var width: CGFloat = 560
    var maxContentHeight: CGFloat = 480
    let confirmTitle: String
    var confirmSystemImage: String?
    var confirmDisabled = false
    var cancelDisabled = false
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footerLeading: () -> FooterLeading

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(systemImage: heroSystemImage, colors: heroColors, title: title, subtitle: subtitle)
            HeightCappedScrollView(maxHeight: maxContentHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            DialogFooter(
                confirmTitle: confirmTitle,
                confirmSystemImage: confirmSystemImage,
                confirmDisabled: confirmDisabled,
                cancelDisabled: cancelDisabled,
                confirm: confirm,
                cancel: cancel,
                leading: footerLeading
            )
        }
        .frame(width: width)
    }
}

extension TaskDialogShell where FooterLeading == EmptyView {
    /// 无底栏左侧附件的常规形态。
    init(
        heroSystemImage: String,
        heroColors: [Color],
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 560,
        maxContentHeight: CGFloat = 480,
        confirmTitle: String,
        confirmSystemImage: String? = nil,
        confirmDisabled: Bool = false,
        confirm: @escaping () -> Void,
        cancel: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            heroSystemImage: heroSystemImage,
            heroColors: heroColors,
            title: title,
            subtitle: subtitle,
            width: width,
            maxContentHeight: maxContentHeight,
            confirmTitle: confirmTitle,
            confirmSystemImage: confirmSystemImage,
            confirmDisabled: confirmDisabled,
            confirm: confirm,
            cancel: cancel,
            content: content,
            footerLeading: { EmptyView() }
        )
    }
}

/// 高度贴内容、到上限才出现滚动的 ScrollView —— 报告类弹窗用。
/// 动机（0.4.2 用户报）：裸 ScrollView 是贪婪布局,内容短时弹窗下面一大片空白；
/// 这里量出内容实高,frame 取 min(内容, 上限)。
struct HeightCappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

/// HeightCappedScrollView 的内容实高 preference。泛型类型里不能放静态存储属性，所以独立在外。
private struct ContentHeightKey: PreferenceKey {
    nonisolated static let defaultValue: CGFloat = 0
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
