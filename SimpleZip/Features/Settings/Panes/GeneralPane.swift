//
//  GeneralPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI
import AppKit

/// 通用偏好：界面语言、启动位置、默认覆盖行为、删除前确认。
///
/// 设计上每个 pane 只持有自己用到的 @AppStorage：
/// SwiftUI 会自动让所有引用同一个 key 的视图共享值，不需要从父视图传 binding 下来，
/// 同时父 SettingsView 也不再被 30+ 个 @AppStorage 撑爆。
struct GeneralPane: View {
    @AppStorage(AppPreferences.Key.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.Key.startupLocation) private var startupLocation = StartupLocation.home.rawValue
    /// 当前活跃的 custom 路径，跟 history 头部 + Menu label 文案绑在一起。
    @AppStorage(AppPreferences.Key.startupCustomLocationPath) private var startupCustomLocationPath = ""
    @AppStorage(AppPreferences.Key.rememberLastFolder) private var rememberLastFolder = true
    @AppStorage(AppPreferences.Key.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = false

    /// custom 历史快照（@AppStorage 不能直接绑 array），onAppear 拉一次，每次操作后 reload。
    @State private var startupCustomLocationHistory: [URL] = []

    /// 用户在 Menu 里点了某项，但对应目录已经不存在 —— 在 Picker 下显示红字提示，并不提交选择。
    @State private var startupLocationErrorMessage: String?
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.ask.rawValue
    @AppStorage(AppPreferences.Key.confirmBeforeDeletingFiles) private var confirmBeforeDeletingFiles = true
    @AppStorage(AppPreferences.Key.finderOpenAutoExtract) private var finderOpenAutoExtract = false
    @AppStorage(AppPreferences.Key.openExternalInNewTab) private var openExternalInNewTab = true
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false

    @State private var languageMessage: String?

    /// 「预设密码」编辑器的本地缓冲区。
    /// 用户键入只改这里，不会立即写入 Keychain —— 必须显式点「保存」才落盘。
    /// 关闭设置窗口（视图被 dismiss）会丢失未保存的修改，与 macOS Settings 习惯一致。
    @State private var presetPasswordBuffer = ""

    /// 当前 Keychain 里实际保存的预设密码（用来判断「未改动」状态以禁用保存按钮）。
    @State private var savedPresetPassword = ""

    /// 控制密码框显示明文还是 SecureField。
    /// 必须经过 `PresetPasswordStore.requestReveal()` 走 Touch ID 认证才能切到 true，
    /// 否则一直保持掩码 —— 「点眼睛就明文」会让肩窥变得很容易。
    @State private var showsPresetPassword = false
    @State private var presetPasswordRevealMessage: String?

    var body: some View {
        Form {
            Section(L10n.text("settings.section.general")) {
                SettingsControlRow(
                    title: L10n.text("settings.language"),
                    description: L10n.text("settings.language.description")
                ) {
                    Picker("", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // 之前是 .frame(width: 220)，长翻译会被截断。
                    // 改为 minWidth 后 Picker 会按内容自适应，同时不至于退化成极窄。
                    .frame(minWidth: 200, alignment: .trailing)
                    .onChange(of: appLanguage) { newValue in
                        applyLanguage(newValue)
                    }
                }

                if let languageMessage {
                    Text(languageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsControlRow(
                    title: L10n.text("settings.startupLocation"),
                    description: L10n.text("settings.startupLocation.description")
                ) {
                    // 用 Menu 而不是 Picker —— Picker 在「下拉项 label」和「已选状态 label」
                    // 用同一个 Text，没办法让自定义位置在选中时显示文件夹名、在下拉里仍是「自定义位置」。
                    // Menu 把 label（已选状态展示）和 Button content（下拉项）分开，两边各自配文案。
                    Menu {
                        // 系统目录段
                        ForEach(visibleSystemLocations) { location in
                            Button(location.title) {
                                selectSystemStartupLocation(location)
                            }
                        }
                        // custom 历史段，用 lastPathComponent 作为显示文案
                        if !visibleCustomURLs.isEmpty {
                            Divider()
                            ForEach(visibleCustomURLs, id: \.self) { url in
                                Button(url.lastPathComponent) {
                                    selectCustomStartupLocation(url)
                                }
                            }
                        }
                        // 「添加自定义位置…」操作 —— 永远在最下面，弹出文件夹选择面板
                        Divider()
                        Button(L10n.text("settings.startup.addCustom")) {
                            addCustomStartupLocation()
                        }
                    } label: {
                        Text(displayedStartupLocationTitle)
                    }
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }

                if let startupLocationErrorMessage {
                    Text(startupLocationErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.rememberLastFolder"),
                    description: L10n.text("settings.rememberLastFolder.description"),
                    isOn: $rememberLastFolder
                )

                SettingsToggleRow(
                    title: L10n.text("settings.checkForUpdatesOnLaunch"),
                    description: L10n.text("settings.checkForUpdatesOnLaunch.description"),
                    isOn: $checkForUpdatesOnLaunch
                )
            }

            Section(L10n.text("settings.section.defaults")) {
                SettingsControlRow(
                    title: L10n.text("settings.overwriteBehavior"),
                    description: L10n.text("settings.overwriteBehavior.description")
                ) {
                    Picker("", selection: $overwriteBehavior) {
                        ForEach(OverwriteBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.confirmBeforeDeletingFiles"),
                    description: L10n.text("settings.confirmBeforeDeletingFiles.description"),
                    isOn: $confirmBeforeDeletingFiles
                )

                SettingsToggleRow(
                    title: L10n.text("settings.finderOpenAutoExtract"),
                    description: L10n.text("settings.finderOpenAutoExtract.description"),
                    isOn: $finderOpenAutoExtract
                )

                SettingsToggleRow(
                    title: L10n.text("settings.openExternalInNewTab"),
                    description: L10n.text("settings.openExternalInNewTab.description"),
                    isOn: $openExternalInNewTab
                )
            }

            Section(L10n.text("settings.presetPasswordEnabled")) {
                SettingsToggleRow(
                    title: L10n.text("settings.presetPasswordEnabled"),
                    description: L10n.text("settings.presetPasswordEnabled.description"),
                    isOn: $presetPasswordEnabled
                )
                .onChange(of: presetPasswordEnabled) { isOn in
                    if isOn {
                        // 用户刚打开开关：现在才碰 Keychain，触发一次可能的访问授权对话框。
                        // 这是预期的行为 —— 用户主动启用了这个功能。
                        reloadPresetPasswordBuffer()
                        presetPasswordRevealMessage = nil
                    } else {
                        // 关掉开关 = 同时清掉 Keychain 里残留的密码；
                        // 不留陈旧凭据，符合「关闭功能=完全停用」的用户预期。
                        // 如果 Keychain 拒绝删除（access 被撤销 / 锁定），开关回弹到 ON 并提示，
                        // 否则会出现「UI 显示关闭但下次启动旧密码还在」的不一致状态。
                        if AppPreferences.clearPresetPassword() {
                            presetPasswordBuffer = ""
                            savedPresetPassword = ""
                            showsPresetPassword = false
                            presetPasswordRevealMessage = nil
                        } else {
                            DispatchQueue.main.async {
                                presetPasswordEnabled = true
                            }
                            presetPasswordRevealMessage = L10n.text("settings.presetPassword.clearFailed")
                        }
                    }
                }

                presetPasswordEditor
                    .opacity(presetPasswordEnabled ? 1 : 0.55)
                    .disabled(!presetPasswordEnabled)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .onAppear {
            // 把 custom 历史从 UserDefaults 拉一份到 @State，下面所有 menu / cap 计算从它读。
            startupCustomLocationHistory = AppPreferences.startupCustomLocationHistory
            // 关键：只有用户主动开了预设密码功能时才碰 Keychain。
            // 这样默认情况下打开「通用」设置不会触发 macOS 的「允许 SimpleZip 访问钥匙串」对话框。
            // 真正启用了预设的用户，每次 app 启动后最多遇到一次（同进程后续 load 走缓存）。
            if presetPasswordEnabled {
                reloadPresetPasswordBuffer()
            }
        }
        .onDisappear {
            // 离开设置 = 把未保存的修改丢掉、把显示状态重置为掩码。
            // 防止用户「点显示 → 切走 → 再切回」时旁人看到明文。
            showsPresetPassword = false
            presetPasswordBuffer = savedPresetPassword
            presetPasswordRevealMessage = nil
        }
    }

    /// 预设密码编辑行。
    ///
    /// 布局：三栏 HStack —— 密码框 / 眼睛按钮 / 保存按钮。
    /// 之前用过 `.overlay` 把眼睛塞进 TextField 内部，但 SecureField 的内容区域
    /// 不会因 overlay 而避让，结果输入的圆点跟眼睛重叠 —— 看着特别丑。
    /// 改回三栏后所有元素各自独立宽度，HStack 默认 `.center` 自动垂直居中，
    /// 同时通过外层 `controlSize(.small)` 让三者高度一致。
    private var presetPasswordEditor: some View {
        SettingsControlRow(
            title: L10n.text("settings.presetPassword"),
            description: L10n.text("settings.presetPassword.description")
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                // alignmentGuide 解释见 eye / Save 注释：
                // macOS .roundedBorder SecureField 视觉中心比几何中心高 ~3pt（顶部内 padding > 底部），
                // 默认 HStack center 对齐让 eye/Save 看着偏下。这里把 eye/Save 的对齐点显式下移 3pt
                // → HStack 反向把它们位置上移 3pt，跟 field 的视觉中心齐平。
                HStack(spacing: 8) {
                    Group {
                        if showsPresetPassword {
                            TextField(
                                "",
                                text: $presetPasswordBuffer,
                                prompt: Text(L10n.text("settings.presetPassword.placeholder"))
                                    .foregroundColor(.secondary)
                            )
                        } else {
                            SecureField(
                                "",
                                text: $presetPasswordBuffer,
                                prompt: Text(L10n.text("settings.presetPassword.placeholder"))
                                    .foregroundColor(.secondary)
                            )
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                    Button {
                        togglePresetPasswordVisibility()
                    } label: {
                        Image(systemName: showsPresetPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 22, height: 22)
                    .help(L10n.text("archive.showPassword"))
                    .alignmentGuide(VerticalAlignment.center) { dimensions in
                        // 返回值是「本视图哪个 Y 算作对齐参考点」（从视图顶部算起）。
                        // 默认是几何中心 dimensions[.center]；这里加 3 等价于「告诉 HStack 把
                        // 本视图的 (几何中心 + 3) 当作中心点对齐」，实际渲染就是把视图上移 3pt。
                        dimensions[VerticalAlignment.center] + 3
                    }

                    Button(L10n.text("button.save")) {
                        savePresetPassword()
                    }
                    .disabled(presetPasswordBuffer == savedPresetPassword)
                    .alignmentGuide(VerticalAlignment.center) { dimensions in
                        dimensions[VerticalAlignment.center] + 3
                    }
                }
                if let presetPasswordRevealMessage {
                    Text(presetPasswordRevealMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reloadPresetPasswordBuffer() {
        savedPresetPassword = AppPreferences.presetPassword
        presetPasswordBuffer = savedPresetPassword
        showsPresetPassword = false
    }

    private func savePresetPassword() {
        // 旧版本无条件报「已保存」，但 Keychain 写失败的情况（权限被拒、磁盘满、ad-hoc 签名被换）
        // 完全被吞掉，用户重启后发现密码丢了一头雾水。这里看返回值给真实反馈。
        let success = AppPreferences.setPresetPassword(presetPasswordBuffer)
        if success {
            savedPresetPassword = presetPasswordBuffer
            presetPasswordRevealMessage = L10n.text("settings.presetPassword.saved")
        } else {
            // 不更新 savedPresetPassword —— 保留旧值，让 Save 按钮继续可用，用户可重试。
            presetPasswordRevealMessage = L10n.text("settings.presetPassword.saveFailed")
        }
    }

    /// 切换密码显示状态。
    /// - 从掩码切到明文：必须走 Touch ID / Mac 解锁口令；
    /// - 从明文切回掩码：无需认证（这是隐藏，更安全的方向）。
    private func togglePresetPasswordVisibility() {
        if showsPresetPassword {
            showsPresetPassword = false
            return
        }
        Task {
            let reason = L10n.text("settings.presetPassword.revealReason")
            let granted = await PresetPasswordStore.requestReveal(reason: reason)
            await MainActor.run {
                if granted {
                    showsPresetPassword = true
                    presetPasswordRevealMessage = nil
                } else {
                    presetPasswordRevealMessage = L10n.text("settings.presetPassword.revealFailed")
                }
            }
        }
    }

    /// Menu 总项数上限（系统目录 + custom 历史 + 「添加自定义」action）。
    /// 超过 → 优先裁 custom 历史末尾的项（最旧的 MRU 先掉），不动系统目录。
    private static let startupLocationMenuCap = 10

    /// 永远列在 Menu 里的系统目录段（顺序就是显示顺序）。
    private var visibleSystemLocations: [StartupLocation] {
        [.home, .downloads, .desktop, .documents, .movies, .music, .pictures, .lastFolder]
    }

    /// custom 历史段实际显示的 URL 列表。
    /// 算法：(系统目录数 + custom 历史数 + 1 个 Add action) ≤ cap；
    /// 不够就从历史末尾裁掉（MRU 最旧的先掉）。
    private var visibleCustomURLs: [URL] {
        let nonCustomCount = visibleSystemLocations.count + 1 // +1 for Add action
        let slotsForCustom = max(0, Self.startupLocationMenuCap - nonCustomCount)
        return Array(startupCustomLocationHistory.prefix(slotsForCustom))
    }

    /// Menu 收起状态显示的文字。
    /// - 普通分支：枚举自带 title；
    /// - .custom 且活跃路径存在：显示文件夹名；
    /// - .custom 但路径失效：仍显示「自定义位置」原文案，让用户知道当前选择已失效。
    private var displayedStartupLocationTitle: String {
        let current = StartupLocation(rawValue: startupLocation) ?? .home
        if current == .custom,
           !startupCustomLocationPath.isEmpty,
           FileManager.default.fileExists(atPath: startupCustomLocationPath) {
            return URL(fileURLWithPath: startupCustomLocationPath).lastPathComponent
        }
        return current.title
    }

    // MARK: - Menu 行为

    /// 用户点了系统目录段里的某项。检查它对应的实际目录是否存在 ——
    /// 不存在 = 拒绝提交 + 红字提示；存在 = 写 startupLocation 并清掉错误。
    private func selectSystemStartupLocation(_ location: StartupLocation) {
        // .lastFolder 没值（用户首次启动还没记任何文件夹）算正常状态，由 defaultStartupURL
        // 回落到 home，不弹错误。
        if location != .lastFolder,
           let url = AppPreferences.resolvedURL(for: location),
           !FileManager.default.fileExists(atPath: url.path) {
            startupLocationErrorMessage = L10n.text("settings.startup.folderUnavailable")
            return
        }
        startupLocation = location.rawValue
        startupLocationErrorMessage = nil
    }

    /// 用户点了 custom 历史段里的某项（之前挑过的路径）。
    /// 路径还在 = 切到这个 custom；不在 = 红字提示，同时从历史里清掉这条「死路径」。
    private func selectCustomStartupLocation(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            startupLocationErrorMessage = L10n.text("settings.startup.folderUnavailable")
            AppPreferences.removeCustomStartupLocation(url)
            startupCustomLocationHistory = AppPreferences.startupCustomLocationHistory
            return
        }
        AppPreferences.recordCustomStartupLocation(url, keepingAtMost: customHistoryCapacity)
        startupCustomLocationHistory = AppPreferences.startupCustomLocationHistory
        startupLocation = StartupLocation.custom.rawValue
        startupLocationErrorMessage = nil
    }

    /// 「添加自定义位置…」action：弹文件夹选择面板。
    private func addCustomStartupLocation() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.openFolder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !startupCustomLocationPath.isEmpty,
           FileManager.default.fileExists(atPath: startupCustomLocationPath) {
            panel.directoryURL = URL(fileURLWithPath: startupCustomLocationPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        AppPreferences.recordCustomStartupLocation(url, keepingAtMost: customHistoryCapacity)
        startupCustomLocationHistory = AppPreferences.startupCustomLocationHistory
        startupLocation = StartupLocation.custom.rawValue
        startupLocationErrorMessage = nil
    }

    /// 历史最大可保留项数（=总 cap - 系统目录数 - Add action 数）。
    /// 跟 visibleCustomURLs 的 slotsForCustom 算法一致 —— 录入端就裁好，避免 history 越攒越大。
    private var customHistoryCapacity: Int {
        max(0, Self.startupLocationMenuCap - visibleSystemLocations.count - 1)
    }

    /// 切换界面语言：写到 AppleLanguages、提示用户重启生效。
    ///
    /// `removeObject` 分支留给「跟随系统」选项 —— 让 AppleLanguages 回到系统默认。
    private func applyLanguage(_ rawValue: String) {
        let language = AppLanguage(rawValue: rawValue) ?? .system
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let restartHint = L10n.text("settings.languageRestartHint")
        DispatchQueue.main.async {
            languageMessage = restartHint
        }
    }
}
