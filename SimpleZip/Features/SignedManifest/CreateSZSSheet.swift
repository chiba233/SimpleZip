//
//  CreateSZSSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import AppKit
import SwiftUI

/// 创建 `.szs` 签名清单的 sheet。
///
/// UX：用户先选「根目录」（payload root），再添加该目录下要签名的文件（NSOpenPanel 多选）；
/// 文件 path 会被换算成相对 payload root 的 relativePath。最后选签名密钥 + 输出位置 → 跑 `SZSArchive.create`。
///
/// 右键入口（FileTable → 「创建签名清单」）走 `initialPrefill`，预填 payload root + files，免去用户重新挑。
/// 菜单 File → Create Signed Manifest 入口走 `initialPrefill = nil`，从空白开始。
struct CreateSZSSheet: View {
    /// 右键预填值（payload root + 已选文件）。nil = 空白 sheet。
    var initialPrefill: ArchiveBrowserModel.CreateSZSPrefill?
    let onClose: () -> Void

    @State private var payloadRoot: URL?
    @State private var selectedFiles: [URL] = []
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var signingKeyFingerprint: String = ""
    @State private var outputURL: URL?
    @State private var availableSecretKeys: [GPGBackend.GPGKey] = []
    @State private var isCreating = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let labelColumnWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("szs.create.title"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                payloadRootRow
                filesRow
                titleRow
                descriptionRow
                signingKeyRow
                outputRow
            }

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.text("szs.create.cancelButton"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("szs.create.createButton")) {
                    runCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            applyPrefillIfAny()
            seedDefaultSigningKey()
            loadAvailableKeysAsync()
        }
    }

    // MARK: - 子行布局

    private func labelText(_ key: String) -> some View {
        Text(L10n.text(key))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: labelColumnWidth, alignment: .trailing)
    }

    private var payloadRootRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.payloadRoot")
            Text(payloadRoot?.path ?? L10n.text("szs.create.payloadRoot.placeholder"))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("szs.create.payloadRoot.choose")) {
                choosePayloadRoot()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var filesRow: some View {
        HStack(alignment: .top, spacing: 8) {
            labelText("szs.create.filesLabel")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.format("szs.create.fileCount", selectedFiles.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("szs.create.addFiles")) {
                        chooseFiles()
                    }
                    .controlSize(.small)
                    .disabled(payloadRoot == nil)
                    .help(L10n.text("szs.create.addFiles.help"))
                }
                if !selectedFiles.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(selectedFiles, id: \.self) { url in
                                HStack {
                                    Text(relativePath(for: url))
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        selectedFiles.removeAll { $0 == url }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.titleLabel")
            TextField(L10n.text("szs.create.titlePlaceholder"), text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var descriptionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.descriptionLabel")
            TextField(L10n.text("szs.create.descriptionPlaceholder"), text: $description)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var signingKeyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.signingKeyLabel")
            Menu {
                Button(L10n.text("szs.create.signingKey.auto")) {
                    signingKeyFingerprint = ""
                }
                if !availableSecretKeys.isEmpty {
                    Divider()
                    ForEach(availableSecretKeys) { key in
                        Button("\(key.userID) · \(key.shortFingerprint)") {
                            signingKeyFingerprint = key.fingerprint
                        }
                    }
                }
            } label: {
                Text(signingKeyLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var signingKeyLabel: String {
        if signingKeyFingerprint.isEmpty {
            return L10n.text("szs.create.signingKey.auto")
        }
        if let matched = availableSecretKeys.first(where: { $0.fingerprint == signingKeyFingerprint }) {
            return "\(matched.userID) · \(matched.shortFingerprint)"
        }
        return L10n.format("archive.gpgSign.key.missingFingerprint", String(signingKeyFingerprint.suffix(16)))
    }

    private var outputRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.outputLocation")
            Text(outputURL?.path ?? L10n.text("szs.create.outputLocation.placeholder"))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("szs.create.outputLocation.choose")) {
                chooseOutput()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private var canCreate: Bool {
        payloadRoot != nil && !selectedFiles.isEmpty && outputURL != nil && !isCreating
    }

    private func applyPrefillIfAny() {
        guard let prefill = initialPrefill else { return }
        payloadRoot = prefill.payloadRoot
        // 右键选中里可能含目录 → 递归展开成普通文件，让文件计数 / 列表准确（create 也会再展开兜底）。
        selectedFiles = SZSArchive.expandToRegularFiles(prefill.files)
        // 默认输出 = `<payloadRoot 文件夹名>.szs`，落在 payloadRoot **里**。
        // 例：payload root 是 `/Users/yumeka/Desktop` → 输出 `/Users/yumeka/Desktop/Desktop.szs`。
        // 名字跟所在文件夹同名更有「这是这个文件夹的签名清单」的语义；之前默认 `manifest.szs` 太通用 —— 多个文件夹同时签
        // 会全叫一样名字。父目录别 `.deletingLastPathComponent()` 跳出去（之前的 bug：Desktop 的父是 home，输出会落到
        // `/Users/yumeka/Desktop.szs` 而不是 Desktop 里）。
        outputURL = prefill.payloadRoot.appendingPathComponent(prefill.payloadRoot.lastPathComponent + ".szs")
    }

    private func seedDefaultSigningKey() {
        let defaultFp = AppPreferences.gpgDefaultSigningKeyFingerprint
        if !defaultFp.isEmpty {
            signingKeyFingerprint = defaultFp
        }
    }

    private func loadAvailableKeysAsync() {
        guard AppPreferences.gpgEnabled, GPGBackend.isAvailable() else { return }
        Task { @MainActor in
            if let loaded = try? await GPGBackend.listKeys() {
                availableSecretKeys = loaded.filter { $0.hasSecretKey }
            }
        }
    }

    private func choosePayloadRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = payloadRoot
        if panel.runModal() == .OK, let url = panel.url {
            payloadRoot = url
            // 选了新 root → 之前选的文件可能在不同 root 下，清空让用户重选避免混淆。
            selectedFiles.removeAll()
        }
    }

    private func chooseFiles() {
        guard let root = payloadRoot else { return }
        // 每次新挑文件时清掉上次的 status（成功 / 错误都清）—— 否则上次「N 个文件不在 payload root」的红字
        // 会一直挂着，即使本次合法添加也不消失，看起来像挑错了。
        statusMessage = nil
        statusIsError = false
        let panel = NSOpenPanel()
        // 支持选目录：选中的目录会被递归展开成其下所有普通文件（`.szs` 目录支持）。
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = root
        if panel.runModal() == .OK {
            // 选中的条目（文件或目录）必须位于 payload root 之下（或就是 root 本身）。
            let rootPath = root.standardizedFileURL.path
            let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let pickedInRoot = panel.urls.filter { url in
                let path = url.standardizedFileURL.path
                return path == rootPath || path.hasPrefix(normalizedRoot)
            }
            // 目录递归展开成普通文件；文件原样。去重后追加。
            let expanded = SZSArchive.expandToRegularFiles(pickedInRoot)
            for url in expanded where !selectedFiles.contains(url) {
                selectedFiles.append(url)
            }
            let rejectedCount = panel.urls.count - pickedInRoot.count
            if rejectedCount > 0 {
                statusMessage = L10n.format("error.szs.fileOutsidePayloadRoot", "\(rejectedCount)")
                statusIsError = true
            }
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        // 默认名同上：payloadRoot 文件夹名.szs（如果有），否则 "manifest.szs" 兜底。
        let defaultName: String = {
            if let outputURL { return outputURL.lastPathComponent }
            if let payloadRoot { return payloadRoot.lastPathComponent + ".szs" }
            return "manifest.szs"
        }()
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = outputURL?.deletingLastPathComponent() ?? payloadRoot ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
        }
    }

    private func runCreate() {
        guard let payloadRoot, let outputURL, !selectedFiles.isEmpty else { return }
        isCreating = true
        statusMessage = nil
        Task {
            do {
                try await SZSArchive.create(
                    payloadRoot: payloadRoot,
                    files: selectedFiles,
                    signingKeyFingerprint: signingKeyFingerprint.isEmpty ? nil : signingKeyFingerprint,
                    title: title.isEmpty ? nil : title,
                    description: description.isEmpty ? nil : description,
                    outputURL: outputURL
                )
                await MainActor.run {
                    statusMessage = L10n.format("szs.create.succeeded", outputURL.lastPathComponent)
                    statusIsError = false
                    isCreating = false
                    // 1.5s 后自动关 sheet —— 让用户看到成功反馈，但不挡屏幕太久。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onClose()
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = L10n.format("szs.create.failed", error.localizedDescription)
                    statusIsError = true
                    isCreating = false
                }
            }
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let root = payloadRoot else { return url.path }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let normalized = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(normalized) else { return url.lastPathComponent }
        return String(filePath.dropFirst(normalized.count))
    }
}
