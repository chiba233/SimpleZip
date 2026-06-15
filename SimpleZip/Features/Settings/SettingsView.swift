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

import AppKit
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
    // 打开设置时别把键盘焦点自动塞给 AI 搜索框(用户报「一开设置光标永远在搜索框，不合理」)。
    // 绑定 @FocusState、默认不聚焦 → SwiftUI 接管焦点、不再让它当窗口首响应者;用户点一下才进。
    @FocusState private var aiSearchFieldFocused: Bool

    var body: some View {
        // 弃用 NavigationSplitView：macOS 上它的把手照样能把侧栏拖塌（constant(.all) 拦不住）、
        // 持久化旧宽度还会压过钉宽声明（用户连报两次）。普通 HStack + frame(width:) 绝对定宽 ——
        // 物理上没有把手、没有折叠、没有持久化；侧栏毛玻璃用 SidebarBackdrop 补回。
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 12)
                AIGate {
                    aiSettingsSearchField
                }
                ForEach(SettingsPane.allCases) { pane in
                    // #79:选中态用活动中心同款「行色层叠渐变 chrome」(渐变底 + 同色渐变描边),
                    // 替代旧的 accent 平涂 —— 与活动中心侧栏视觉对齐。瓦片本就共用 color.gradient,
                    // 选中态切到 chromeSelection 即同款;行为(点选切页)零变更。
                    CenteredSidebarRow(
                        title: pane.title,
                        systemImage: pane.systemImage,
                        color: pane.iconColor,
                        isSelected: selectedPane == pane,
                        chromeSelection: true
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
                // 居中:About 等固定布局分区在窗口里垂直居中(用户要「关于要居中」)。之前「爆掉」是因为窗口能被拉到
                // 比内容还矮、居中后上下裁切 —— 现已给内容定了最小宽高(见上方 body 的 .frame),窗口不会短于内容,
                // 居中不再溢出。hero 分区的 Form 本就填满高度,居中对它无影响。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 0.4.5:设置改由 SettingsWindowController 自建 NSWindow 托管(缩放/全屏/沉浸 chrome 在那边一次设定、永不被
        // SwiftUI 重置)。这里必须给**内容**定出最小宽高 —— NSHostingController 据此驱动窗口最小尺寸,窗口才不会被拉到
        // 比这更窄/矮(只设 window.minSize 不够:设 contentViewController 时会按内容约束重算,没内容下限就允许拉窄,
        // 布局行为不一致)。最小宽 940 保证最长 pane 名 + Form 行在全 10 语种下不截断。
        .frame(minWidth: 940, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
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
                    .focused($aiSearchFieldFocused)
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
            //
            // 沉浸式(#79):hero 头作为 Form 的顶部安全区 inset 钉住 —— Form 本体仍占满整个沉浸区
            // (内容滚动从 hero 下方穿过、毛玻璃铺到透明标题栏顶),不再被外层 VStack 的顶部安全区
            // 下推(那会杀掉 bleed,把 hero 顶进标题栏下方的死带)。对齐活动中心 grouped Form 吃 inset 的行为。
            // #79:居中 + 沉浸 —— hero 与 Form 同为一条钉宽 720 的 VStack 的两个子节点,一起居中、对齐(safeAreaInset
            // 那条路会让 hero 跟随外层整宽被甩到左,已排除)。沉浸由窗口 chrome 提供(SettingsWindowController 建窗时一次设定:
            // fullSizeContentView + 透明标题栏 + 去分隔线),内容铺到顶、消除标题栏色带 —— 去掉这套则到处露色带。
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
            .frame(maxWidth: 720, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 设置窗口控制器:自建 NSWindow 托管 `SettingsView`。
///
/// 为什么不用 SwiftUI `Settings` 场景:它给的是**不可缩放的偏好窗**,要做成「可缩放 + 全屏 + 沉浸」必须手动覆盖
/// 标题栏 chrome,而 SwiftUI 会在**重开 / 进全屏**时用自己那套配置把覆盖冲掉 → 标题栏色带(白条)反复冒出
/// (用户实测「第一次正常、第二次打开就爆」)。自己持有窗口 → chrome 创建时设一次、永不被冲(与活动中心同款,一直稳)。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private init() {}

    /// 打开设置窗(可选定位到某 pane + 滚到某锚点)。已开着就切 pane / 滚锚点并前置;没开就建窗。
    func show(pane: SettingsPane? = nil, anchor: String? = nil) {
        // pane / anchor 复用现成深链机制:首次开窗时由 SettingsView.onAppear / settingsScrollAnchors 消费。
        if let pane { SettingsDeepLink.pendingPane = pane }
        if let anchor { SettingsDeepLink.pendingAnchor = anchor }

        if let window {
            // 已开着:发通知即时切 pane(SettingsView 在监听 .openSettingsPane);锚点延一拍等布局完再滚。
            if let pane { NotificationCenter.default.post(name: .openSettingsPane, object: pane) }
            if let anchor {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .scrollToSettingsAnchor, object: anchor)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // 沉浸 chrome 一次设定(对齐活动中心,创建后永不改):fullSizeContentView + 透明标题栏 + 去分隔线;
        // 可缩放 + 可全屏;tabbingMode=.disallowed —— 偏好窗不该并窗口标签(否则任务期临时窗口会并进来冒白条)。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("settings.title")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 940, height: 700)
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.center()
        window.makeKeyAndOrderFront(nil)
        // 别让 AI 搜索框抢初始焦点(用户报:一开设置光标永远在搜索框)。延一拍等 hosting view 布局完再清。
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
