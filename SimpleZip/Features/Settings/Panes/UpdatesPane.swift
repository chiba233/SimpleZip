//
//  UpdatesPane.swift
//  SimpleZip
//
//  0.4.1 设置 → 软件更新：检查更新（立即 / 启动时 / 自动下载）+ 从 GitHub 拉取的版本更新日志。
//  更新日志数据源 = 仓库 main 分支的 CHANGELOG(.zh-CN).md（按 App 语言选中英），
//  解析「## x.y.z」分段后逐版本折叠展示 —— 不引入新格式，日志文件本身就是单一事实源。
//

import Combine
import Sparkle
import SwiftUI

struct UpdatesPane: View {
    @AppStorage(AppPreferences.Key.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = false
    /// Sparkle 的「自动下载并安装」开关 —— 真值在 SPUUpdater 里，@State 只是 UI 镜像（onAppear 同步）。
    @State private var automaticallyDownloads = false
    @StateObject private var changelog = ChangelogFeed()

    var body: some View {
        Form {
            Section(L10n.text("updates.section.check")) {
                SettingsControlRow(
                    title: L10n.text("updates.currentVersion"),
                    description: L10n.text("updates.currentVersion.description"),
                    systemImage: "app.badge.checkmark", iconTint: .green
                ) {
                    Text(Self.currentVersionText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                SettingsControlRow(
                    title: L10n.text("updates.lastCheck"),
                    description: L10n.text("updates.lastCheck.description"),
                    systemImage: "clock.fill", iconTint: .purple
                ) {
                    Text(lastCheckText)
                        .foregroundStyle(.secondary)
                }

                SettingsControlRow(
                    title: L10n.text("updates.checkNow"),
                    description: L10n.text("updates.checkNow.description"),
                    systemImage: "arrow.triangle.2.circlepath", iconTint: .blue
                ) {
                    Button {
                        SparkleUpdater.shared.checkForUpdates()
                    } label: {
                        Label(L10n.text("updates.checkNow.button"), systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.checkForUpdatesOnLaunch"),
                    description: L10n.text("settings.checkForUpdatesOnLaunch.description"),
                    systemImage: "power", iconTint: .orange,
                    isOn: $checkForUpdatesOnLaunch
                )

                SettingsToggleRow(
                    title: L10n.text("updates.autoDownload"),
                    description: L10n.text("updates.autoDownload.description"),
                    systemImage: "arrow.down.circle.fill", iconTint: .teal,
                    isOn: $automaticallyDownloads
                )
                .onChange(of: automaticallyDownloads) { newValue in
                    SparkleUpdater.shared.updater.automaticallyDownloadsUpdates = newValue
                }
            }

            Section(L10n.text("updates.section.changelog")) {
                switch changelog.state {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("updates.changelog.loading"))
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.text("updates.changelog.failed"), systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Button {
                            changelog.load()
                        } label: {
                            Label(L10n.text("updates.changelog.retry"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .loaded(let releases):
                    ForEach(releases) { release in
                        releaseRow(release)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // 更新日志的每个版本折叠行整行可点展开(用户点名,与设置其它折叠组、活动中心同款)。
        .disclosureGroupStyle(.wholeRow)
        .onAppear {
            automaticallyDownloads = SparkleUpdater.shared.updater.automaticallyDownloadsUpdates
            changelog.loadIfNeeded()
        }
    }

    /// 单个版本的折叠行：最新版本默认展开，其余收起；正文按 Markdown 渲染（粗体等保留）。
    @ViewBuilder
    private func releaseRow(_ release: ChangelogFeed.Release) -> some View {
        DisclosureGroup(isExpanded: bindingForExpansion(release)) {
            Text(release.attributedBody)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 12) {
                // 版本抽屉头 = 一级,彩色瓦片(与全设置同制度)。
                SettingsRowIcon(systemImage: "shippingbox.fill", tint: .brown)
                Text(L10n.format("updates.changelog.version", release.version))
                    .font(.body.weight(.medium))
                if release.version == Self.shortVersion {
                    Text(L10n.text("updates.changelog.current"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
        }
    }

    private func bindingForExpansion(_ release: ChangelogFeed.Release) -> Binding<Bool> {
        Binding(
            get: { changelog.expandedVersions.contains(release.version) },
            set: { expanded in
                if expanded {
                    changelog.expandedVersions.insert(release.version)
                } else {
                    changelog.expandedVersions.remove(release.version)
                }
            }
        )
    }

    private var lastCheckText: String {
        guard let date = SparkleUpdater.shared.updater.lastUpdateCheckDate else {
            return L10n.text("updates.lastCheck.never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private static var currentVersionText: String {
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        return "\(shortVersion) (\(build))"
    }
}

/// 从 GitHub raw 拉 CHANGELOG 并按「## 版本号」分段的 feed。
/// 失败只影响本分区（显示重试），不阻塞设置页其它内容。
@MainActor
final class ChangelogFeed: ObservableObject {
    struct Release: Identifiable {
        let version: String
        let body: String
        var id: String { version }

        /// Markdown 渲染（保留换行；解析失败退回纯文本，绝不丢内容）。
        /// 渲染前把 `~` 和 `_` 转义成字面量:inlineOnly 模式下整个正文是**一个段落**,
        /// 跨行的两个 `~`(如 `~/.Trash` 与 `~/文稿`)会被 GFM 配成删除线区间,把中间几条
        /// 更新整段画上横线(用户截图实锤);`__MACOSX` 这类双下划线同理有配对风险。
        /// 转义只做在反引号代码段**之外** —— 代码段内不解析反斜杠转义,会把 `\~` 原样
        /// 漏显出来(实测 129 处)。CHANGELOG 约定从不写删除线/下划线强调,转义零损失。
        ///
        /// `### 分类标题`(0.4.4 起 CHANGELOG 按 feat/UX/bugfix… 分类):inlineOnly 模式不渲染
        /// 块级 ATX 标题,会把 `### feat` 原样露出井号。渲染前把这种行就地转成粗体行(`**feat**`)——
        /// CHANGELOG 文件保持标准 `###`(GitHub / Sparkle HTML 仍是正常标题),只在这个 inline 渲染器
        /// 里降级成粗体,井号不外漏。`## 版本号` 由 parseReleases 切走,这里的 body 里不会再有。
        var attributedBody: AttributedString {
            let headerNormalized = body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { rawLine -> String in
                    let line = String(rawLine)
                    let trimmed = line.drop(while: { $0 == " " })
                    guard trimmed.hasPrefix("### ") else { return line }
                    let title = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    return title.isEmpty ? line : "**\(title)**"
                }
                .joined(separator: "\n")
            let segments = headerNormalized.components(separatedBy: "`")
            let escaped = segments.enumerated().map { index, segment in
                index.isMultiple(of: 2)
                    ? segment
                        .replacingOccurrences(of: "~", with: "\\~")
                        .replacingOccurrences(of: "_", with: "\\_")
                    : segment
            }.joined(separator: "`")
            return (try? AttributedString(
                markdown: escaped,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(body)
        }
    }

    enum State {
        case idle
        case loading
        case loaded([Release])
        case failed(String)
    }

    @Published var state: State = .idle
    /// 展开状态（最新版本在 load 成功时自动展开）。
    @Published var expandedVersions: Set<String> = []

    /// 只展示最近 N 个版本 —— 完整历史去 GitHub 看，设置页不做无限长列表。
    private nonisolated static let maxReleases = 12

    func loadIfNeeded() {
        if case .idle = state { load() }
    }

    func load() {
        state = .loading
        let url = Self.changelogURL
        Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else {
                    throw URLError(.badServerResponse)
                }
                let releases = Self.parseReleases(from: text)
                await MainActor.run {
                    guard let self else { return }
                    self.state = .loaded(releases)
                    if let latest = releases.first {
                        self.expandedVersions = [latest.version]
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 跟随 App 语言选中英文版日志；其余语言回退英文。
    private static var changelogURL: URL {
        let isChinese = L10n.text("settings.section.general").range(of: "通用") != nil
            || Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let file = isChinese ? "CHANGELOG.zh-CN.md" : "CHANGELOG.md"
        // 强制解包安全：常量字符串 URL，编译期可证 —— 但仓库规则禁 force unwrap，走 fallback。
        return URL(string: "https://raw.githubusercontent.com/chiba233/SimpleZip/main/\(file)")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// 把整份 CHANGELOG 按「## x.y.z」切段。段内正文原样保留（含 `- **…**` 列表）。
    nonisolated static func parseReleases(from markdown: String) -> [Release] {
        var releases: [Release] = []
        var currentVersion: String?
        var currentLines: [String] = []

        func flush() {
            if let version = currentVersion {
                let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    releases.append(Release(version: version, body: body))
                }
            }
            currentLines = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                currentVersion = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentVersion != nil {
                currentLines.append(String(line))
            }
        }
        flush()
        return Array(releases.prefix(maxReleases))
    }
}
