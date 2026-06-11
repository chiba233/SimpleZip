//
//  GenerateRevocationSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 生成撤销证书的 sheet。
///
/// 撤销证书是「日后宣告密钥失效」的 emergency tool —— 一旦私钥被偷或丢失，把这份 `.asc` 文件发到 keyserver
/// 就能告诉所有用过这把公钥的人「别再信任了」。**应该在密钥还能用时就生成出来并安全保存到离线介质**，
/// 等到私钥真出事时再生成就来不及了。
///
/// 走 `gpg --gen-revoke <fpr>`。`gpg-agent + pinentry-mac` 会弹密码框收私钥 passphrase。SimpleZip 不接触 passphrase。
struct GenerateRevocationSheet: View {
    let key: GPGBackend.GPGKey
    @Binding var isPresented: Bool
    /// (reason, description, destination) 用户确认后回调。保存位置在本 sheet 里就选好，
    /// 调用方拿到完整目标 URL 直接写文件 —— 不再在生成成功后另弹一个突兀的 NSSavePanel。
    let onGenerate: (GPGBackend.GPGRevocationReason, String, URL) -> Void

    @State private var reason: GPGBackend.GPGRevocationReason = .none
    @State private var description: String = ""
    /// 撤销证书 `.asc` 的保存位置。onAppear 默认桌面 + 自动文件名，用户可「选择…」改。
    @State private var destinationURL: URL?

    /// 自动文件名：`<userID 去空格>_<短指纹>-revocation.asc`（与历史 NSSavePanel 默认名一致）。
    private var defaultFileName: String {
        "\(key.userID.replacingOccurrences(of: " ", with: "_"))_\(key.shortFingerprint)-revocation.asc"
    }

    var body: some View {
        // 0.4.2 体例统一：并入现代弹窗壳（hero + DialogSection + 钉底 DialogFooter）。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: "xmark.shield.fill",
                colors: [.orange, .red],
                title: L10n.text("settings.gpg.keys.revokeTitle"),
                subtitle: L10n.format("settings.gpg.keys.revokeSubject", key.userID, key.shortFingerprint)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 何时该生成 / 为什么提前生成的关键说明 —— 用户经常不知道这是干啥的。
                    Label(L10n.text("settings.gpg.keys.revokeIntro"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(0.1))
                        )

                    DialogSection(L10n.text("settings.gpg.keys.revokeReasonSection")) {
                        Picker("", selection: $reason) {
                            Text(L10n.text("settings.gpg.keys.revokeReason.none")).tag(GPGBackend.GPGRevocationReason.none)
                            Text(L10n.text("settings.gpg.keys.revokeReason.compromised")).tag(GPGBackend.GPGRevocationReason.compromised)
                            Text(L10n.text("settings.gpg.keys.revokeReason.superseded")).tag(GPGBackend.GPGRevocationReason.superseded)
                            Text(L10n.text("settings.gpg.keys.revokeReason.notUsed")).tag(GPGBackend.GPGRevocationReason.notUsed)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    DialogSection(L10n.text("settings.gpg.keys.revokeDescriptionLabel")) {
                        TextField(L10n.text("settings.gpg.keys.revokeDescriptionPlaceholder"), text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...5)
                        Text(L10n.text("settings.gpg.keys.revokeDescriptionHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // 保存位置：直接在 sheet 里选好，用户清楚 `.asc` 会落到哪 —— 不再事后另弹保存框。
                    DialogSection(L10n.text("settings.gpg.keys.revokeDestinationLabel")) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(destinationURL?.path ?? "")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.text("settings.gpg.keys.revokeChooseButton")) {
                                chooseDestination()
                            }
                        }
                    }

                    Label(L10n.text("settings.gpg.newKey.passphraseNote"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            DialogFooter(
                confirmTitle: L10n.text("settings.gpg.keys.revokeGenerateButton"),
                confirmDisabled: destinationURL == nil,
                confirm: {
                    guard let destinationURL else { return }
                    onGenerate(reason, description, destinationURL)
                    isPresented = false
                },
                cancel: { isPresented = false }
            ) {
                EmptyView()
            }
        }
        .frame(width: 560, height: 560)
        .onAppear {
            // 默认落到桌面（桌面取不到则退到用户主目录）+ 自动文件名。
            if destinationURL == nil {
                let directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
                destinationURL = directory.appendingPathComponent(defaultFileName)
            }
        }
    }

    /// 「选择…」：NSSavePanel 选目标 `.asc`，种子用当前默认目录 + 文件名。取消则保留原选择。
    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "asc") ?? .data]
        panel.message = L10n.text("settings.gpg.keys.revokeSavePanelMessage")
        if let current = destinationURL {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        } else {
            panel.nameFieldStringValue = defaultFileName
        }
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }
}
