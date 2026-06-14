//
//  SettingsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//
//  0.3.3 UI 现代化：手画的 HStack 侧栏（自定义按钮 + 自管开关）重绘成原生
//  NavigationSplitView + List(selection:) —— 系统设置同款：原生选中态、原生侧栏开关、
//  系统材质（macOS 26 上自动玻璃化），少掉一整套自绘 chrome。
//

import SwiftUI

/// 设置窗口的主容器：原生侧栏 + 当前选中的 pane。
///
/// 真正的偏好项都放在 `Panes/` 下，每个 pane 自己拥有它需要的 `@AppStorage`。
/// 这里只关心：当前选中哪个 pane、以及外部跳转（健康面板的修复按钮直接切 pane）。
struct SettingsView: View {
    @State private var selectedPane: SettingsPane? = .general
    // #64(macOS 26 AI):用一句话找设置 —— AI 从设置目录里抽出命中项 + 意图,App 确定性地深链过去
    // (+ 安全开关项可顺手切;第三道闸在 SettingToggleRegistry.accessor)。仅 isReady 时露出。
    @State private var aiSettingsQuery = ""
    @State private var aiSettingsRunning = false
    @State private var aiSettingsError: String?

    var body: some View {
        // 弃用 NavigationSplitView：macOS 上它的把手照样能把侧栏拖塌（constant(.all) 拦不住）、
        // 持久化旧宽度还会压过钉宽声明（用户连报两次）。普通 HStack + frame(width:) 绝对定宽 ——
        // 物理上没有把手、没有折叠、没有持久化；侧栏毛玻璃用 SidebarBackdrop 补回。
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 12)
                if AIReportAssistant.isReady {
                    aiSettingsSearchField
                }
                ForEach(SettingsPane.allCases) { pane in
                    CenteredSidebarRow(
                        title: pane.title,
                        systemImage: pane.systemImage,
                        color: pane.iconColor,
                        isSelected: selectedPane == pane
                    ) {
                        selectedPane = pane
                    }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            // 自适应宽（同活动中心）：取最宽 pane 名的内容宽度，任何语言都不截断。
            .frame(minWidth: 200)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .background(SidebarBackdrop().ignoresSafeArea())

            Divider()
                .ignoresSafeArea()

            selectedPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 有理想尺寸但可以拉，遵循 macOS 原生 Settings 风格（写死尺寸会被长翻译撑爆）。
        .frame(
            minWidth: 880, idealWidth: 980, maxWidth: .infinity,
            minHeight: 660, idealHeight: 780, maxHeight: .infinity
        )
        .navigationTitle(L10n.text("settings.title"))
        // 0.4.2 深链：菜单栏「关于 SimpleZip」等入口直接定位到指定 pane。
        .onAppear {
            if let pending = SettingsDeepLink.consumePending() {
                selectedPane = pending
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsPane)) { note in
            if let pane = note.object as? SettingsPane {
                selectedPane = pane
            }
        }
    }

    /// #64:侧栏顶部的「一句话找设置」AI 搜索框。
    @ViewBuilder
    private var aiSettingsSearchField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
                TextField(L10n.text("settings.aiSearch.prompt"), text: $aiSettingsQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await runAISettingsSearch() } }
                    .onChange(of: aiSettingsQuery) { _ in aiSettingsError = nil }
                if aiSettingsRunning { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            if let aiSettingsError {
                Text(aiSettingsError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 定宽:否则 TextField 随输入变宽,把 `fixedSize` 的侧栏无限撑长(用户实测)。
        .frame(width: 180)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    /// AI 从设置目录抽出命中项 + 意图 → 确定性深链(+ 安全开关项顺手切)。失败 / 没命中给气泡提示,不乱跳。
    @MainActor
    private func runAISettingsSearch() async {
        let query = aiSettingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !aiSettingsRunning else { return }
        guard #available(macOS 26.0, *) else { return }
        aiSettingsRunning = true
        aiSettingsError = nil
        defer { aiSettingsRunning = false }
        let catalog = SettingsCatalog.items
            .map { "\($0.id)\t\(L10n.text($0.titleKey))\t\($0.keywords.joined(separator: ", "))" }
            .joined(separator: "\n")
        do {
            let spec = try await AIReportAssistant.settingsQuerySpec(for: query, catalog: catalog)
            let id = spec.settingID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let item = SettingsCatalog.item(id: id) else {
                aiSettingsError = L10n.text("settings.aiSearch.notFound")
                return
            }
            // 安全开关:仅 isToggleable 项可经 AI 直接开关(accessor 内部第三道闸再挡一次);否则只导航过去。
            if spec.intent != .navigate, let accessor = SettingToggleRegistry.accessor(for: id) {
                accessor.set(spec.intent == .enable)
            }
            SettingsDeepLink.open(item.pane, anchor: item.id)
            aiSettingsQuery = ""
        } catch {
            aiSettingsError = L10n.text("settings.aiSearch.failed")
        }
    }

    /// 健康面板需要可写的 selectedPane（修复按钮跳对应 pane）；List 的 selection 是 Optional，
    /// 这里折回非 Optional binding —— 清空选择时落回「通用」。
    private var selectedPaneBinding: Binding<SettingsPane> {
        Binding(
            get: { selectedPane ?? .general },
            set: { selectedPane = $0 }
        )
    }

    @ViewBuilder
    private var selectedPaneView: some View {
        let pane = selectedPane ?? .general
        if pane.showsHero {
            // #81 0.4.5:裸 Form 分区顶部统一 hero 头(彩色渐变图标瓦片 + 标题 + 一句描述),对齐活动中心。
            // 帮助 / 关于自带头(showsHero=false)直接走原布局,绝不在自带头上再叠一层。
            VStack(spacing: 0) {
                HStack {
                    paneHero(pane)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 4)
                paneContent(pane)
            }
        } else {
            paneContent(pane)
        }
    }

    /// #81 hero 头:渐变发光图标瓦片 + 标题 + 副标题(与活动中心 `paneHero` 同款配色 0.65/0.45,辉光 0.30,纯静态)。
    private func paneHero(_ pane: SettingsPane) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [pane.iconColor.opacity(0.65), pane.iconColor.opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .frame(width: 38, height: 38)
                .shadow(color: pane.iconColor.opacity(0.30), radius: 7, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                if !pane.subtitle.isEmpty {
                    Text(pane.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralPane()
        case .archive:
            ArchivePane()
        case .browser:
            BrowserPane()
        case .view:
            ColumnsPane()
        case .fileAssociations:
            FileAssociationsPane()
        case .gpg:
            GPGPane()
        case .updates:
            UpdatesPane()
        case .health:
            HealthPane(selectedPane: selectedPaneBinding)
        case .backup:
            BackupPane()
        case .automation:
            AutomationPane()
        case .help:
            HelpPane()
        case .about:
            AboutPane()
        }
    }
}
