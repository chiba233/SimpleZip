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
    // 0.2.0 新增进向导的浏览 / 视图设置。
    @AppStorage(AppPreferences.Key.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(AppPreferences.Key.hiddenDetectionMode) private var hiddenDetectionMode = FileBrowserOutline.HiddenDetectionMode.dotfilesOnly.rawValue
    @AppStorage(AppPreferences.Key.hiddenGroupCollapseMode) private var hiddenGroupCollapseMode = FileBrowserOutline.CollapseMode.alwaysCollapsed.rawValue
    @AppStorage(AppPreferences.Key.rowDensity) private var rowDensity = FileBrowserOutline.RowDensity.standard.rawValue
    @AppStorage(AppPreferences.Key.fileGroupingScope) private var fileGroupingScope = BrowserGrouping.GroupingScope.global.rawValue
    @AppStorage(AppPreferences.Key.fileGroupBy) private var fileGroupBy = BrowserGrouping.GroupBy.none.rawValue

    @State private var currentStep: Int = 0

    /// 总步数：0 = backup restore，1 = version check，2 = intro，3..14 = 实际设置步骤（含 GPG），15 = completion。
    /// 进度条只展示「设置类」步骤（3..14 → 1/12..12/12），backup / version check / intro / completion 不计入。
    /// GPG 单独成步是因为它是「特殊功能 / 可选禁用」性质，跟 7-Zip / RAR 这类「必装后端」语义不同，
    /// 用户得明确做出 opt-in / opt-out 的决定 —— 塞进 backend 步骤里会让用户误以为「必须装」。
    private let totalSteps = 16
    private let settingStepCount = 12
    private let firstSettingStepIndex = 3

    /// 「取消」按钮的二次确认 alert flag。
    /// 不直接关 sheet：用户可能误点 ESC / 关闭，已经做出的选项可能想留也想看后面的步骤。
    @State private var showsCancelConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            progressHeader

            Divider()

            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Header

    private var progressHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("welcome.window.title"))
                    .font(.headline)
                if currentStep >= firstSettingStepIndex && currentStep < firstSettingStepIndex + settingStepCount {
                    Text(L10n.format("welcome.stepLabel", currentStep - firstSettingStepIndex + 1, settingStepCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            WelcomeBackupRestoreStep()
        case 1:
            WelcomeVersionCheckStep()
        case 2:
            WelcomeIntroStep()
        case 3:
            WelcomeLanguageStep(appLanguage: $appLanguage)
        case 4:
            WelcomeStartupLocationStep(startupLocation: $startupLocation)
        case 5:
            WelcomeOverwriteStep(overwriteBehavior: $overwriteBehavior)
        case 6:
            WelcomePresetPasswordStep(enabled: $presetPasswordEnabled)
        case 7:
            WelcomeFinderAutoExtractStep(enabled: $finderOpenAutoExtract)
        case 8:
            WelcomeFileAssociationsStep()
        case 9:
            WelcomeHiddenFilesStep(
                showHidden: $showHiddenFiles,
                detectionMode: $hiddenDetectionMode,
                collapseMode: $hiddenGroupCollapseMode
            )
        case 10:
            WelcomeRowDensityStep(rowDensity: $rowDensity)
        case 11:
            WelcomeGroupingStep(
                scope: $fileGroupingScope,
                fileGroupBy: $fileGroupBy
            )
        case 12:
            WelcomeSafetyStep(
                suspiciousPathPolicy: suspiciousPathPolicy,
                symbolicLinkPolicy: symbolicLinkPolicy,
                activeContentOpenPolicy: activeContentOpenPolicy
            )
        case 13:
            WelcomeBackendStep()
        case 14:
            WelcomeGPGStep()
        default:
            WelcomeCompletionStep()
        }
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
                    currentStep -= 1
                }
            }

            if currentStep < totalSteps - 1 {
                Button(L10n.text("welcome.button.next")) {
                    currentStep += 1
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.text("welcome.button.finish")) {
                    AppPreferences.markWelcomeAssistantCompleted()
                    onComplete()
                }
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
    let body1: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(body1)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
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

private struct WelcomeIntroStep: View {
    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.intro.title"),
            body1: L10n.text("welcome.intro.body")
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                Text(L10n.text("welcome.intro.note"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct WelcomeLanguageStep: View {
    @Binding var appLanguage: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.language.title"),
            body1: L10n.text("welcome.language.body")
        ) {
            Picker("", selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }
}

private struct WelcomeStartupLocationStep: View {
    @Binding var startupLocation: String

    /// 当 `startupLocation == .custom` 时显示的具体路径 —— 从 UserDefaults 读，避免又开一个 @AppStorage。
    @State private var customPath: String = AppPreferences.startupCustomLocationURL?.path ?? ""

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.startupLocation.title"),
            body1: L10n.text("welcome.startupLocation.body")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $startupLocation) {
                    ForEach(simpleLocations, id: \.rawValue) { location in
                        Text(location.title).tag(location.rawValue)
                    }
                    if !customPath.isEmpty {
                        Text(customRowTitle).tag(StartupLocation.custom.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)

                Button(L10n.text("welcome.startupLocation.pickCustom")) {
                    pickCustomLocation()
                }
            }
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

private struct WelcomeOverwriteStep: View {
    @Binding var overwriteBehavior: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.overwrite.title"),
            body1: L10n.text("welcome.overwrite.body")
        ) {
            Picker("", selection: $overwriteBehavior) {
                ForEach(OverwriteBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
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
            body1: L10n.text("welcome.fileAssociations.body")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(L10n.text("welcome.fileAssociations.setAll")) {
                    setAllDefaults()
                }

                VStack(spacing: 0) {
                    ForEach(ArchiveAssociationService.supportedAssociations) { association in
                        FileAssociationRow(
                            association: association,
                            currentDefaultApp: associationStatus[association.id] ?? L10n.text("settings.association.loading"),
                            isSimpleZipDefault: ArchiveAssociationService.isSimpleZipDefault(for: association)
                        ) {
                            setDefault(for: association)
                        }
                        if association.id != ArchiveAssociationService.supportedAssociations.last?.id {
                            Divider().padding(.leading, 52)
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
        }
        .onAppear(perform: refresh)
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

/// 隐藏文件步骤：显示隐藏文件开关 + （开启后）什么算隐藏 + 隐藏组折叠策略。
private struct WelcomeHiddenFilesStep: View {
    @Binding var showHidden: Bool
    @Binding var detectionMode: String
    @Binding var collapseMode: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.hiddenFiles.title"),
            body1: L10n.text("welcome.hiddenFiles.body")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L10n.text("settings.showHiddenFiles"), isOn: $showHidden)
                    .toggleStyle(.switch)

                if showHidden {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("settings.hiddenDetection"))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $detectionMode) {
                            ForEach(FileBrowserOutline.HiddenDetectionMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("settings.hiddenGroupCollapse"))
                            .font(.subheadline.weight(.medium))
                        Picker("", selection: $collapseMode) {
                            ForEach(FileBrowserOutline.CollapseMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    }
                }
            }
        }
    }
}

/// 列表大小（行密度）步骤。
private struct WelcomeRowDensityStep: View {
    @Binding var rowDensity: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.rowDensity.title"),
            body1: L10n.text("welcome.rowDensity.body")
        ) {
            Picker("", selection: $rowDensity) {
                ForEach(FileBrowserOutline.RowDensity.allCases, id: \.self) { density in
                    Text(density.title).tag(density.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }
}

/// 分组默认步骤：分组范围（全局 / 按文件夹）+ 文件浏览默认分组。
/// 不含「压缩包浏览默认分组」—— 那是给打开压缩包后内部浏览用的，首启向导里用户还没打开任何压缩包，
/// 放这里只会让人困惑（用户反馈「分组方式这个选项在欢迎助手里毫无价值」）。需要时在 设置 → 视图 里有。
private struct WelcomeGroupingStep: View {
    @Binding var scope: String
    @Binding var fileGroupBy: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.grouping.title"),
            body1: L10n.text("welcome.grouping.body")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                labeledPicker(L10n.text("settings.grouping.scope"), selection: $scope) {
                    ForEach(BrowserGrouping.GroupingScope.allCases, id: \.self) { value in
                        Text(value.title).tag(value.rawValue)
                    }
                }
                labeledPicker(L10n.text("settings.grouping.fileDefault"), selection: $fileGroupBy) {
                    ForEach(BrowserGrouping.GroupBy.allCases, id: \.self) { value in
                        Text(value.title).tag(value.rawValue)
                    }
                }
            }
        }
    }

    private func labeledPicker<Content: View>(
        _ label: String,
        selection: Binding<String>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .fixedSize()
        }
    }
}

private struct WelcomeSafetyStep: View {
    let suspiciousPathPolicy: String
    let symbolicLinkPolicy: String
    let activeContentOpenPolicy: String

    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.safety.title"),
            body1: L10n.text("welcome.safety.body")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                row(label: L10n.text("welcome.safety.suspiciousPath"), policy: suspiciousPathPolicy)
                row(label: L10n.text("welcome.safety.symlink"), policy: symbolicLinkPolicy)
                row(label: L10n.text("welcome.safety.activeContent"), policy: activeContentOpenPolicy)
            }
        }
    }

    private func row(label: String, policy: String) -> some View {
        let decision = ArchiveSecurityDecision(rawValue: policy) ?? .ask
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(L10n.format("welcome.safety.currentValue", decision.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            body1: L10n.text("welcome.backend.body")
        ) {
            // GroupBox + SettingsControlRow / SettingsActionRow 是 Settings 同款组件 ——
            // 助手里直接复用让视觉一致，避免「快速开始」UI 跟「偏好设置」差太多的违和感。
            VStack(alignment: .leading, spacing: 22) {
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

private struct WelcomeCompletionStep: View {
    var body: some View {
        WelcomeStepShell(
            title: L10n.text("welcome.completion.title"),
            body1: L10n.text("welcome.completion.body")
        ) {
            HStack {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }
}
