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
    /// 发包端闭环:随 `.szs` 在旁边导出签名公钥(`PUBLIC_KEY.asc`)+ 验证说明(`VERIFY.md`),
    /// 收件人不装 SimpleZip 也能 `gpg --import` + `--verify`。默认开 —— 签名分发的意义就在能验。
    /// 需要**具体**签名密钥(「自动」时不知道 gpg 会用哪把,该开关禁用而不是静默跳过)。
    @State private var exportVerificationKit = true

    /// 标签列定宽(en 最长 "Description (optional)" + 22pt 瓦片也放得下)；hint 行用它对齐值列。
    private let labelColumnWidth: CGFloat = 190

    var body: some View {
        // 0.4.1 重构：套创建 / 解压对话框同款 DialogChrome 体例;design system 第一刀改用骨架组件。
        TaskDialogShell(
            heroSystemImage: "signature",
            heroColors: [.green, .teal],
            title: L10n.text("szs.create.title"),
            subtitle: L10n.text("szs.create.subtitle"),
            width: 660,
            maxContentHeight: 560,
            confirmTitle: L10n.text("szs.create.createButton"),
            confirmSystemImage: "signature",
            confirmDisabled: !canCreate,
            cancelDisabled: isCreating,
            confirm: { runCreate() },
            cancel: onClose,
            content: {
                DialogSection(L10n.text("szs.create.section.content")) {
                    payloadRootRow
                    filesRow
                    titleRow
                    descriptionRow
                }
                DialogSection(L10n.text("szs.create.section.signing")) {
                    signingKeyRow
                    exportVerificationKitRow
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
            },
            footerLeading: {
                // 创建中显示菊花 + 「正在创建…」——加密多个文件 + 签名要跑好几个 gpg 进程，
                // 期间还会弹 pinentry，没有进度提示会让人以为卡死了。
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("szs.create.creating"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        )
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onAppear {
            applyPrefillIfAny()
            seedDefaultSigningKey()
            loadAvailableKeysAsync()
        }
    }

    // MARK: - 子行布局

    private var payloadRootRow: some View {
        HStack(alignment: .center, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.payloadRoot"), systemImage: "folder.fill", tint: .blue, width: labelColumnWidth)
            Text(payloadRoot?.path ?? L10n.text("szs.create.payloadRoot.placeholder"))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button(L10n.text("szs.create.payloadRoot.choose")) {
                choosePayloadRoot()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var filesRow: some View {
        HStack(alignment: .top, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.filesLabel"), systemImage: "doc.on.doc.fill", tint: .cyan, width: labelColumnWidth)
            VStack(alignment: .leading, spacing: 8) {
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
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
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
        HStack(alignment: .center, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.titleLabel"), systemImage: "character.cursor.ibeam", tint: .pink, width: labelColumnWidth)
            TextField(L10n.text("szs.create.titlePlaceholder"), text: $title, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .dialogFieldEmphasis()
        }
    }

    private var descriptionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.descriptionLabel"), systemImage: "text.alignleft", tint: .pink, width: labelColumnWidth)
            TextField(L10n.text("szs.create.descriptionPlaceholder"), text: $description, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .dialogFieldEmphasis()
        }
    }

    private var signingKeyRow: some View {
        HStack(alignment: .center, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.signingKeyLabel"), systemImage: "signature", tint: .green, width: labelColumnWidth)
            Spacer(minLength: 12)
            // 值钉到右缘 —— 与本对话框其他行(选择按钮列)同一条右基线(用户点名)。
            GPGSecretKeyMenu(
                selection: $signingKeyFingerprint,
                secretKeys: availableSecretKeys,
                autoLabelKey: "szs.create.signingKey.auto",
                missingFingerprintKey: "archive.gpgSign.key.missingFingerprint"
            )
        }
    }

    // MARK: - 把文件加密成 .gpg（可选）

    /// 「随包导出公钥与验证说明」开关。签名密钥为「自动」时禁用(导出需要知道具体哪把),
    /// 副标题随状态切换说明原因 —— 不静默跳过。
    @ViewBuilder
    private var exportVerificationKitRow: some View {
        DialogToggleRow(
            title: L10n.text("szs.create.exportKit.toggle"),
            subtitle: signingKeyFingerprint.isEmpty
                ? L10n.text("szs.create.exportKit.needsKey")
                : L10n.text("szs.create.exportKit.subtitle"),
            systemImage: "person.badge.key.fill",
            tint: .teal,
            pinsToTrailing: true,
            isOn: $exportVerificationKit
        )
        .disabled(signingKeyFingerprint.isEmpty)
        .opacity(signingKeyFingerprint.isEmpty ? 0.55 : 1)
    }

    @ViewBuilder
    private var encryptFilesRows: some View {
        DialogToggleRow(
            title: L10n.text("szs.create.encryptFiles.toggle"),
            systemImage: "lock.fill",
            tint: .purple,
            pinsToTrailing: true,
            isOn: $encryptFiles
        )
        .onChange(of: encryptFiles) { enabled in
            if !enabled {
                recipientFingerprints.removeAll()
                symmetricPassphrase = ""
            }
        }
        if encryptFiles {
            // 说明 / 警告紧贴所属控件(同一值列、小间距 6),不再用「空标签 + 浮动说明行」——
            // 孤儿说明行隔着 16pt 行距浮在卡片里,正是用户点名的「不优雅」。
            HStack(alignment: .top, spacing: 8) {
                DialogRowLabel(L10n.text("archive.gpgEncrypt.recipientsLabel"), systemImage: "person.2.fill", tint: .green, width: labelColumnWidth)
                VStack(alignment: .leading, spacing: 6) {
                    GPGAddRecipientMenu(eligibleKeys: availableEncryptionKeys, selection: $recipientFingerprints)
                    GPGRecipientChipRow(selection: $recipientFingerprints, lookupKeys: availableEncryptionKeys)
                    if hasMixedRecipientRings {
                        Text(L10n.text("gpgEncrypt.mixedKeyrings"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // 说明横跨整行(同「加密为 GPG」对话框的规则:备注不挤在右值列)。
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    DialogRowLabel(L10n.text("archive.gpgEncrypt.passphraseLabel"), systemImage: "lock.rectangle.fill", tint: .orange, width: labelColumnWidth)
                    SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $symmetricPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .dialogFieldEmphasis()
                }
                Text(L10n.text("szs.create.encryptFiles.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var outputRow: some View {
        HStack(alignment: .center, spacing: 8) {
            DialogRowLabel(L10n.text("szs.create.outputLocation"), systemImage: "square.and.arrow.down.fill", tint: .indigo, width: labelColumnWidth)
            Text(outputURL?.path ?? L10n.text("szs.create.outputLocation.placeholder"))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                // 随包验证材料(公钥 .asc + VERIFY.md):开关开且选了具体密钥才做。
                // 导出失败不影响已成功的 `.szs`,但绝不静默 —— 状态行写明 + 任务日志留痕。
                var kitLog: [TransferLogEntry] = []
                var kitFailureMessage: String?
                if exportVerificationKit, !signingKeyFingerprint.isEmpty {
                    do {
                        let source = availableSecretKeys.first(where: { $0.fingerprint == signingKeyFingerprint })?.source ?? .userKeyring
                        let armored = try await GPGBackend.exportPublicKey(fingerprint: signingKeyFingerprint, source: source)
                        let directory = outputURL.deletingLastPathComponent()
                        let keyURL = UniqueFileName.suffixed(for: directory.appendingPathComponent("PUBLIC_KEY.asc"), suffix: "") {
                            FileManager.default.fileExists(atPath: $0.path)
                        }
                        try armored.write(to: keyURL, atomically: true, encoding: .utf8)
                        let verifyURL = UniqueFileName.suffixed(for: directory.appendingPathComponent("VERIFY.md"), suffix: "") {
                            FileManager.default.fileExists(atPath: $0.path)
                        }
                        try SZSArchive.verifyInstructions(
                            containerName: outputName,
                            publicKeyFileName: keyURL.lastPathComponent,
                            fingerprint: signingKeyFingerprint
                        ).write(to: verifyURL, atomically: true, encoding: .utf8)
                        kitLog = [keyURL, verifyURL].map {
                            TransferLogEntry(name: $0.lastPathComponent, action: .added, isDirectory: false)
                        }
                    } catch {
                        kitFailureMessage = error.localizedDescription
                    }
                }
                let exportFailure = kitFailureMessage
                let exportLog = kitLog
                await MainActor.run {
                    var log = manifest.files.map {
                        TransferLogEntry(name: $0.relativePath, action: .added, isDirectory: false)
                    }
                    log.append(TransferLogEntry(name: outputName, action: .added, isDirectory: false))
                    log.append(contentsOf: exportLog)
                    task.transferLog = log
                    detailsSession.finishedAt = Date()
                    TaskCenter.shared.finish(task, outcome: .succeeded(outputURL))
                    SystemSound.operationComplete?.play()
                    if let exportFailure {
                        detailsSession.append(exportFailure)
                        statusMessage = L10n.format("szs.create.exportKit.partial", exportFailure)
                        statusIsError = true
                        isCreating = false
                        // 部分失败:不自动关 sheet,让用户读完提示自己关。
                        return
                    }
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
