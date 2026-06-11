//
//  HelpPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2「设置 → 帮助」：图文并茂的使用指南，活动中心的「帮助」大项也渲染同一个视图（不重画）。
//  首要内容 = 格式能力表（用户点名从「压缩」pane 搬来）；其后是七张主题卡（图标 + 步骤式文案），
//  排版刻意宽松 —— 教学页要好读，不追求信息密度。
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

    /// 顺序就是页面顺序：从「打开」到「活动中心」，按用户的使用旅程排。
    static let all: [HelpTopic] = [
        HelpTopic(key: "open", systemImage: "archivebox", colors: [.blue, .cyan]),
        HelpTopic(key: "extract", systemImage: "arrow.down.doc", colors: [.green, .teal]),
        HelpTopic(key: "create", systemImage: "plus.square.on.square", colors: [.orange, .yellow]),
        HelpTopic(key: "edit", systemImage: "pencil.and.outline", colors: [.purple, .indigo]),
        // 0.4.3 #9:macOS 元数据策略(xattr / quarantine / Finder 标签 / resource fork / 权限)——
        // 内容逐条用捆绑 7zz 与系统 tar 实测过,改引擎行为时必须同步这页。
        HelpTopic(key: "metadata", systemImage: "doc.badge.gearshape", colors: [.brown, .orange]),
        HelpTopic(key: "search", systemImage: "magnifyingglass", colors: [.pink, .orange]),
        HelpTopic(key: "sign", systemImage: "signature", colors: [.teal, .green]),
        HelpTopic(key: "tasks", systemImage: "list.bullet.rectangle", colors: [.gray, .blue])
    ]
}

/// 「设置 → 帮助」/ 活动中心「帮助」共用的内容页。
struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
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

                // 首要内容（用户点名）：各格式支持什么操作、不支持时为什么 —— 点行可展开。
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("settings.formatMatrix.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.text("settings.formatMatrix.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FormatCapabilityMatrixView()
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06))
                        )
                }

                // 主题卡：自适应两列，宽松排版。
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("help.topics.title"))
                        .font(.title3.weight(.semibold))
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(HelpTopic.all) { topic in
                            HelpTopicCard(topic: topic)
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
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}
