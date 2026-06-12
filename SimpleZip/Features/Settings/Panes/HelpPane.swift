//
//  HelpPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2「设置 → 帮助」：图文并茂的使用指南，活动中心的「帮助」大项也渲染同一个视图（不重画）。
//  0.4.3 改造(用户点名「乱七八糟」):主题卡按功能**分类**收进 DialogDrawer 抽屉(design system
//  组件,与创建对话框「高级选项」同款),首屏只剩页头 + 格式能力表抽屉 + 分类抽屉列表;
//  贴士覆盖 0.4.3 新功能(校验/发布工作流/分析工具/预设/CLI 与 URL scheme/自检)。
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
            HelpTopic(key: "create", systemImage: "plus.square.on.square", colors: [.orange, .yellow]),
            HelpTopic(key: "edit", systemImage: "pencil.and.outline", colors: [.purple, .indigo]),
            HelpTopic(key: "search", systemImage: "magnifyingglass", colors: [.pink, .orange])
        ]),
        HelpCategory(key: "verify", systemImage: "checkmark.seal", color: .green, topics: [
            HelpTopic(key: "checksums", systemImage: "number.square", colors: [.green, .mint]),
            HelpTopic(key: "inspect", systemImage: "checklist", colors: [.teal, .green]),
            HelpTopic(key: "release", systemImage: "shippingbox.and.arrow.backward", colors: [.cyan, .blue])
        ]),
        HelpCategory(key: "analyze", systemImage: "chart.pie", color: .indigo, topics: [
            HelpTopic(key: "analyze", systemImage: "chart.pie", colors: [.indigo, .purple]),
            HelpTopic(key: "presets", systemImage: "wand.and.stars", colors: [.purple, .pink])
        ]),
        HelpCategory(key: "safety", systemImage: "shield.lefthalf.filled", color: .orange, topics: [
            HelpTopic(key: "metadata", systemImage: "doc.badge.gearshape", colors: [.brown, .orange]),
            HelpTopic(key: "safety", systemImage: "shield.lefthalf.filled", colors: [.orange, .red]),
            HelpTopic(key: "sign", systemImage: "signature", colors: [.teal, .green])
        ]),
        HelpCategory(key: "automation", systemImage: "terminal", color: .gray, topics: [
            HelpTopic(key: "cli", systemImage: "terminal", colors: [.gray, .blue]),
            HelpTopic(key: "tasks", systemImage: "list.bullet.rectangle", colors: [.gray, .blue])
        ])
    ]
}

/// 「设置 → 帮助」/ 活动中心「帮助」共用的内容页。
struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 页头：救生圈 hero + 一句话定位。
                HStack(spacing: 14) {
                    Image(systemName: "lifepreserver")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
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
                .padding(.bottom, 8)

                // 首要内容（用户点名）：格式能力表 —— 自己一个抽屉,默认展开。
                DialogDrawer(
                    L10n.text("settings.formatMatrix.title"),
                    systemImage: "tablecells",
                    color: .blue,
                    initiallyExpanded: true
                ) {
                    Text(L10n.text("settings.formatMatrix.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FormatCapabilityMatrixView()
                }

                // 功能分类抽屉:每类一个抽屉,里面是该类的主题卡(自适应两列)。
                ForEach(HelpCategory.all) { category in
                    DialogDrawer(category.title, systemImage: category.systemImage, color: category.color) {
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

/// 一张帮助主题卡：渐变图标瓦片 + 标题 + 多行教学文案（• 步骤在 L10n 字符串里换行排）。
private struct HelpTopicCard: View {
    let topic: HelpTopic

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
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}
