//
//  ExtractOptionsForm.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/16.
//

import SwiftUI

struct ExtractOptionsForm<ExtraControls: View>: View {
    let title: String
    @Binding var destinationURL: URL
    @Binding var password: String
    @Binding var zipDecryptionMethod: ArchiveDecryptionMethod
    @Binding var showDetails: Bool
    let showsZipDecryptionMethod: Bool
    let zipEncryptionDetectionText: String?
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let extraControls: () -> ExtraControls

    // presetPasswordEnabled 是 bool，放 UserDefaults 安全，@AppStorage 自动响应改动。
    // 密码本身现在存在 Keychain，view 在 onAppear 时拉一次到 @State 缓冲。
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false
    @State private var presetPassword = ""

    /// 「使用预设密码」复选框的当前勾选状态。
    /// 默认值：调用方在 onAppear 时按 `request.password == preset` 同步一次，
    /// 这样能在「Finder 自动解压」「extractArchive 默认填入」「用户失败后改填别的」
    /// 三种入口下都给出合理初始值。
    @State private var usePresetPassword = false

    private var hasUsablePreset: Bool { presetPasswordEnabled && !presetPassword.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                extraControls()
                destinationRow
                if hasUsablePreset {
                    Toggle(L10n.text("button.usePresetPassword"), isOn: $usePresetPassword)
                        .help(L10n.text("button.usePresetPassword.help"))
                        .onChange(of: usePresetPassword) { newValue in
                            // 勾上：把预设值灌进 password binding；
                            // 取消：清空让用户重新输入（保留旧值会让人迷惑「这是哪个密码」）。
                            password = newValue ? presetPassword : ""
                        }
                }
                if !(hasUsablePreset && usePresetPassword) {
                    SecureField(L10n.text("extract.password.placeholder"), text: $password)
                }
                if showsZipDecryptionMethod {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(L10n.text("extract.decryptionMethod"), selection: $zipDecryptionMethod) {
                            ForEach(ArchiveDecryptionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }

                        if zipDecryptionMethod == .automatic, let zipEncryptionDetectionText {
                            Text(zipEncryptionDetectionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            // 故意不在 Form 上加 .controlSize(.small)：会让 Picker 被缩成 small，
            // 跟同 Form 里的裸 Text（SIZ 签名 / 解压目标 / 密码 placeholder 等 body 字号）大小不一致。
            // 底部按钮行有自己单独的 .controlSize(.small)，不受影响。

            HStack {
                ShowDetailsToggleButton(isOn: $showDetails)
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.extract"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .onAppear {
            // 从 Keychain 拉预设密码到本地 @State，view 打开后不会再变。
            presetPassword = AppPreferences.presetPassword
            // 入口约定：调用方在构造 request 时已经把预设密码填进 password。
            // 这里同步 toggle 的初始勾选状态，让用户视觉上一目了然「现在用的是预设」。
            if hasUsablePreset && password == presetPassword && !password.isEmpty {
                usePresetPassword = true
            }
        }
    }

    private var destinationRow: some View {
        HStack {
            Text(L10n.text("archive.destination"))
            Text(destinationURL.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("button.choose")) {
                chooseDestination()
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.extractTo")
        panel.prompt = L10n.text("button.choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL

        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }
}
