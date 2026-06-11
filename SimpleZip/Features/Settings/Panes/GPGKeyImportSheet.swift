//
//  GPGKeyImportSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/03.
//
//  双击一个 `.gpg`/`.asc` 文件、嗅探出是**公钥/私钥导出**时弹的导入确认 sheet。
//
//  动机：`.gpg`/`.asc` 按后缀不保证是加密数据，可能是钥匙串材料。识别出钥匙串材料就不该「解密打开」，
//  而是把它当成「导入到钥匙串」——这里复用设置页 GPGPane 用的同一个 `GPGBackend.importKey` 后端，
//  只是把已经选好的文件预填进来，并让用户选进哪个 ring（用户 `~/.gnupg/` 共享 vs SimpleZip 私有）。
//
//  私钥 caveat（与 NewGPGKeySheet 一致）：gpg 的 secring 是全局的，即使选「SimpleZip 私有」，私钥仍写入
//  `~/.gnupg/private-keys-v1.d/`。且 **SimpleZip 不管理私钥 passphrase**——导入只是把密钥放进钥匙串，
//  用到它时由 gpg-agent/pinentry 负责解锁。
//

import SwiftUI

/// 待导入的钥匙串材料请求 —— 由 ContentView 嗅探（`GPGFileKind`）后赋值，驱动 `GPGKeyImportSheet`。
struct GPGKeyImportRequest: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    /// 嗅探到含私钥材料（`PRIVATE/SECRET KEY BLOCK` / `secret key packet`）—— UI 加重提示。
    let isPrivateKey: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct GPGKeyImportSheet: View {
    let request: GPGKeyImportRequest
    /// sheet 关闭回调（成功导入后延迟关 / 取消即时关）。
    let onClose: () -> Void

    @State private var ring: GPGBackend.GPGKeyringSource = .userKeyring
    @State private var isImporting = false
    @State private var resultMessage: String?
    @State private var didSucceed = false

    var body: some View {
        // 0.4.2 体例统一：GPG 全套 sheet 并入现代弹窗壳（DialogHero + DialogSection + 钉底 bar）。
        VStack(alignment: .leading, spacing: 0) {
            DialogHero(
                systemImage: request.isPrivateKey ? "key.fill" : "person.badge.key.fill",
                colors: request.isPrivateKey ? [.orange, .red] : [.teal, .blue],
                title: L10n.text(request.isPrivateKey ? "gpgImport.title.private" : "gpgImport.title.public"),
                subtitle: request.sourceURL.lastPathComponent
            )

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("gpgImport.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DialogSection(L10n.text("gpgImport.ring.label")) {
                    Picker("", selection: $ring) {
                        Text(L10n.text("gpgImport.ring.user")).tag(GPGBackend.GPGKeyringSource.userKeyring)
                        Text(L10n.text("gpgImport.ring.simpleZip")).tag(GPGBackend.GPGKeyringSource.simpleZipKeyring)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(isImporting || didSucceed)

                    if request.isPrivateKey {
                        Label(L10n.text("gpgImport.privateKey.note"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let resultMessage {
                    Label(resultMessage, systemImage: didSucceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(didSucceed ? Color.green : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            HStack {
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(L10n.text(didSucceed ? "button.close" : "button.cancel")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                if !didSucceed {
                    Button(L10n.text("gpgImport.action.import")) {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImporting)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 440)
    }

    private func performImport() {
        isImporting = true
        resultMessage = nil
        Task {
            do {
                _ = try await GPGBackend.importKey(from: request.sourceURL, into: ring)
                await MainActor.run {
                    isImporting = false
                    didSucceed = true
                    resultMessage = L10n.text("gpgImport.result.succeeded")
                }
                // 成功后短暂停留让用户看到反馈，再自动关闭。
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run { onClose() }
            } catch {
                await MainActor.run {
                    isImporting = false
                    resultMessage = L10n.format("gpgImport.result.failed", error.localizedDescription)
                }
            }
        }
    }
}
