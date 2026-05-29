//
//  GeneralPane.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 通用偏好：界面语言、启动位置、默认覆盖行为、删除前确认。
///
/// 设计上每个 pane 只持有自己用到的 @AppStorage：
/// SwiftUI 会自动让所有引用同一个 key 的视图共享值，不需要从父视图传 binding 下来，
/// 同时父 SettingsView 也不再被 30+ 个 @AppStorage 撑爆。
struct GeneralPane: View {
    @AppStorage(AppPreferences.Key.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.Key.startupLocation) private var startupLocation = StartupLocation.home.rawValue
    @AppStorage(AppPreferences.Key.rememberLastFolder) private var rememberLastFolder = true
    @AppStorage(AppPreferences.Key.overwriteBehavior) private var overwriteBehavior = OverwriteBehavior.ask.rawValue
    @AppStorage(AppPreferences.Key.confirmBeforeDeletingFiles) private var confirmBeforeDeletingFiles = true
    @AppStorage(AppPreferences.Key.finderOpenAutoExtract) private var finderOpenAutoExtract = false
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
                    Picker("", selection: $startupLocation) {
                        ForEach(StartupLocation.allCases) { location in
                            Text(location.title).tag(location.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 200, alignment: .trailing)
                }

                SettingsToggleRow(
                    title: L10n.text("settings.rememberLastFolder"),
                    description: L10n.text("settings.rememberLastFolder.description"),
                    isOn: $rememberLastFolder
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
                    } else {
                        // 关掉开关 = 同时清掉 Keychain 里残留的密码；
                        // 不留陈旧凭据，符合「关闭功能=完全停用」的用户预期。
                        AppPreferences.clearPresetPassword()
                        presetPasswordBuffer = ""
                        savedPresetPassword = ""
                        showsPresetPassword = false
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
        AppPreferences.setPresetPassword(presetPasswordBuffer)
        savedPresetPassword = presetPasswordBuffer
        presetPasswordRevealMessage = L10n.text("settings.presetPassword.saved")
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
