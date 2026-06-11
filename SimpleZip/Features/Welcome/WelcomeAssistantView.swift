//
//  WelcomeAssistantView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/29.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// 用户从 SimpleZip → 重新运行欢迎助手 入口触发；ContentView 监听后打开 sheet。
    /// 也可以用于其它入口（命令行 / URL scheme）唤起助手。
    static let openWelcomeAssistant = Notification.Name("openWelcomeAssistant")
}

/// 欢迎助手 wizard —— 首次启动自动弹，覆盖最容易被新用户错过的关键设置。
///
/// 设计动机：
/// - SimpleZip 有数十个偏好。新用户大概率会绕过设置直接用，错过预设密码 / Finder 自动解压
///   这类「真的能省事」的开关。这个 wizard 在第一次启动时把关键设置拆成若干简短步骤逐个过。
/// - 步骤构成见下方 `stepContent` 的 switch（备份恢复 / 版本检查 / intro / 一组设置步骤 / 完成）；
///   总步数 / 设置步数以 `totalSteps`、`settingStepCount` 为准（加减步骤时改那里，别在注释里写死数字）。
///   每个设置步骤都直接绑 `@AppStorage` —— 用户改的瞬间就落盘，`Back / Skip / Finish` 都不会丢失改动。
/// - 触发：`AppPreferences.welcomeAssistantCompleted` bool 控制是否首次启动自动弹；
///   走完最后一步时置 true。SimpleZip 菜单的「重新运行欢迎助手」通过
///   `Notification.Name.openWelcomeAssistant` 重新打开，不重置 completed bool
///   （重新打开仍然算「已经走过一遍」）。
struct WelcomeAssistantView: View {
    /// 助手结束（Finish 或 Esc）时由 host 处理：关掉 sheet / 关掉窗口。
    let onComplete: () -> Void

