//
//  ExtractOptionsForm.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/16.
//

import SwiftUI

struct ExtractOptionsForm<ExtraControls: View>: View {
    let title: String
    /// hero 副标题（通常是压缩包文件名）；nil 则只显示标题。
    var subtitle: String?
    /// sheet 高度 —— grouped Form（List）是贪婪布局，必须给定高；内容多的入口（.siz 带签名行）传大值。
    var preferredHeight: CGFloat = 400
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
        // 0.4.1 重构：与创建对话框同一套现代体例 —— hero 头 + grouped Form + 钉底 bar 操作栏。
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Form {
                Section {
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
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                ShowDetailsToggleButton(isOn: $showDetails)
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.extract"), action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(height: preferredHeight)
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
