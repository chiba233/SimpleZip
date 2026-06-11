//
//  AboutPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2「设置 → 关于」：替代系统标准 About 面板（菜单栏「关于 SimpleZip」重定向到这里）。
//  比系统面板能放下更多内容：大图标 + 渐变名字 + 版本胶囊 + 链接卡 + 第三方致谢，但仍保持克制 ——
//  不放滚动致谢长文，链接全部跳浏览器。
//

import AppKit
import SwiftUI

struct AboutPane: View {
    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("about.versionLine", short, build)
    }

    var body: some View {
        // 0.4.2 用户报「明明显示完整还有滚动条碍眼」：放得下直接铺,放不下才包 ScrollView。
        ViewThatFits(in: .vertical) {
            aboutContent
            ScrollView {
                aboutContent
            }
        }
    }

    private var aboutContent: some View {
            VStack(spacing: 0) {
                // 顶部主视觉：大图标 + 渐变大名 + 版本胶囊。
                VStack(spacing: 14) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 128, height: 128)
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                    }
                    // 0.4.2 用户点名：标题改液态玻璃风格,玻璃色跟 macOS 主题强调色。
                    appTitle
                    Text(versionLine)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Text(L10n.text("about.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                    Text(L10n.text("about.author"))
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 36)
                .padding(.bottom, 28)

                // 链接卡：仓库 / 许可证 / 提交 Bug —— 全部跳浏览器。
                HStack(spacing: 12) {
                    aboutLinkCard(
                        title: L10n.text("about.link.project"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        colors: [.blue, .cyan]
                    ) { AboutPanel.openProjectPage() }
                    aboutLinkCard(
                        title: L10n.text("about.link.license"),
                        systemImage: "doc.text",
                        colors: [.purple, .indigo]
                    ) { AboutPanel.openLicensePage() }
                    aboutLinkCard(
                        title: L10n.text("about.link.issue"),
                        systemImage: "ladybug",
                        colors: [.orange, .red]
                    ) { AboutPanel.openNewIssuePage() }
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 28)

                // 第三方致谢：站在谁的肩膀上。
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("about.ack.title"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(alignment: .top, spacing: 12) {
                        acknowledgementCard(name: "7-Zip", systemImage: "archivebox.fill", detail: L10n.text("about.ack.sevenzip"))
                        acknowledgementCard(name: "GnuPG", systemImage: "key.fill", detail: L10n.text("about.ack.gnupg"))
                        acknowledgementCard(name: "Sparkle", systemImage: "sparkles", detail: L10n.text("about.ack.sparkle"))
                    }
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 24)

                Text(L10n.text("about.copyright"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
    }

    /// 液态玻璃标题：macOS 26 用系统 Liquid Glass（accent tint）；老系统退回主题色渐变字。
    @ViewBuilder
    private var appTitle: some View {
        if #available(macOS 26.0, *) {
            Text("SimpleZip")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.55)), in: Capsule())
        } else {
            Text("SimpleZip")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    @ViewBuilder
    private func aboutLinkCard(title: String, systemImage: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func acknowledgementCard(name: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(12)
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