    @AppStorage(AppPreferences.Key.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.Key.startupLocation) private var startupLocation = StartupLocation.home.rawValue
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.ask.rawValue
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false
    @AppStorage(AppPreferences.Key.finderOpenAutoExtract) private var finderOpenAutoExtract = false
    @AppStorage(AppPreferences.Key.suspiciousPathPolicy) private var suspiciousPathPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.symbolicLinkPolicy) private var symbolicLinkPolicy = ArchiveSecurityDecision.ask.rawValue
    @AppStorage(AppPreferences.Key.activeContentOpenPolicy) private var activeContentOpenPolicy = ArchiveSecurityDecision.ask.rawValue
    // 向导只留「显示隐藏文件」总开关 —— 判定方式 / 折叠策略 / 行密度 / 分组等细粒度视图偏好
    // 已砍出向导（0.3.3），统一在 设置 → 浏览 / 视图 里调。
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    /// 0.4.2:安全策略页新增「删除文件前二次确认」开关(默认开,与设置页同 key)。
    @AppStorage(AppPreferences.Key.confirmBeforeDeletingFiles) private var confirmBeforeDeletingFiles = true
    /// 0.4.3 #7:安全策略页随设置 → 压缩 → 安全 同步新增两个写入验证开关(同 key,默认值同设置页)。
    @AppStorage(AppPreferences.Key.verifyAfterArchiveRewrite) private var verifyAfterArchiveRewrite = true
    @AppStorage(AppPreferences.Key.verifyAfterArchiveCreate) private var verifyAfterArchiveCreate = false

    @State private var currentStep: Int = 0

    /// 总页数。0.3.3 用户拍板「压到 6 页」后 0.4.3 用户点名加回一页 Finder 右键集成 ——
    /// 0 欢迎（hero + 版本检查 + 备份导入）/ 1 通用（语言 + 常规）/ 2 便利（预设密码 + 自动解压 + 文件关联）/
    /// 3 Finder 右键集成 / 4 安全策略 / 5 引擎（后端 + GPG）/ 6 完成。每个设置仍直接绑 @AppStorage，改的瞬间落盘。
    private let totalSteps = 7

    /// 「取消」按钮的二次确认 alert flag。
    /// 不直接关 sheet：用户可能误点 ESC / 关闭，已经做出的选项可能想留也想看后面的步骤。
    @State private var showsCancelConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            Divider()

            // 0.4.2 重绘：放得下直接铺（默认**无滚动条**），放不下才退回 ScrollView。
            ViewThatFits(in: .vertical) {
                paddedStepContent
                ScrollView {
                    paddedStepContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 换页过场：新页淡入 + 轻微右侧滑入，旧页淡出左移（footer 按钮里用 spring 驱动）。
            .id(currentStep)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 28)),
                removal: .opacity.combined(with: .offset(x: -20))
            ))

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        // 高度随首页紧凑化回落(760 → 700):按最高的「便利」三段页核算,留 ViewThatFits 兜底。
        .frame(width: 780, height: 700)
        .background(
            // 顶部一抹主题色柔光 —— 华丽但不喧宾夺主,深浅色模式都成立。
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
        .alert(L10n.text("welcome.cancelConfirm.title"), isPresented: $showsCancelConfirmation) {
            Button(L10n.text("welcome.cancelConfirm.cancel"), role: .cancel) {}
            Button(L10n.text("welcome.cancelConfirm.confirm"), role: .destructive) {
                // 取消 = 不 mark completed。用户下次启动还会再次自动弹（除非他们之前已经走完过一次）。
                // 这是预期的「取消 ≠ 完成」语义。
                onComplete()
            }
        } message: {
            Text(L10n.text("welcome.cancelConfirm.message"))
        }
    }

    private var paddedStepContent: some View {
        stepContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
    }

    // MARK: - Header

    private var progressHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 0.4.2 用户点名：真 app 图标放左上角 header（hero 区不再放图标）。
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                }

                Text(L10n.text("welcome.window.title"))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // 0.4.2 重绘：线性进度条 → onboarding 风分段步骤点（当前步 = 加宽主题色胶囊）。
            HStack(spacing: 7) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Capsule()
                        .fill(step <= currentStep ? Color.accentColor : Color.primary.opacity(0.14))
                        .frame(width: step == currentStep ? 26 : 8, height: 8)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentStep)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            // 欢迎页：hero（大渐变图标 + 标题 + 简介）+ 版本检查 + 备份导入，三合一。
            VStack(alignment: .leading, spacing: 16) {
                welcomeHero
                WelcomeVersionCheckStep()
                WelcomeBackupRestoreStep()
            }
        case 1:
            // 通用：语言 + 常规（启动位置 / 覆盖 / 隐藏文件 / 密度 / 分组）。
            VStack(alignment: .leading, spacing: 16) {
                WelcomeLanguageStep(appLanguage: $appLanguage)
                WelcomeGeneralStep(
                    startupLocation: $startupLocation,
                    overwriteBehavior: $overwriteBehavior,
                    showHidden: $showHiddenFiles
                )
            }
        case 2:
            // 便利：预设密码 + Finder 自动解压 + 文件关联。
            VStack(alignment: .leading, spacing: 16) {
                WelcomePresetPasswordStep(enabled: $presetPasswordEnabled)
                WelcomeFinderAutoExtractStep(enabled: $finderOpenAutoExtract)
                WelcomeFileAssociationsStep()
            }
        case 3:
            // Finder 右键集成（0.4.3 用户点名）：macOS 默认不激活第三方服务,首启就让用户挑要哪些右键项。
            WelcomeFinderServicesStep()
        case 4:
            WelcomeSafetyStep(
                suspiciousPathPolicy: $suspiciousPathPolicy,
                symbolicLinkPolicy: $symbolicLinkPolicy,
                activeContentOpenPolicy: $activeContentOpenPolicy,
                confirmBeforeDelete: $confirmBeforeDeletingFiles,
                verifyAfterRewrite: $verifyAfterArchiveRewrite,
                verifyAfterCreate: $verifyAfterArchiveCreate
            )
        case 5:
            // 引擎：压缩后端 + GPG（GPG 保持独立 section —— opt-in/opt-out 决定仍然显式）。
            VStack(alignment: .leading, spacing: 16) {
                WelcomeBackendStep()
                WelcomeGPGStep()
            }
        default:
            WelcomeCompletionStep()
        }
    }

    /// 欢迎页 hero：大渐变图标 + 大标题 + 简介 + 小贴士。原 WelcomeIntroStep 的内容升级合并到这里。
    private var welcomeHero: some View {
        // 0.4.2 修「第一页默认就有滚动条」：竖排居中大 hero 占掉 ~250pt,挤掉下面两段 ——
        // 改横排紧凑头(真 app 图标 + 标题/简介),与设置页 hero 同语言;note 行与 body 信息重复,删。
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("welcome.intro.title"))
                .font(.title.weight(.bold))
            Text(L10n.text("welcome.intro.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // 「取消」总是显示在最左侧 —— 用户随时能退出助手，但走二次确认避免误点。
            Button(L10n.text("welcome.button.cancel")) {
                showsCancelConfirmation = true
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if currentStep > 0 {
                Button(L10n.text("welcome.button.back")) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        currentStep = max(currentStep - 1, 0)
                    }
                }
            }

            // 主行动按钮用 prominent —— 现代 onboarding 的视觉重点，回退 / 取消保持常规按钮。
            if currentStep < totalSteps - 1 {
                Button(L10n.text("welcome.button.next")) {
                    // 必须在 action 里 clamp：按钮显隐的守卫是「渲染期」的，按住回车 / 快速连点时
                    // 旧按钮还在屏上、新状态没渲染，裸 += 会把 currentStep 顶过界 ——
                    // 越界后 default 分支连续渲染完成页，往回走就「多出两页」（用户报的 bug）。
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        currentStep = min(currentStep + 1, totalSteps - 1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.text("welcome.button.finish")) {
                    AppPreferences.markWelcomeAssistantCompleted()
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - 步骤子视图

/// 通用步骤外壳：标题 + 描述 + 自定义内容块。
/// 抽出来主要是让每个 step 的 padding / 字号 / 段落间距保持一致。
private struct WelcomeStepShell<Content: View>: View {
    let title: String
    /// 0.4.2 重绘：可选彩色图标瓦片（与设置侧栏 / 帮助页同语言）。不传 = 纯文字标题（兼容旧调用）。
    var systemImage: String? = nil
    var tint: Color = .accentColor
    let body1: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        // 用户拍板:窗口背景可以渐变,**box 不渐变** —— 图标瓦片用纯色。
                        .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(body1)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 内容进卡片 —— 与全 app 的 DialogSection 一个外观,欢迎页不再是裸控件铺地。
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
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

private struct WelcomeBackupRestoreStep: View {
    @State private var statusMessage: String?
    /// 区分成功 / 失败 —— 成功用绿色 ✓，失败用红色 ⚠
    @State private var statusIsSuccess = false

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.backupRestore.title"),
            systemImage: "arrow.down.doc.fill",
            tint: .indigo,
            body1: L10n.text("welcome.backupRestore.body")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(L10n.text("welcome.backupRestore.button")) {
                    pickBackupFile()
                }

                // 导入是 destructive-ish（会按白名单清掉现有设置再写备份值）。首启流程不弹二次确认 ——
                // 主动选文件本身算确认 —— 但给一句小灰字说清后果。
                Text(L10n.text("welcome.backupRestore.importReplaceHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let statusMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: statusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(statusIsSuccess ? Color.green : Color.orange)
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func pickBackupFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = L10n.text("button.choose")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let payload = json as? [String: Any] else {
                throw NSError(domain: "WelcomeAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a JSON object"])
            }
            try AppPreferences.importPayload(payload)
            statusMessage = L10n.text("welcome.backupRestore.success")
            statusIsSuccess = true
        } catch {
            statusMessage = L10n.format("welcome.backupRestore.failure", error.localizedDescription)
            statusIsSuccess = false
        }
    }
}

private struct WelcomeVersionCheckStep: View {
    // 引导阶段就让用户决定要不要开「每次启动时检查更新」—— 直接绑 @AppStorage，改的瞬间落盘。
    @AppStorage(AppPreferences.Key.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = false

    /// 当前安装版本号 —— 从 Info.plist 的 `CFBundleShortVersionString` 取。
    /// 不缓存到 @State，每次 body 重新计算一次足够轻量。
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.versionCheck.title"),
            systemImage: "arrow.triangle.2.circlepath",
            tint: .red,
            body1: L10n.format("welcome.versionCheck.body", currentVersion)
        ) {
            // 简化版：直接复用菜单栏「检查更新」相同入口。
            // Sparkle 会自己弹「正在检查 / 已经最新 / 有新版下载」UI，不需要助手内嵌状态机。
            // 如果将来想做内嵌 banner，可以接 SPUUpdater 的 delegate 自己 driver。
            Button(L10n.text("welcome.versionCheck.button")) {
                SparkleUpdater.shared.checkForUpdates()
            }

            Toggle(L10n.text("settings.checkForUpdatesOnLaunch"), isOn: $checkForUpdatesOnLaunch)
            Text(L10n.text("settings.checkForUpdatesOnLaunch.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// WelcomeIntroStep 已并入第 0 页的 welcomeHero（0.3.3「压到 6 页」改版）。

private struct WelcomeLanguageStep: View {
    @Binding var appLanguage: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.language.title"),
            systemImage: "globe",
            tint: .blue,
            body1: L10n.text("welcome.language.body")
        ) {
            Picker("", selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// 「常规设置」合并步骤（0.2.1）——用户反馈欢迎向导太长，把原本各占一步的
/// 启动位置 / 覆盖行为 / 隐藏文件 / 列表密度 / 分组 五项收进同一页。
///
/// 每一项保留为本页内的一个小节（小标题 + 原说明文案 + 与原步骤完全一致的控件），
/// 既缩短了步数又不丢任何设置项或解释。控件逻辑沿用原来的实现，未改变任何写入行为
/// （仍各自绑 `@AppStorage`，改动即时落盘）。
private struct WelcomeGeneralStep: View {
    @Binding var startupLocation: String
    @Binding var overwriteBehavior: String
    @Binding var showHidden: Bool

    /// 当 `startupLocation == .custom` 时显示的具体路径 —— 从 UserDefaults 读，避免又开一个 @AppStorage。
    @State private var customPath: String = AppPreferences.startupCustomLocationURL?.path ?? ""

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.general.title"),
            systemImage: "gearshape.fill",
            tint: .gray,
            body1: L10n.text("welcome.general.body")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                section(L10n.text("welcome.startupLocation.title"), caption: L10n.text("welcome.startupLocation.body")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $startupLocation) {
                            ForEach(simpleLocations, id: \.rawValue) { location in
                                Text(location.title).tag(location.rawValue)
                            }
                            if !customPath.isEmpty {
                                Text(customRowTitle).tag(StartupLocation.custom.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()

                        Button(L10n.text("welcome.startupLocation.pickCustom")) {
                            pickCustomLocation()
                        }
                    }
                }

                Divider()

                section(L10n.text("welcome.overwrite.title"), caption: L10n.text("welcome.overwrite.body")) {
                    Picker("", selection: $overwriteBehavior) {
                        ForEach(OverwriteBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Divider()

                // 0.3.3 砍设置（用户「不适合放欢迎助手的砍了」）：隐藏文件的判定方式 / 折叠策略、
                // 行密度、分组范围 / 方式都是细粒度视图偏好 —— 留在 设置 → 浏览 / 视图，
                // 向导只留「显示隐藏文件」这一个总开关。
                section(L10n.text("welcome.hiddenFiles.title"), caption: L10n.text("welcome.hiddenFiles.body")) {
                    Toggle(L10n.text("settings.showHiddenFiles"), isOn: $showHidden)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    /// 小节外壳：小标题 + 说明 + 控件。各小节之间用 `Divider()` 分隔，视觉上仍是清晰的独立设置。
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    /// 「自定义位置（路径）」—— 直接把路径短名作为 picker 行文案，免去再起一行小灰字。
    private var customRowTitle: String {
        let url = URL(fileURLWithPath: customPath)
        let lastSegment = url.lastPathComponent.isEmpty ? customPath : url.lastPathComponent
        return "\(StartupLocation.custom.title) — \(lastSegment)"
    }

    /// 选择面包含的位置 —— 排除 `.lastFolder`（语义需要先有上次记录）；`.custom` 单独通过下方按钮触发挑路径。
    private var simpleLocations: [StartupLocation] {
        [.home, .downloads, .desktop, .documents, .movies, .music, .pictures]
    }

    private func pickCustomLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("button.choose")
        if !customPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            AppPreferences.setStartupCustomLocation(url)
            customPath = url.path
            startupLocation = StartupLocation.custom.rawValue
        }
    }
}

private struct WelcomePresetPasswordStep: View {
    @Binding var enabled: Bool

    /// 助手里的密码输入缓冲。
    /// `savedValue` 跟 Keychain 当前值同步，用来判断「未改动」状态以禁用保存按钮。
    /// 不在这里实现 Touch ID 揭示明文 —— 那是设置页的事，助手保持极简。
    @State private var passwordBuffer: String = ""
    @State private var savedValue: String = ""
    @State private var statusMessage: String?

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.presetPassword.title"),
            systemImage: "key.fill",
            tint: .orange,
            body1: L10n.text("welcome.presetPassword.body")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.text("settings.presetPasswordEnabled"), isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { isOn in
                        if isOn {
                            // 第一次开开关才碰 Keychain，触发可能的「允许访问」对话框。
                            loadFromKeychain()
                        } else {
                            // 关掉开关 = 同时清掉 Keychain 残留密码。
                            // 失败时回弹开关并把错误信息显示出来。
                            if !AppPreferences.clearPresetPassword() {
                                enabled = true
                                statusMessage = L10n.text("settings.presetPassword.clearFailed")
                            } else {
                                passwordBuffer = ""
                                savedValue = ""
                                statusMessage = nil
                            }
                        }
                    }

                if enabled {
                    HStack(spacing: 8) {
                        SecureField(
                            "",
                            text: $passwordBuffer,
                            prompt: Text(L10n.text("settings.presetPassword.placeholder"))
                                .foregroundColor(.secondary)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                        Button(L10n.text("button.save")) {
                            savePassword()
                        }
                        .disabled(passwordBuffer == savedValue)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            // 进入步骤时如果开关已经打开，把 Keychain 已存值拉进缓冲（一次性，启动时 load 走缓存）。
            if enabled {
                loadFromKeychain()
            }
        }
    }

    private func loadFromKeychain() {
        savedValue = AppPreferences.presetPassword
        passwordBuffer = savedValue
    }

    private func savePassword() {
        if AppPreferences.setPresetPassword(passwordBuffer) {
            savedValue = passwordBuffer
            statusMessage = L10n.text("welcome.presetPassword.savedHint")
        } else {
            statusMessage = L10n.text("settings.presetPassword.saveFailed")
        }
    }
}

private struct WelcomeFinderAutoExtractStep: View {
    @Binding var enabled: Bool

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.finderAutoExtract.title"),
            systemImage: "finder",
            tint: .blue,
            body1: L10n.text("welcome.finderAutoExtract.body")
        ) {
            Toggle(L10n.text("settings.finderOpenAutoExtract"), isOn: $enabled)
                .toggleStyle(.switch)
        }
    }
}

/// 文件关联步骤：复用设置页的 ArchiveAssociationService + FileAssociationRow，外加一个「全部设为默认」按钮。
private struct WelcomeFileAssociationsStep: View {
    @State private var associationStatus: [String: String] = [:]
    @State private var statusMessage: String?

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.fileAssociations.title"),
            systemImage: "doc.badge.gearshape",
            tint: .teal,
            body1: L10n.text("welcome.fileAssociations.body")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(L10n.text("welcome.fileAssociations.setAll")) {
                    setAllDefaults()
                }

                // 与 设置 → 文件关联 同制度:按类分组、同类同色(类别色在 ArchiveAssociation.category 上)。
                VStack(alignment: .leading, spacing: 0) {
                    associationGroup(titleKey: "settings.association.group.archives", systemImage: "doc.zipper", tint: .blue, category: .archive)
                    associationGroup(titleKey: "settings.association.group.simplezip", systemImage: "checkmark.seal", tint: .green, category: .simpleZip)
                    associationGroup(titleKey: "settings.association.group.volumes", systemImage: "square.stack.3d.down.right", tint: .orange, category: .volume)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    /// 一个类别的分组(与 FileAssociationsPane 同构:瓦片小标题 + 类内行)。
    @ViewBuilder
    private func associationGroup(titleKey: String, systemImage: String, tint: Color, category: ArchiveAssociation.Category) -> some View {
        let items = ArchiveAssociationService.supportedAssociations.filter { $0.category == category }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SettingsRowIcon(systemImage: systemImage, tint: tint)
                Text(L10n.text(titleKey)).font(.headline)
            }
            .padding(.vertical, 6)
            ForEach(items) { association in
                FileAssociationRow(
                    association: association,
                    currentDefaultApp: associationStatus[association.id] ?? L10n.text("settings.association.loading"),
                    isSimpleZipDefault: ArchiveAssociationService.isSimpleZipDefault(for: association)
                ) {
                    setDefault(for: association)
                }
                if association.id != items.last?.id {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    private func setAllDefaults() {
        var failed: [String] = []
        for association in ArchiveAssociationService.supportedAssociations {
            do {
                try ArchiveAssociationService.setAsDefault(for: association)
            } catch {
                failed.append(".\(association.fileExtension)")
            }
        }
        statusMessage = failed.isEmpty
            ? L10n.text("welcome.fileAssociations.setAllDone")
            : L10n.format("welcome.fileAssociations.setAllPartial", failed.joined(separator: " "))
        scheduleRefreshAfterLaunchServicesSettle()
    }

    private func setDefault(for association: ArchiveAssociation) {
        do {
            try ArchiveAssociationService.setAsDefault(for: association)
            statusMessage = L10n.format("settings.defaultArchiveTypeDone", ".\(association.fileExtension)")
            scheduleRefreshAfterLaunchServicesSettle()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// LaunchServices 设默认后同进程内短时间会读到旧缓存，多个时间点 retry 让 UI 自动跟上（同 FileAssociationsPane）。
    private func scheduleRefreshAfterLaunchServicesSettle() {
        refresh()
        for delay in [0.3, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                refresh()
            }
        }
    }

    private func refresh() {
        associationStatus = Dictionary(uniqueKeysWithValues: ArchiveAssociationService.supportedAssociations.map { association in
            (association.id, ArchiveAssociationService.currentDefaultAppName(for: association))
        })
    }
}

private struct WelcomeSafetyStep: View {
    // 0.4.2 用户点名「只读太蠢」：三个策略改成 Picker 直接改（@AppStorage Binding 从主 view 透传,
    // 改的瞬间落盘）;新增「删除文件前二次确认」开关(与 设置 → 通用 同 key)。
    @Binding var suspiciousPathPolicy: String
    @Binding var symbolicLinkPolicy: String
    @Binding var activeContentOpenPolicy: String
    @Binding var confirmBeforeDelete: Bool
    /// 0.4.3 #7:写入后验证两开关 —— 与 设置 → 压缩 → 安全 同 key,文案直接复用设置页的。
    @Binding var verifyAfterRewrite: Bool
    @Binding var verifyAfterCreate: Bool

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.safety.title"),
            systemImage: "shield.lefthalf.filled",
            tint: .pink,
            body1: L10n.text("welcome.safety.body")
        ) {
            policyRow(label: L10n.text("welcome.safety.suspiciousPath"), selection: $suspiciousPathPolicy)
            policyRow(label: L10n.text("welcome.safety.symlink"), selection: $symbolicLinkPolicy)
            policyRow(label: L10n.text("welcome.safety.activeContent"), selection: $activeContentOpenPolicy)

            toggleRow(
                icon: "trash",
                title: L10n.text("welcome.safety.confirmDelete"),
                detail: L10n.text("welcome.safety.confirmDelete.detail"),
                isOn: $confirmBeforeDelete
            )
            toggleRow(
                icon: "checkmark.seal",
                title: L10n.text("settings.verifyAfterRewrite"),
                detail: L10n.text("settings.verifyAfterRewrite.description"),
                isOn: $verifyAfterRewrite
            )
            toggleRow(
                icon: "checkmark.seal.fill",
                title: L10n.text("settings.verifyAfterCreate"),
                detail: L10n.text("settings.verifyAfterCreate.description"),
                isOn: $verifyAfterCreate
            )
        }
    }

    /// 开关行,与上面策略行同构（左图标 + 标题/副文,右侧控件）—— 用户报独立 Toggle+Divider 长相对不上。
    private func toggleRow(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.pink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func policyRow(label: String, selection: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.pink)
                .frame(width: 18)
            Text(label)
                .font(.callout.weight(.medium))
            Spacer()
            Picker("", selection: selection) {
                ForEach(ArchiveSecurityDecision.allCases) { decision in
                    Text(decision.title).tag(decision.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Finder 右键集成步骤（0.4.3 用户点名加页）：macOS 对第三方服务默认不激活,首启时
/// 直接挑要哪些「… 用 SimpleZip」右键项。逐服务开关 + 立即重新注册按钮与
/// 设置 → 通用 → Finder 右键集成完全同一份状态（pbs NSServicesStatus 写穿,文案同 key 复用）。
private struct WelcomeFinderServicesStep: View {
    /// 各服务激活状态镜像（真值在 pbs 偏好域,onAppear 拉取、开关写穿）—— 同 GeneralPane。
    @State private var serviceStates: [String: Bool] = [:]
    @State private var statusMessage: String?

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("settings.finderExtension"),
            systemImage: "filemenu.and.cursorarrow",
            tint: .cyan,
            body1: L10n.text("settings.finderExtension.description")
        ) {
            ForEach(FinderServicesRegistry.services) { service in
                SettingsToggleRow(
                    title: L10n.text(service.titleKey),
                    description: service.menuName,
                    systemImage: service.systemImage,
                    isOn: serviceBinding(service)
                )
            }

            HStack {
                // 启动时已按版本自动注册（AppDelegate）；这里是手动兜底 —— 右键菜单没出现时立即重刷。
                Button(L10n.text("settings.finderExtension.register")) {
                    NSUpdateDynamicServices()
                    statusMessage = L10n.text("settings.finderExtension.registered")
                }
                Button(L10n.text("settings.finderExtension.manage")) {
                    // 系统设置 → 键盘 → 键盘快捷键 → 服务 仍可管理（与上面的开关同一份状态）。
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reloadServiceStates)
    }

    private func reloadServiceStates() {
        var states: [String: Bool] = [:]
        for service in FinderServicesRegistry.services {
            states[service.message] = FinderServicesRegistry.isEnabled(service)
        }
        serviceStates = states
    }

    /// 单个服务开关的写穿 binding：set 时直接写 pbs + 刷新注册,再更新镜像 —— 同 GeneralPane。
    private func serviceBinding(_ service: FinderServicesRegistry.Service) -> Binding<Bool> {
        Binding(
            get: { serviceStates[service.message] ?? false },
            set: { enabled in
                FinderServicesRegistry.setEnabled(enabled, for: service)
                serviceStates[service.message] = enabled
            }
        )
    }
}

private struct WelcomeBackendStep: View {
    @AppStorage(AppPreferences.Key.sevenZipBackend) private var sevenZipBackend = SevenZipBackendChoice.automatic.rawValue
    @AppStorage(AppPreferences.Key.rarBackend) private var rarBackend = RarBackendChoice.automatic.rawValue

    @State private var sevenZipAvailable = false
    @State private var rarAvailable = false
    @State private var hasLocalRar = false

    @State private var rarInstallReview: RarInstallReview?
    @State private var isInstallingRar = false
    @State private var installMessage: String?
    @State private var systemInstallMessage: String?

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.backend.title"),
            systemImage: "cpu",
            tint: .purple,
            body1: L10n.text("welcome.backend.body")
        ) {
            // GroupBox + SettingsControlRow / SettingsActionRow 是 Settings 同款组件 ——
            // 助手里直接复用让视觉一致，避免「快速开始」UI 跟「偏好设置」差太多的违和感。
            VStack(alignment: .leading, spacing: 16) {
                // 7-Zip section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("settings.7zip.backend"))
                        .font(.title3.weight(.semibold))
                    BackendStatusBadge(
                        isOk: sevenZipAvailable,
                        okText: L10n.text("welcome.backend.sevenZip.available"),
                        failText: L10n.text("welcome.backend.sevenZip.missing"),
                        style: .prominent
                    )
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsControlRow(
                                title: L10n.text("settings.7zip.backend"),
                                description: L10n.text("settings.7zip.backend.description")
                            ) {
                                Picker("", selection: $sevenZipBackend) {
                                    ForEach(SevenZipBackendChoice.allCases) { choice in
                                        Text(choice.title).tag(choice.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .onChange(of: sevenZipBackend) { _ in refreshStatus() }
                            }

                            if !sevenZipAvailable && SevenZipBackendChoice(rawValue: sevenZipBackend) == .system {
                                SystemInstallCommandView(
                                    title: L10n.text("settings.systemInstall.7zip.title"),
                                    command: "brew install sevenzip",
                                    message: $systemInstallMessage
                                )
                            }
                        }
                    }
                }

                // RAR section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("settings.rar.backend"))
                        .font(.title3.weight(.semibold))
                    BackendStatusBadge(
                        isOk: rarAvailable,
                        okText: L10n.text("welcome.backend.rar.available"),
                        failText: L10n.text("welcome.backend.rar.missing"),
                        style: .prominent
                    )
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsControlRow(
                                title: L10n.text("settings.rar.backend"),
                                description: L10n.text("settings.rar.backend.description")
                            ) {
                                Picker("", selection: $rarBackend) {
                                    ForEach(RarBackendChoice.allCases) { choice in
                                        Text(choice.title).tag(choice.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .onChange(of: rarBackend) { _ in refreshStatus() }
                            }

                            rarBlockBelowPicker

                            if let installMessage {
                                Text(installMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refreshStatus)
        .sheet(item: $rarInstallReview) { review in
            RarInstallReviewSheet(
                review: review,
                isInstalling: isInstallingRar,
                onCancel: { rarInstallReview = nil },
                onConfirm: { action in
                    rarInstallReview = nil
                    runRarInstaller(action: action)
                }
            )
        }
    }

    /// RAR 区块在 Picker 下方的「安装 / 更新 / 删除 / brew」按钮组 —— 用 SettingsActionRow 视觉跟 Settings 一致。
    @ViewBuilder
    private var rarBlockBelowPicker: some View {
        let selectedRar = RarBackendChoice(rawValue: rarBackend) ?? .automatic
        if !rarAvailable && selectedRar == .system {
            SystemInstallCommandView(
                title: L10n.text("settings.systemInstall.rar.title"),
                command: "brew install --cask rar",
                message: $systemInstallMessage
            )
        } else if selectedRar == .automatic || selectedRar == .bundled {
            if !hasLocalRar {
                SettingsActionRow(
                    title: L10n.text("settings.rar.runInstaller"),
                    description: L10n.text("settings.rar.runInstaller.description"),
                    systemImage: "arrow.down.circle",
                    buttonTitle: L10n.text("settings.rar.runInstaller"),
                    isDisabled: isInstallingRar
                ) {
                    beginRarInstallReview(.install)
                }
            } else {
                SettingsActionRow(
                    title: L10n.text("settings.rar.updateBackend"),
                    description: L10n.text("settings.rar.updateBackend.description"),
                    systemImage: "arrow.triangle.2.circlepath",
                    buttonTitle: L10n.text("settings.rar.updateBackend"),
                    isDisabled: isInstallingRar
                ) {
                    beginRarInstallReview(.update)
                }
                SettingsActionRow(
                    title: L10n.text("settings.rar.deleteBackend"),
                    description: L10n.text("settings.rar.deleteBackend.description"),
                    systemImage: "trash",
                    buttonTitle: L10n.text("settings.rar.deleteBackend"),
                    role: .destructive,
                    isDisabled: isInstallingRar,
                    action: deleteLocalRar
                )
            }
        }
    }

    private func beginRarInstallReview(_ action: RarInstallAction) {
        do {
            rarInstallReview = try RarInstallerService.loadReview(action: action)
        } catch {
            installMessage = error.localizedDescription
        }
    }

    private func runRarInstaller(action: RarInstallAction) {
        isInstallingRar = true
        installMessage = action == .install
            ? L10n.text("settings.rar.installing")
            : L10n.text("settings.rar.updating")
        Task {
            let message = await RarInstallerService.runInstaller(action: action)
            isInstallingRar = false
            refreshStatus()
            installMessage = message
        }
    }

    private func deleteLocalRar() {
        do {
            try ArchiveService.deleteLocalRarBackend()
            refreshStatus()
            installMessage = L10n.text("settings.rar.deleteSucceeded")
        } catch {
            installMessage = L10n.format("settings.rar.deleteFailedWithOutput", error.localizedDescription)
        }
    }

    private func refreshStatus() {
        sevenZipAvailable = ArchiveService.canUseSevenZip()
        rarAvailable = ArchiveService.canCreateRAR()
        hasLocalRar = ArchiveService.hasLocalRarBackend()
    }
}

/// GPG 集成的 opt-in / opt-out 步骤。
///
/// 单独成步骤（跟 7-Zip / RAR backend 那一步分开），因为 GPG 是「特殊可选功能」语义 ——
/// 用户不开 GPG 也不影响日常压缩 / 解压，必须显式选择启用。开启后若后端缺失，给 brew 命令 + GPGTools 链接，
/// 不卡用户继续 wizard（后端可以以后再装）。
///
/// 视觉模板复用 `BackendStatusBadge(.prominent)` + `GroupBox` + `SettingsControlRow` + `SystemInstallCommandView`
/// 跟 `WelcomeBackendStep` 同款，避免「快速开始 wizard 自成一套 UI」违和。
private struct WelcomeGPGStep: View {
    @AppStorage(AppPreferences.Key.gpgEnabled) private var gpgEnabled = false

    @State private var gpgAvailable = false
    @State private var hasPinentryMac = false
    @State private var systemInstallMessage: String?

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.gpg.title"),
            systemImage: "signature",
            tint: .green,
            body1: L10n.text("welcome.gpg.body")
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // 主开关 ——「启用 GPG 集成」勾选，绑同 settings 的 AppPreferences.gpgEnabled，
                // 用户在 wizard 这里勾上，之后任何 GPG 入口（签名 .siz、验签、密钥管理）才显现。
                GroupBox {
                    SettingsToggleRow(
                        title: L10n.text("welcome.gpg.enable"),
                        description: L10n.text("welcome.gpg.enable.description"),
                        isOn: $gpgEnabled
                    )
                }

                // 启用后才展示后端检测 / 安装提示 —— 没启用 = 用户明确选择「不用 GPG」，
                // 不该再 spam 安装提示。
                if gpgEnabled {
                    Text(L10n.text("welcome.gpg.backendCheck"))
                        .font(.title3.weight(.semibold))

                    BackendStatusBadge(
                        isOk: gpgAvailable,
                        okText: L10n.text("welcome.gpg.available"),
                        failText: L10n.text("welcome.gpg.missing"),
                        style: .prominent
                    )

                    if !gpgAvailable {
                        // gpg 完全缺失 → brew 命令 + GPGTools 备选链接。SystemInstallCommandView
                        // 内部承包 pasteboard + 开 Terminal，跟 Archive Pane 同款。
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                SystemInstallCommandView(
                                    title: L10n.text("settings.gpg.install.brew.title"),
                                    command: "brew install gnupg pinentry-mac",
                                    message: $systemInstallMessage
                                )

                                SettingsActionRow(
                                    title: L10n.text("settings.gpg.install.gpgsuite.title"),
                                    description: "https://gpgtools.org/",
                                    systemImage: "safari",
                                    buttonTitle: L10n.text("settings.gpg.install.gpgsuite.button")
                                ) {
                                    if let url = URL(string: "https://gpgtools.org/") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                    } else if !hasPinentryMac {
                        // gpg 装了但 pinentry-mac 缺 —— 能签名但不能 prompt passphrase（解密 / 解锁私钥会卡）。
                        // 黄字警告，不是错误。
                        Text(L10n.text("welcome.gpg.pinentry.warning"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }

                    // passphrase 声明 —— SimpleZip 不保管 GPG 私钥密码，全交给本机 gpg-agent + pinentry-mac。
                    // 这条信息长期 release note / 错误文案都要重复，让用户碰到 GPG 问题时知道找 gpg / pinentry 而不是 SimpleZip。
                    Text(L10n.text("welcome.gpg.passphraseNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: refreshStatus)
        .onChange(of: gpgEnabled) { enabled in
            // 切换开关时刷一次状态 —— 用户可能在外面装好 gpg 再回到 wizard 开开关。
            if enabled { refreshStatus() }
        }
    }

    private func refreshStatus() {
        gpgAvailable = GPGBackend.isAvailable()
        hasPinentryMac = GPGBackend.hasPinentryMac()
    }
}

/// 完成页：庆祝式 hero —— 渐变圆形大徽章弹簧弹入 + 大标题。
private struct WelcomeCompletionStep: View {
    @State private var celebrate = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                // 同上「box 不渐变」拍板 —— 完成徽章也用纯色。
                .background(Color.green, in: Circle())
                .shadow(color: .green.opacity(0.38), radius: 14, y: 5)
                .scaleEffect(celebrate ? 1 : 0.5)
                .opacity(celebrate ? 1 : 0)
                .accessibilityHidden(true)

            Text(L10n.text("welcome.completion.title"))
                .font(.largeTitle.weight(.bold))

            Text(L10n.text("welcome.completion.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // 0.4.2：当前版本亮点速览 + 指路「设置 → 帮助」（图文指南就在那）。
            VStack(alignment: .leading, spacing: 8) {
                highlightRow("magnifyingglass", "welcome.completion.highlight.search")
                highlightRow("arrow.left.arrow.right.circle", "welcome.completion.highlight.compare")
                highlightRow("lifepreserver", "welcome.completion.highlight.help")
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.12)) {
                celebrate = true
            }
        }
    }

    @ViewBuilder
    private func highlightRow(_ systemImage: String, _ key: String) -> some View {
        Label(L10n.text(key), systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
