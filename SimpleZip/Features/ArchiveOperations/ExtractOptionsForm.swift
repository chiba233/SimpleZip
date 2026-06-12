//
//  ExtractOptionsForm.swift
//  SimpleZip
//
//  Created by Codex on 2026/05/16.
//

import SwiftUI

struct ExtractOptionsForm<ExtraControls: View, Drawers: View>: View {
    let title: String
    /// hero 副标题（通常是压缩包文件名）；nil 则只显示标题。
    var subtitle: String?
    @Binding var destinationURL: URL
    @Binding var password: String
    @Binding var zipDecryptionMethod: ArchiveDecryptionMethod
    @Binding var showDetails: Bool
    let showsZipDecryptionMethod: Bool
    let zipEncryptionDetectionText: String?
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder let extraControls: () -> ExtraControls
    /// 主卡片下方的抽屉区（#18 一级密度治理）：DialogDrawer 是独立卡片,与 DialogSection 同级,
    /// 不能塞进 extraControls(那会嵌进卡片里)。不需要抽屉的调用方传空闭包。
    @ViewBuilder let drawers: () -> Drawers

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
        // 0.4.1 重构：hero 头 + 自适应分区卡片 + 钉底 bar 操作栏。
        // 不用 grouped Form（List 贪婪布局要写死高度 → 内容少时一大片固定空白,用户点名的问题）；
        // DialogSection 高度贴内容,ScrollView 只设 maxHeight 防超屏。
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "doc.zipper",
                colors: [.blue, .cyan],
                title: title,
                subtitle: subtitle
            )

            HeightCappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection {
                        extraControls()
                        destinationRow
                        if hasUsablePreset {
                            DialogToggleRow(
                                title: L10n.text("button.usePresetPassword"),
                                systemImage: "key.fill",
                                tint: .orange,
                                pinsToTrailing: true,
                                isOn: $usePresetPassword
                            )
                            .help(L10n.text("button.usePresetPassword.help"))
                            .onChange(of: usePresetPassword) { newValue in
                                // 勾上：把预设值灌进 password binding；
                                // 取消：清空让用户重新输入（保留旧值会让人迷惑「这是哪个密码」）。
                                password = newValue ? presetPassword : ""
                            }
                        }
                        if !(hasUsablePreset && usePresetPassword) {
                            LabeledContent {
                                // 值列靠右对齐(用户拍板:「路径和密码靠右对齐,不要左对齐」)。
                                SecureField(L10n.text("extract.password.placeholder"), text: $password)
                                    .textFieldStyle(.roundedBorder)
                                    .dialogFieldEmphasis()
                                    .frame(maxWidth: 260)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } label: {
                                alignedRowLabel("archive.password", systemImage: "key.fill", tint: .orange)
                            }
                        }
                        if showsZipDecryptionMethod {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent {
                                    Picker("", selection: $zipDecryptionMethod) {
                                        ForEach(ArchiveDecryptionMethod.allCases) { method in
                                            Text(method.title).tag(method)
                                        }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                } label: {
                                    alignedRowLabel("extract.decryptionMethod", systemImage: "shield.lefthalf.filled", tint: .purple)
                                }

                                if zipDecryptionMethod == .automatic, let zipEncryptionDetectionText {
                                    Text(zipEncryptionDetectionText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    drawers()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                ShowDetailsToggleButton(isOn: $showDetails)
                Spacer()
                Button(action: cancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                Button(action: confirm) {
                    Label(L10n.text("button.extract"), systemImage: "doc.zipper")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        // 点空白释放输入框焦点（与创建对话框同款 UX 修复）。
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
        LabeledContent {
            // 值列靠右对齐(用户拍板:「路径和密码靠右对齐,不要左对齐」)。
            HStack(spacing: 8) {
                Text(destinationURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button(L10n.text("button.choose")) {
                    chooseDestination()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            alignedRowLabel("archive.destination", systemImage: "folder.fill", tint: .blue)
        }
    }

    /// 「保存到 / 密码 / 解密方式」三行的标签统一定宽 —— 标签长短不一时值列各自起步,
    /// 用户报「保存到和密码不齐」。定宽后值列垂直对齐(en 最长的 "Password (optional)" 也放得下)。
    /// 一级行彩色瓦片（无侧栏不降饱和）。
    private func alignedRowLabel(_ key: String, systemImage: String, tint: Color) -> some View {
        DialogRowLabel(L10n.text(key), systemImage: systemImage, tint: tint, width: 180)
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
