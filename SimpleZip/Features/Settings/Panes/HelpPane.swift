//
//  HelpPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2「设置 → 帮助」：图文并茂的使用指南，活动中心的「帮助」大项也渲染同一个视图（不重画）。
//  0.4.3 改造:主题卡按功能分类收进抽屉;贴士覆盖新功能。
//  视觉:帮助页用**自己的** HelpDrawer(不动公共 DialogDrawer)——外层按分类色做渐变叠层、
//  渐变描边与彩色阴影,内层主题卡保持实底,层次一眼分明;展开收起走弹簧 + 内容淡入上移,
//  卡片悬停轻浮起,hero 图标带缓慢旋转的渐变光环。仅此页放开手绘限制。
//

import SwiftUI

/// 帮助主题卡的数据：key 决定 L10n（`help.topic.<key>.title` / `.body`），图标 + 渐变色自带。
private struct HelpTopic: Identifiable {
    let key: String
    let systemImage: String
    let colors: [Color]
    var id: String { key }

    var title: String { L10n.text("help.topic.\(key).title") }
    var body: String { L10n.text("help.topic.\(key).body") }
}

/// 功能分类:一个抽屉一类,抽屉里是该类的主题卡。顺序 = 页面顺序,按使用旅程排。
private struct HelpCategory: Identifiable {
    let key: String
    let systemImage: String
    let color: Color
    let topics: [HelpTopic]
    var id: String { key }

    var title: String { L10n.text("help.category.\(key)") }

    static let all: [HelpCategory] = [
        HelpCategory(key: "basics", systemImage: "archivebox", color: .blue, topics: [
            HelpTopic(key: "open", systemImage: "archivebox", colors: [.blue, .cyan]),
            HelpTopic(key: "extract", systemImage: "arrow.down.doc", colors: [.green, .teal]),
            HelpTopic(key: "fastExtract", systemImage: "bolt", colors: [.yellow, .orange]),
            HelpTopic(key: "webExtract", systemImage: "arrow.down.circle", colors: [.blue, .indigo]),
            HelpTopic(key: "create", systemImage: "plus.square.on.square", colors: [.orange, .yellow]),
            HelpTopic(key: "edit", systemImage: "pencil.and.outline", colors: [.purple, .indigo]),
            HelpTopic(key: "search", systemImage: "magnifyingglass", colors: [.pink, .orange]),
            HelpTopic(key: "dmg", systemImage: "externaldrive", colors: [.gray, .blue]),
            HelpTopic(key: "splitMerge", systemImage: "square.split.2x1", colors: [.brown, .orange])
        ]),
        HelpCategory(key: "verify", systemImage: "checkmark.seal", color: .green, topics: [
            HelpTopic(key: "checksums", systemImage: "number.square", colors: [.green, .mint]),
            HelpTopic(key: "inspect", systemImage: "checklist", colors: [.teal, .green]),
            HelpTopic(key: "release", systemImage: "shippingbox.and.arrow.backward", colors: [.cyan, .blue]),
            HelpTopic(key: "reproducible", systemImage: "arrow.triangle.2.circlepath", colors: [.mint, .teal]),
            HelpTopic(key: "releaseDir", systemImage: "folder.badge.questionmark", colors: [.indigo, .purple])
        ]),
        HelpCategory(key: "analyze", systemImage: "chart.pie", color: .indigo, topics: [
            HelpTopic(key: "analyze", systemImage: "chart.pie", colors: [.indigo, .purple]),
            HelpTopic(key: "presets", systemImage: "wand.and.stars", colors: [.purple, .pink]),
            HelpTopic(key: "duplicates", systemImage: "doc.on.doc", colors: [.teal, .blue]),
            HelpTopic(key: "salvage", systemImage: "cross.case", colors: [.red, .orange])
        ]),
        HelpCategory(key: "ai", systemImage: "sparkles", color: .purple, topics: [
            HelpTopic(key: "aiSuggestions", systemImage: "sparkles", colors: [.purple, .pink]),
            HelpTopic(key: "aiAssist", systemImage: "wand.and.stars", colors: [.indigo, .purple]),
            HelpTopic(key: "aiBackground", systemImage: "clock.arrow.2.circlepath", colors: [.pink, .orange])
        ]),
        HelpCategory(key: "safety", systemImage: "shield.lefthalf.filled", color: .orange, topics: [
            HelpTopic(key: "metadata", systemImage: "doc.badge.gearshape", colors: [.brown, .orange]),
            HelpTopic(key: "safety", systemImage: "shield.lefthalf.filled", colors: [.orange, .red]),
            HelpTopic(key: "sign", systemImage: "signature", colors: [.teal, .green]),
            HelpTopic(key: "sensitiveFiles", systemImage: "eye.trianglebadge.exclamationmark", colors: [.yellow, .orange])
        ]),
        HelpCategory(key: "automation", systemImage: "terminal", color: .gray, topics: [
            HelpTopic(key: "cli", systemImage: "terminal", colors: [.gray, .blue]),
            HelpTopic(key: "tasks", systemImage: "list.bullet.rectangle", colors: [.gray, .blue]),
            HelpTopic(key: "shortcuts", systemImage: "rectangle.stack", colors: [.pink, .purple]),
            HelpTopic(key: "spotlight", systemImage: "magnifyingglass.circle", colors: [.orange, .yellow]),
            HelpTopic(key: "finderExtension", systemImage: "finder", colors: [.blue, .cyan])
        ]),
        HelpCategory(key: "settings", systemImage: "gearshape.2", color: .teal, topics: [
            HelpTopic(key: "settingsGeneral", systemImage: "switch.2", colors: [.gray, .blue]),
            HelpTopic(key: "settingsCompression", systemImage: "rectangle.compress.vertical", colors: [.orange, .yellow]),
            HelpTopic(key: "settingsBrowser", systemImage: "list.bullet", colors: [.blue, .cyan]),
            HelpTopic(key: "settingsAssociations", systemImage: "link", colors: [.green, .mint]),
            HelpTopic(key: "settingsGPG", systemImage: "key", colors: [.purple, .indigo]),
            HelpTopic(key: "settingsUpdates", systemImage: "arrow.down.circle.dotted", colors: [.teal, .green]),
            HelpTopic(key: "settingsHealth", systemImage: "stethoscope", colors: [.red, .pink]),
            HelpTopic(key: "settingsBackup", systemImage: "arrow.triangle.pull", colors: [.brown, .orange])
        ])
    ]
}

