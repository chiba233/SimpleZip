//
//  ArchiveCreationOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/12.
//

import SwiftUI

/// 创建压缩包前的选项面板。
struct ArchiveCreationOptionsView: View {
    @State var request: ArchiveCreationRequest
    @State private var showsSevenZipAdvancedOptions = false
    @State private var excludedFileCount: Int?
    @State private var isCountingExcludedFiles = false
    /// 「使用预设密码」复选框的当前勾选状态。仅在用户在通用设置里启用了预设密码时显示。
    /// 默认勾选 —— 与「设置里开了 = 默认走预设」的用户预期一致。
    @State private var useArchivePresetPassword = false
    @AppStorage(AppPreferences.Key.presetPasswordEnabled) private var presetPasswordEnabled = false
    /// 签名密钥选择策略 —— 跟 GPGPane「默认值」段同步。true = 每次创建时给 picker 让用户挑。
    @AppStorage(AppPreferences.Key.gpgPromptForSigningKey) private var gpgPromptForSigningKey = false
    /// 用户钥匙串里全部 GPG 密钥（含自有私钥 + 他人公钥）。GPG 开启 + 后端可用时 onAppear 异步加载。
    /// 签名 picker 在 use site 过滤 `hasSecretKey`；收件人 picker 用全部。
    @State private var availableKeys: [GPGBackend.GPGKey] = []
    /// 「加密内层 archive」总开关 —— 关 = 仅签名（v2 行为）；开 = 展示收件人 picker + 对称密码 SecureField。
    /// 默认关：避免用户看见 recipients / passphrase 行就以为「必须填 / 必须选」而困惑。
    /// Toggle 关掉时同步把 options.gpgRecipientFingerprints + options.gpgSymmetricPassphrase 清空，
    /// 避免用户填好后反悔关 toggle、加密字段还潜伏在 options 里被发送。
    @State private var useGPGEncryption: Bool = false
    /// 预设密码从 Keychain 拉到 view 内，dialog 关闭即丢；不绑定 @AppStorage 是因为 Keychain
    /// 没有 @AppStorage 等价物，而且业务侧也只需要打开时的快照。
    @State private var presetPassword = ""
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    private var hasUsablePreset: Bool { presetPasswordEnabled && !presetPassword.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("archive.create.title"))
                .font(.title3)
                .fontWeight(.semibold)

            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("archive.fileName"), text: fileNameBinding)
                        .textFieldStyle(.roundedBorder)

                    HStack(alignment: .center, spacing: 14) {
                        HStack(spacing: 6) {
                            Text(L10n.text("archive.format"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker(L10n.text("archive.format"), selection: $request.options.format) {
                                ForEach(ArchiveCreateFormat.allCases) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 112)
                            .onChange(of: request.options.format) { _ in
                                updateDestinationExtension()
                            }
                        }

                        if request.options.format.supportsCompressionLevel {
                            HStack(spacing: 6) {
                                Text(L10n.text("archive.compressionLevel"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker(L10n.text("archive.compressionLevel"), selection: $request.options.compressionLevel) {
                                    ForEach(CompressionLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 124)
                            }
                        }

                        if request.options.format.supportsUpdateMode {
                            HStack(spacing: 6) {
                                Text(L10n.text("archive.updateMode"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker(L10n.text("archive.updateMode"), selection: $request.options.updateMode) {
                                    ForEach(ArchiveUpdateMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 152)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if request.options.format.supportsPassword {
                        if hasUsablePreset {
                            Toggle(L10n.text("button.usePresetPassword"), isOn: $useArchivePresetPassword)
                                .help(L10n.text("button.usePresetPassword.help"))
                                .toggleStyle(.checkbox)
                                .onChange(of: useArchivePresetPassword) { newValue in
                                    if newValue {
                                        // 勾选 = password 和 confirmation 都用预设。
                                        // 不动 encryptionMethod —— 用户对加密算法的偏好与「用什么密码」无关。
                                        request.options.password = presetPassword
                                        request.options.passwordConfirmation = presetPassword
                                    } else {
                                        request.options.password = ""
                                        request.options.passwordConfirmation = ""
                                    }
                                }
                        }
                        if !(hasUsablePreset && useArchivePresetPassword) {
                            passwordField(L10n.text("archive.password"), text: $request.options.password)
                            if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                                passwordField(L10n.text("archive.passwordConfirm"), text: $request.options.passwordConfirmation)
                                Toggle(L10n.text("archive.showPassword"), isOn: $request.options.showPassword)
                                    .toggleStyle(.checkbox)
                                if passwordValidationMessage != nil {
                                    validationText(L10n.text("error.passwordsDoNotMatch"))
                                }
                            }
                        }
                        if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                            if request.options.format == .zip {
                                Picker(L10n.text("archive.encryptionMethod"), selection: $request.options.encryptionMethod) {
                                    ForEach(ArchiveEncryptionMethod.allCases) { method in
                                        Text(method.title).tag(method)
                                    }
                                }
                            } else {
                                HStack {
                                    Text(L10n.text("archive.encryptionMethod"))
                                    Spacer()
                                    Text(ArchiveEncryptionMethod.aes256.title)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let singleFileValidationMessage {
                        validationText(singleFileValidationMessage)
                    }

                    if request.options.format == .rar, !ArchiveService.canCreateRAR() {
                        validationText(L10n.text("archive.rar.requiresTool"))
                    }

                    if request.options.format.supportsVolumeSplitting {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.text("archive.7z.volumeSize"), text: $request.options.sevenZipVolumeSize)
                                .textFieldStyle(.roundedBorder)
                            if let volumeSizeValidationMessage {
                                validationText(volumeSizeValidationMessage)
                            } else {
                                Text(L10n.text("archive.7z.volumeSizeHint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if request.options.format == .sevenZip {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(L10n.text("archive.7z.method"), selection: $request.options.sevenZipMethod) {
                                ForEach(SevenZipCompressionMethod.allCases) { method in
                                    Text(method.title).tag(method)
                                }
                            }

                            Picker(L10n.text("archive.7z.dictionarySize"), selection: $request.options.sevenZipDictionarySizeMB) {
                                ForEach(dictionarySizeOptions, id: \.self) { size in
                                    Text("\(size) MB").tag(size)
                                }
                            }

                            Picker(L10n.text("archive.7z.wordSize"), selection: $request.options.sevenZipWordSize) {
                                ForEach(wordSizeOptions, id: \.self) { wordSize in
                                    Text("\(wordSize)").tag(wordSize)
                                }
                            }

                            HStack {
                                Text(L10n.text("archive.7z.threads"))
                                Spacer()
                                // 不能 .labelsHidden() —— Stepper 的「label」正是要显示的线程数值（自动 / N），
                                // 隐藏了就只剩 ▲▼ 没有数字（用户反馈「线程数不显示」）。
                                Stepper(value: $request.options.sevenZipThreadCount, in: 0...maxThreadCount) {
                                    Text(threadCountLabel)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack {
                                Text(L10n.text("archive.memoryUsageCompressing"))
                                Spacer()
                                Text(estimatedCompressionMemoryText)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text(L10n.text("archive.memoryUsageDecompressing"))
                                Spacer()
                                Text(estimatedDecompressionMemoryText)
                                    .foregroundStyle(.secondary)
                            }

                            DisclosureGroup(L10n.text("archive.7z.advanced"), isExpanded: $showsSevenZipAdvancedOptions) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(L10n.text("archive.7z.solid"), isOn: $request.options.sevenZipSolidArchive)
                                    if request.options.sevenZipSolidArchive {
                                        Picker(L10n.text("archive.7z.solidBlockSize"), selection: $request.options.sevenZipSolidBlockSize) {
                                            ForEach(SevenZipSolidBlockSize.allCases) { size in
                                                Text(size.title).tag(size)
                                            }
                                        }
                                    }

                                    Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                                        ForEach(SevenZipPathMode.allCases) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }

                                    Toggle(L10n.text("archive.7z.storeSymbolicLinks"), isOn: $request.options.sevenZipStoreSymbolicLinks)
                                    Toggle(L10n.text("archive.7z.storeHardLinks"), isOn: $request.options.sevenZipStoreHardLinks)
                                    Toggle(L10n.text("archive.7z.compressSharedFiles"), isOn: $request.options.sevenZipCompressSharedFiles)
                                    Toggle(L10n.text("archive.7z.deleteAfterCompression"), isOn: $request.options.sevenZipDeleteSourceFiles)
                                }
                                .padding(.top, 6)
                            }
                        }
                    }

                    if request.options.format != .sevenZip, request.options.format.supportsUpdateMode {
                        Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                            ForEach(SevenZipPathMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    if request.options.format == .sevenZip || request.options.format == .rar {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(L10n.text("archive.7z.encryptFileNames"), isOn: $request.options.sevenZipEncryptFileNames)
                                .disabled(request.options.password.isEmpty)
                            if request.options.password.isEmpty {
                                Text(L10n.text("archive.7z.encryptFileNamesHint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
                            }
                        }
                    }

                    if request.options.format.supportsSFX {
                        Toggle(L10n.text("archive.createSFX"), isOn: $request.options.createSFXArchive)
                    }

                    if request.options.format.supportsRawParameters {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.text("archive.parameters"), text: $request.options.rawParameters)
                                .textFieldStyle(.roundedBorder)
                            Text(L10n.text("archive.parametersHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if request.options.format.supportsExcludeRules {
                        Toggle(L10n.text("archive.skipDSStore"), isOn: $request.options.skipDSStore)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(L10n.text("archive.skipHiddenFiles"), isOn: $request.options.skipHiddenFiles)
                            Text(L10n.text("archive.skipHiddenFilesHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("archive.customExcludes"))
                            TextEditor(text: $request.options.customExcludes)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 72)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: .separatorColor))
                                )
                            Text(L10n.text("archive.customExcludesHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button(L10n.text("archive.countExcludedFiles")) {
                                    countExcludedFiles()
                                }
                                .disabled(isCountingExcludedFiles || !hasExcludeRulesEnabled)

                                if isCountingExcludedFiles {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(excludedFileCountText)
                                    .font(.caption)
                                    .foregroundStyle((excludedFileCount ?? 0) > 0 ? .secondary : .tertiary)
                            }
                        }
                    }

                    HStack {
                        Text(L10n.text("archive.destination"))
                        Text(request.destinationURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("button.choose")) {
                            chooseDestination()
                        }
                    }

                    // GPG 签名 —— 只在「主开关 + 后端可用」时才显示，关掉的用户完全看不见。
                    // 勾选 → 输出文件改成 .siz 容器（内层是当前 format，签名 + 元数据一起打 tar 包）。
                    if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                        Toggle(L10n.text("archive.gpgSign"), isOn: $request.options.gpgSign)
                            .disabled(gpgSigningDisabledBySplitVolume)
                        if gpgSigningDisabledBySplitVolume {
                            validationText(L10n.text("archive.gpgSign.disabledBySplitVolume"))
                        }
                        if request.options.gpgSign {
                            Text(L10n.text("archive.gpgSign.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            // ask 模式下显示密钥 picker；silent 模式静默用默认密钥（在 onAppear 已 seed 到 options）。
                            if gpgPromptForSigningKey {
                                signingKeyPickerRow
                            }
                            // GPG 加密相关设置 —— 总开关 + 收件人 picker + 对称密码。
                            // **总开关默认关 = 仅签名 v2 行为**；关闭时下方两组控件 **灰掉但仍可见**（用户能看到「这里有
                            // 加密选项」），同时清空 options 避免「用户先填后关 toggle 但加密 params 还潜伏在 options 里被发送」的 footgun。
                            // 关闭时**不隐藏**是为了让用户一眼看到 sheet 完整可能性 —— 隐藏只展示「下一刻可能变化的 UI」会迷惑。
                            Toggle(L10n.text("archive.gpgEncrypt.useEncryption"), isOn: $useGPGEncryption)
                                .onChange(of: useGPGEncryption) { enabled in
                                    if !enabled {
                                        request.options.gpgRecipientFingerprints.removeAll()
                                        request.options.gpgSymmetricPassphrase = ""
                                    }
                                }
                            recipientsRow
                                .disabled(!useGPGEncryption)
                                .opacity(useGPGEncryption ? 1 : 0.5)
                            encryptionPassphraseRow
                                .disabled(!useGPGEncryption)
                                .opacity(useGPGEncryption ? 1 : 0.5)
                                // scrollProxy 滚到这一行（GPG 段最后一行）：勾上签名后所有加密相关 UI 都能看到，
                                // 不像之前 anchor 钉在 signingKeyPickerRow 上 —— 加密 toggle / recipients / passphrase 还是会被截在 ScrollView 底部。
                                .id("gpgSignAnchor")
                        }
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 520)
            .onChange(of: request.options.gpgSign) { newValue in
                // 用户勾 GPG 签名后，新增的多组 UI（签名密钥 picker 在 ask 模式 / 加密总开关 / recipients / passphrase）
                // 都出现在 ScrollView 底部，默认看不见 —— 自动滚下来。anchor 钉在最后一行（encryptionPassphraseRow），
                // 不再判 ask / silent 模式 —— 即使没 picker，加密那三行依然在 ScrollView 底部需要可见。
                guard newValue else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("gpgSignAnchor", anchor: .bottom)
                    }
                }
            }
            } // ScrollViewReader

            HStack {
                ShowDetailsToggleButton(isOn: $request.options.showDetails)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.create")) {
                    normalizeDestinationForCurrentFormat()
                    create(request)
                }
                .disabled(validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 700)
        .animation(.default, value: request.options.format)
        .animation(.default, value: showsSevenZipAdvancedOptions)
        .animation(.default, value: request.options.password.isEmpty)
        .animation(.default, value: request.options.passwordConfirmation.isEmpty)
        .onChange(of: request.options.skipDSStore) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.skipHiddenFiles) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.customExcludes) { _ in
            excludedFileCount = nil
        }
        .onChange(of: request.options.sevenZipVolumeSize) { _ in
            if gpgSigningDisabledBySplitVolume {
                request.options.gpgSign = false
            }
        }
        .onChange(of: request.options.format) { _ in
            excludedFileCount = nil
            if gpgSigningDisabledBySplitVolume {
                request.options.gpgSign = false
            }
        }
        .onAppear {
            presetPassword = AppPreferences.presetPassword
            // 默认行为：预设密码可用时复选框默认勾上 + 把预设填入 options.password 和 confirmation。
            // 这样用户「打开设置 → 预设打开 → 点新建压缩包」三步流程里不需要再手动勾或填密码。
            if hasUsablePreset {
                useArchivePresetPassword = true
                request.options.password = presetPassword
                request.options.passwordConfirmation = presetPassword
            }
            // Seed 默认签名密钥。silent 模式：用户从未选过 → 走 prefs 默认；ask 模式 picker 初值也来自此。
            // 注意：只在 options 当前是空字符串时 seed，避免覆盖调用方预设的值（如 Finder 入口）。
            let defaultFp = AppPreferences.gpgDefaultSigningKeyFingerprint
            if !defaultFp.isEmpty && request.options.gpgSigningKeyFingerprint.isEmpty {
                request.options.gpgSigningKeyFingerprint = defaultFp
            }
            // 加载钥匙串（含自有私钥 + 他人公钥）。GPG 启用 + 后端可用时跑；失败静默忽略 picker 退化到「让 GPG 自动选」/「无可选收件人」。
            if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                Task { @MainActor in
                    if let loaded = try? await GPGBackend.listKeys() {
                        availableKeys = loaded
                    }
                }
            }
        }
    }

    /// 收件人 picker 行 —— GPG 签名勾上时显示。当前选中的收件人以 chip 形式横列；右侧 Menu 按钮可点开添加新收件人。
    /// 多次点击 Menu 累加多个收件人；chip 上的 × 移除单个。0 收件人 = 「未加密」（除非另设了对称密码）。
    @ViewBuilder
    private var recipientsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("archive.gpgEncrypt.recipientsLabel"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                GPGAddRecipientMenu(eligibleKeys: encryptionEligibleKeys, selection: $request.options.gpgRecipientFingerprints)
                Spacer()
            }
            GPGRecipientChipRow(selection: $request.options.gpgRecipientFingerprints, lookupKeys: availableKeys)
        }
        .padding(.leading, 18)
    }

    /// 加密收件人**候选公钥**：必须在 user keyring（`~/.gnupg/`）—— `GPGBackend.encrypt` 默认只在 user homedir 找 recipient。
    /// 把 SimpleZip 私有 ring 的 key 放进 picker 会让用户选到，然后 gpg 找不到 recipient → 加密失败。
    /// 历史上 `availableKeys` 同时含两个 ring（签名 picker 需要看全部 hasSecretKey），收件人 picker 必须额外过滤。
    private var encryptionEligibleKeys: [GPGBackend.GPGKey] {
        availableKeys.filter { $0.source == .userKeyring }
    }

    /// 对称加密密码 SecureField —— 跟收件人 picker **互不排斥**。空 = 不用对称密码加密。
    /// 总开关 `useGPGEncryption` 关时整行不显示，所以这里不再需要 Toggle 包裹。
    /// placeholder 「可选 · 对称密码」+ 下方 hint 已经说清楚「留空 = 不设密码」。
    @ViewBuilder
    private var encryptionPassphraseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("archive.gpgEncrypt.passphraseLabel"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $request.options.gpgSymmetricPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            Text(L10n.text("archive.gpgEncrypt.passphraseHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
    }

    /// 签名密钥 picker —— ask 模式下显示在「用 GPG 签名」复选框正下方。
    /// 列出所有 `hasSecretKey` 密钥（含智能卡 stub），首项「让 GPG 自动选」对应空 fingerprint = 走 gpg default-key。
    @ViewBuilder
    private var signingKeyPickerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.text("archive.gpgSign.keyLabel"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Menu {
                Button(L10n.text("archive.gpgSign.key.auto")) {
                    request.options.gpgSigningKeyFingerprint = ""
                }
                let secretKeys = availableKeys.filter { $0.hasSecretKey }
                if !secretKeys.isEmpty {
                    Divider()
                    ForEach(secretKeys) { key in
                        Button("\(key.userID) · \(key.shortFingerprint)") {
                            request.options.gpgSigningKeyFingerprint = key.fingerprint
                        }
                    }
                }
            } label: {
                Text(signingKeyMenuLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.leading, 18)
    }

    /// picker 按钮显示文案：未选 / 选了但找不到 / 选了能映射到列表 三种情形。
    private var signingKeyMenuLabel: String {
        let fp = request.options.gpgSigningKeyFingerprint
        if fp.isEmpty {
            return L10n.text("archive.gpgSign.key.auto")
        }
        if let matched = availableKeys.first(where: { $0.fingerprint == fp && $0.hasSecretKey }) {
            return "\(matched.userID) · \(matched.shortFingerprint)"
        }
        // String(...) 包一层避免 Substring → CVarArg 的 printf 序列化 bug（之前掉过的坑）。
        return L10n.format("archive.gpgSign.key.missingFingerprint", String(fp.suffix(16)))
    }

    private var fileNameBinding: Binding<String> {
        Binding {
            archiveBaseName(from: request.destinationURL.lastPathComponent)
        } set: { newValue in
            let trimmedName = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            request.destinationURL = request.destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(archiveFileName(fromBaseName: trimmedName))
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = L10n.text("panel.createArchive")
        panel.directoryURL = request.destinationURL.deletingLastPathComponent()
        panel.nameFieldStringValue = archiveBaseName(from: request.destinationURL.lastPathComponent)
        panel.allowedContentTypes = ArchiveService.contentTypes(for: request.options.format)

        if panel.runModal() == .OK, let url = panel.url {
            request.destinationURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(archiveFileName(fromBaseName: url.lastPathComponent))
        }
    }

    private func updateDestinationExtension() {
        normalizeOptionsForCurrentFormat()
        normalizeDestinationForCurrentFormat()
    }

    private func countExcludedFiles() {
        guard request.options.format.supportsExcludeRules else {
            excludedFileCount = 0
            return
        }
        let sourceURLs = request.sourceURLs
        let options = request.options
        isCountingExcludedFiles = true
        Task { @MainActor in
            let count = await Task.detached(priority: .utility) {
                ArchiveService.excludedFileCount(in: sourceURLs, options: options)
            }.value
            excludedFileCount = count
            isCountingExcludedFiles = false
        }
    }

    private var hasExcludeRulesEnabled: Bool {
        request.options.skipDSStore
            || request.options.skipHiddenFiles
            || !ArchiveService.customExcludePatterns(from: request.options.customExcludes).isEmpty
    }

    private var excludedFileCountText: String {
        guard hasExcludeRulesEnabled else {
            return L10n.text("archive.excludedFilesNotConfigured")
        }
        guard let excludedFileCount else {
            return L10n.text("archive.excludedFilesNeedsCalculation")
        }
        return L10n.format("archive.excludedFilesDetected", excludedFileCount)
    }

    private func normalizeOptionsForCurrentFormat() {
        if !request.options.format.supportsPassword {
            request.options.password = ""
            request.options.passwordConfirmation = ""
            request.options.showPassword = false
        }
        if !request.options.format.supportsVolumeSplitting {
            request.options.sevenZipVolumeSize = ""
        }
        if !request.options.format.supportsUpdateMode {
            request.options.updateMode = .addAndReplace
            request.options.sevenZipPathMode = .relative
        }
        if !request.options.format.supportsSFX {
            request.options.createSFXArchive = false
        }
        if !request.options.format.supportsRawParameters {
            request.options.rawParameters = ""
        }
        if request.options.format == .zip, request.options.password.isEmpty {
            request.options.encryptionMethod = .zipCrypto
        }
        if request.options.format != .zip {
            request.options.encryptionMethod = .aes256
        }
    }

    private func normalizeDestinationForCurrentFormat() {
        let baseName = archiveBaseName(from: request.destinationURL.lastPathComponent)
        request.destinationURL = request.destinationURL
            .deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(archiveFileName(fromBaseName: baseName))
    }

    private func archiveFileName(fromBaseName fileName: String) -> String {
        archiveBaseName(from: fileName) + ".\(request.options.format.pathExtension)"
    }

    private func archiveBaseName(from fileName: String) -> String {
        var baseName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownExtensions = ArchiveCreateFormat.allCases.map(\.pathExtension)
        while let extensionName = knownExtensions.first(where: { baseName.lowercased().hasSuffix(".\($0)") }) {
            baseName.removeLast(extensionName.count + 1)
            baseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return baseName.isEmpty ? "Archive" : baseName
    }

    private var maxThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    private var dictionarySizeOptions: [Int] {
        [1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    }

    private var wordSizeOptions: [Int] {
        [16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    }

    private var threadCountLabel: String {
        request.options.sevenZipThreadCount == 0
            ? L10n.text("archive.7z.threads.auto")
            : "\(request.options.sevenZipThreadCount)"
    }

    private var validationMessage: String? {
        if request.options.format == .rar, !ArchiveService.canCreateRAR() {
            return L10n.text("error.missingRarTool")
        }
        if let passwordValidationMessage {
            return passwordValidationMessage
        }
        if let volumeSizeValidationMessage {
            return volumeSizeValidationMessage
        }
        if let singleFileValidationMessage {
            return singleFileValidationMessage
        }
        return nil
    }

    private var passwordValidationMessage: String? {
        if !request.options.password.isEmpty, request.options.password != request.options.passwordConfirmation {
            return L10n.text("error.passwordsDoNotMatch")
        }
        return nil
    }

    private var volumeSizeValidationMessage: String? {
        guard request.options.format.supportsVolumeSplitting else { return nil }
        let trimmed = request.options.sevenZipVolumeSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? ArchiveService.normalizedSevenZipVolumeSize(from: trimmed)) == nil
            ? L10n.text("error.invalidSevenZipVolumeSize")
            : nil
    }

    private var gpgSigningDisabledBySplitVolume: Bool {
        request.options.format.supportsVolumeSplitting
            && !request.options.sevenZipVolumeSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var singleFileValidationMessage: String? {
        guard request.options.format.requiresSingleRegularFile else { return nil }
        guard request.sourceURLs.count == 1 else {
            return L10n.text("error.singleFileCompressionRequiresSingleFile")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: request.sourceURLs[0].path, isDirectory: &isDirectory), isDirectory.boolValue {
            return L10n.text("error.singleFileCompressionRequiresSingleFile")
        }
        return nil
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        if request.options.showPassword {
            TextField(title, text: text)
        } else {
            SecureField(title, text: text)
        }
    }

    private var effectiveThreadCount: Int {
        request.options.sevenZipThreadCount == 0 ? maxThreadCount : request.options.sevenZipThreadCount
    }

    private var estimatedCompressionMemoryText: String {
        formatMemoryEstimate(compressionMemoryEstimateBytes)
    }

    private var estimatedDecompressionMemoryText: String {
        formatMemoryEstimate(decompressionMemoryEstimateBytes)
    }

    private var compressionMemoryEstimateBytes: Int64 {
        let dictionaryBytes = Int64(request.options.sevenZipDictionarySizeMB) * 1_048_576
        let threads = Int64(effectiveThreadCount)
        switch request.options.sevenZipMethod {
        case .automatic, .lzma2, .lzma:
            return dictionaryBytes * max(1, threads) + threads * 34 * 1_048_576
        case .ppmd:
            return dictionaryBytes + 32 * 1_048_576
        case .bzip2:
            return threads * 10 * 1_048_576
        case .deflate:
            return threads * 4 * 1_048_576
        case .copy:
            return 1 * 1_048_576
        }
    }

    private var decompressionMemoryEstimateBytes: Int64 {
        let dictionaryBytes = Int64(request.options.sevenZipDictionarySizeMB) * 1_048_576
        switch request.options.sevenZipMethod {
        case .automatic, .lzma2, .lzma:
            return dictionaryBytes + 4 * 1_048_576
        case .ppmd:
            return dictionaryBytes
        case .bzip2:
            return 8 * 1_048_576
        case .deflate:
            return 2 * 1_048_576
        case .copy:
            return 1 * 1_048_576
        }
    }

    private func formatMemoryEstimate(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    @ViewBuilder
    private func validationText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
