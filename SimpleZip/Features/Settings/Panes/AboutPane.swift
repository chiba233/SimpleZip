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
    /// 隐藏开发者工具(⌘+点击版本胶囊进入)。
    @State private var showsDevTools = false

    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("about.versionLine", short, build)
    }

    var body: some View {
        // 0.4.2 用户拍板：关于**必须一页显示、绝不出现滚动条** —— 不包任何滚动容器,
        // 间距按设置窗最小高度（660pt）压实。
        aboutContent
            .sheet(isPresented: $showsDevTools) {
                DevToolsView { showsDevTools = false }
            }
    }

    private var aboutContent: some View {
            VStack(spacing: 0) {
                // 顶部主视觉：大图标 + 渐变大名 + 版本胶囊。
                VStack(spacing: 10) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 104, height: 104)
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    }
                    // 0.4.2 用户点名：标题改液态玻璃风格,玻璃色跟 macOS 主题强调色。
                    appTitle
                    Text(versionLine)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                        // 0.4.2 彩蛋：⌘+点击版本胶囊 → 开发者工具(普通点击无事发生,不打扰常规用户)。
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                showsDevTools = true
                            }
                        }
                    Text(L10n.text("about.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                    Text(L10n.text("about.author"))
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 20)
                .padding(.bottom, 18)

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
                .padding(.bottom, 18)

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
                    // 等高的关键:把 HStack 高度钉在「最高那张卡的理想高度」,卡片的 maxHeight:.infinity
                    // 只在这个有界高度里撑满 —— 既等高,又不会贪婪高度吃掉整窗(关于页没有滚动容器)。
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 14)

                Text(L10n.text("about.copyright"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
    }

    private var titleText: Text {
        Text("SimpleZip")
            .font(.system(size: 42, weight: .bold, design: .rounded))
    }

    /// 液态玻璃**字形**（用户点名：像系统激活欢迎字那样,玻璃是字本身、不是垫底）：
    /// 玻璃层按文字轮廓 mask —— 笔画里是折射的主题色玻璃,字外完全透明。老系统退回主题色渐变字。
    @ViewBuilder
    private var appTitle: some View {
        if #available(macOS 26.0, *) {
            titleText
                .foregroundStyle(.clear)
                .overlay {
                    Rectangle()
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.6)), in: Rectangle())
                        .mask(titleText)
                }
        } else {
            titleText
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
        // maxHeight:.infinity 必须配合外层 HStack 的 fixedSize(vertical:true) 用 —— 单独用会把窗口
        // 剩余空间全吃进卡片(用户报"被异常拉高");钉住后它只负责把三张卡撑到一样高(用户报"不一样高真的好丑")。
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
