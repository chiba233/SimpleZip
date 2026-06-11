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
    /// 「把文件加密成 .gpg」总开关 + 收件人 / 对称密码（复用 ArchiveCreationOptionsView 的 idiom 与 L10n key）。
    /// 默认关 = 清单覆盖明文文件（原行为）。开了则每个文件先加密成旁边的 `<name>.gpg`，清单覆盖那些 `.gpg`。
    /// 注意：加密的是**文件本身**，清单（只是哈希信息）始终明文 clearsigned。
    @State private var encryptFiles = false
    @State private var recipientFingerprints: [String] = []
    @State private var symmetricPassphrase = ""
    /// 可作收件人的公钥（仅用户钥匙串，与 GPGBackend.encrypt 默认 homedir 一致）。
    @State private var availableEncryptionKeys: [GPGBackend.GPGKey] = []
    @State private var isCreating = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let labelColumnWidth: CGFloat = 88

    var body: some View {
        // 0.4.1 重构：套创建 / 解压对话框同款 DialogChrome 体例。
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "signature",
                colors: [.green, .teal],
                title: L10n.text("szs.create.title"),
                subtitle: L10n.text("szs.create.subtitle")
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection(L10n.text("szs.create.section.content")) {
                        payloadRootRow
                        filesRow
                        titleRow
                        descriptionRow
                    }
                    DialogSection(L10n.text("szs.create.section.signing")) {
                        signingKeyRow
                        encryptFilesRows
                        outputRow
                    }
                    if let message = statusMessage {
                        Label(message, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 560)

            Divider()

            HStack {
                // 创建中显示菊花 + 「正在创建…」——加密多个文件 + 签名要跑好几个 gpg 进程，
                // 期间还会弹 pinentry，没有进度提示会让人以为卡死了。
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("szs.create.creating"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("szs.create.cancelButton"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button(L10n.text("szs.create.createButton")) {
                    runCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 660)
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onAppear {
            applyPrefillIfAny()
            seedDefaultSigningKey()
            loadAvailableKeysAsync()
        }
    }

    // MARK: - 子行布局

    private func labelText(_ key: String) -> some View {
        // 空 key 当「占位空标签」用（对齐用）—— **不能**走 L10n.text("")：NSLocalizedString 查空 key 会
        // 返回字面量 "localized string not found"(macOS 怪癖),会显示成乱字。空 key → 显示空串。
        Text(key.isEmpty ? "" : L10n.text(key))
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
            GPGSecretKeyMenu(
                selection: $signingKeyFingerprint,
                secretKeys: availableSecretKeys,
                autoLabelKey: "szs.create.signingKey.auto",
                missingFingerprintKey: "archive.gpgSign.key.missingFingerprint"
            )
            Spacer()
        }
    }

    // MARK: - 把文件加密成 .gpg（可选）

    @ViewBuilder
    private var encryptFilesRows: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labelText("szs.create.encryptLabel")
            Toggle(L10n.text("szs.create.encryptFiles.toggle"), isOn: $encryptFiles)
                .toggleStyle(.checkbox)
                .onChange(of: encryptFiles) { enabled in
                    if !enabled {
                        recipientFingerprints.removeAll()
                        symmetricPassphrase = ""
                    }
                }
            Spacer()
        }
        if encryptFiles {
            HStack(alignment: .top, spacing: 8) {
                labelText("archive.gpgEncrypt.recipientsLabel")
                VStack(alignment: .leading, spacing: 4) {
                    GPGAddRecipientMenu(eligibleKeys: availableEncryptionKeys, selection: $recipientFingerprints)
                    GPGRecipientChipRow(selection: $recipientFingerprints, lookupKeys: availableEncryptionKeys)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                labelText("archive.gpgEncrypt.passphraseLabel")
                SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $symmetricPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            if hasMixedRecipientRings {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    labelText("")
                    Text(L10n.text("gpgEncrypt.mixedKeyrings"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                labelText("")
                Text(L10n.text("szs.create.encryptFiles.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
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
        guard payloadRoot != nil, !selectedFiles.isEmpty, outputURL != nil, !isCreating else { return false }
        // 开了加密文件但既没选收件人也没设密码 → 没人能解，禁用；收件人混选两环也禁用。
        if encryptFiles {
            if hasMixedRecipientRings { return false }
            return !recipientFingerprints.isEmpty || !symmetricPassphrase.isEmpty
        }
        return true
    }

    /// 已选收件人分布在哪些 ring —— 一次 gpg 加密只能用一个 homedir，混选两环做不到。
    private var selectedRecipientSources: Set<GPGBackend.GPGKeyringSource> {
        Set(recipientFingerprints.compactMap { fp in
            availableEncryptionKeys.first(where: { $0.fingerprint == fp })?.source
        })
    }

    private var hasMixedRecipientRings: Bool {
        selectedRecipientSources.count > 1
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
                // 收件人候选：两个 ring 都列，但只列**有加密能力**的（纯签名密钥不能当收件人）。
                availableEncryptionKeys = loaded.filter { $0.canEncryptToRecipient }
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
        // 接入活动中心：创建签名清单和「创建压缩包」一样，在「归档操作」里建一个任务，
        // 标题带 `.szs` 名，展开后用 transferLog 列出清单覆盖的每个文件 + `.szs` 本身（「新增」），
        // 和「粘贴」一样的逐文件密度。之前 szs 创建完全不进活动中心。
        let outputName = outputURL.lastPathComponent
        let detailsSession = ArchiveOperationDetailsSession(title: outputName)
        let task = TaskCenter.shared.begin(
            category: .archive,
            kind: .compress,
            title: L10n.format("status.creating", outputName),
            cancellable: false,
            detailsSession: detailsSession
        )
        Task {
            do {
                let manifest = try await SZSArchive.create(
                    payloadRoot: payloadRoot,
                    files: selectedFiles,
                    signingKeyFingerprint: signingKeyFingerprint.isEmpty ? nil : signingKeyFingerprint,
                    // 所选签名密钥在 SimpleZip 私有环时,clearsign 要用其独立 homedir(否则 ~/.gnupg 找不到私钥)。
                    // 空 = 让 gpg 用默认签名密钥(~/.gnupg),故为 false。
                    signingKeyUsesSimpleZipKeyring: availableSecretKeys.first(where: { $0.fingerprint == signingKeyFingerprint })?.source == .simpleZipKeyring,
                    title: title.isEmpty ? nil : title,
                    description: description.isEmpty ? nil : description,
                    encryptionRecipients: encryptFiles ? recipientFingerprints : [],
                    encryptionPassphrase: encryptFiles && !symmetricPassphrase.isEmpty ? symmetricPassphrase : nil,
                    // 收件人全在 SimpleZip 私有环 → 加密走私有 homedir。混选两环已被 canCreate 拦住。
                    encryptionUsesSimpleZipKeyring: encryptFiles && selectedRecipientSources == [.simpleZipKeyring],
                    outputURL: outputURL
                )
                await MainActor.run {
                    var log = manifest.files.map {
                        TransferLogEntry(name: $0.relativePath, action: .added, isDirectory: false)
                    }
                    log.append(TransferLogEntry(name: outputName, action: .added, isDirectory: false))
                    task.transferLog = log
                    detailsSession.finishedAt = Date()
                    TaskCenter.shared.finish(task, outcome: .succeeded(outputURL))
                    SystemSound.operationComplete?.play()
                    statusMessage = L10n.format("szs.create.succeeded", outputName)
                    statusIsError = false
                    isCreating = false
                    // 1.5s 后自动关 sheet —— 让用户看到成功反馈，但不挡屏幕太久。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onClose()
                    }
                }
            } catch {
                await MainActor.run {
                    detailsSession.append(error.localizedDescription)
                    detailsSession.finishedAt = Date()
                    TaskCenter.shared.finish(task, outcome: .failed(error.localizedDescription))
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