/// 「设置 → 帮助」/ 活动中心「帮助」共用的内容页。
struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HelpHero()
                    .padding(.bottom, 6)

                // 首要内容：格式能力表 —— 自己一个抽屉,默认展开。
                HelpDrawer(
                    title: L10n.text("settings.formatMatrix.title"),
                    systemImage: "tablecells",
                    color: .blue,
                    initiallyExpanded: true
                ) {
                    Text(L10n.text("settings.formatMatrix.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FormatCapabilityMatrixView()
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06))
                        )
                }

                // 功能分类抽屉:每类一个抽屉,里面是该类的主题卡(自适应两列)。
                ForEach(HelpCategory.all) { category in
                    HelpDrawer(
                        title: category.title,
                        systemImage: category.systemImage,
                        color: category.color
                    ) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 330), spacing: 12, alignment: .top)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(category.topics) { topic in
                                HelpTopicCard(topic: topic)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 页头:救生圈 hero。无光环(旋转动画触发闪烁,静态环被裁掉)——渐变瓦片 + 彩色阴影足矣。
private struct HelpHero: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lifepreserver")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .shadow(color: .blue.opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("settings.section.help"))
                    .font(.title.weight(.bold))
                Text(L10n.text("help.intro"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 帮助页专属抽屉(不复用公共 DialogDrawer —— 这页放开手绘):
/// 外层 = 分类色渐变底 + 顶部高光 + 渐变描边 + 彩色阴影;头部大瓦片带同色光晕;
/// 展开 = 弹簧 + 内容淡入上移;悬停整体轻浮起。内层主题卡是实底,层次一眼分明。
private struct HelpDrawer<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    @State private var isExpanded: Bool
    @State private var isHovering = false
    @ViewBuilder let content: () -> Content

    init(
        title: String,
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
                // 展开收起用克制的 easeInOut:弹簧 + scale/move 组合转场在 ScrollView 里
                // 会跟 LazyVGrid 布局打架,出现鬼畜。
                withAnimation(.easeInOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            LinearGradient(
                                colors: [color.opacity(0.95), color.opacity(0.65)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .shadow(color: color.opacity(0.45), radius: 7, y: 3)
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(color.opacity(0.14)))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .background(
            ZStack {
                // 第一层:分类色斜向渐变底。
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.16), color.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                // 第二层:顶部白色高光,做出「玻璃面」的厚度。
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            }
        )
        .overlay(
            // 第三层:同色渐变描边,亮起在左上、隐没在右下。
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [color.opacity(0.55), color.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        // 悬停只动阴影,不缩放 —— 容器 scaleEffect 会逼 LazyVGrid 重排,同样鬼畜。
        .shadow(color: color.opacity(isExpanded || isHovering ? 0.22 : 0.10), radius: isExpanded ? 13 : 7, y: 5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }
}

/// 一张帮助主题卡：渐变图标瓦片 + 标题 + 多行教学文案（• 步骤在 L10n 字符串里换行排）。
/// 实底卡放在渐变抽屉里,内外层次一眼分明;悬停轻浮起。
private struct HelpTopicCard: View {
    let topic: HelpTopic
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: topic.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(colors: topic.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .shadow(color: (topic.colors.first ?? .blue).opacity(0.35), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.headline)
                Text(topic.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.12 : 0.06))
        )
        .shadow(color: .black.opacity(isHovering ? 0.10 : 0.04), radius: isHovering ? 7 : 3, y: 2)
        .scaleEffect(isHovering ? 1.008 : 1)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }
}
