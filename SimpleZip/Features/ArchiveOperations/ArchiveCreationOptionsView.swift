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
    /// #115 当前格式已保存的「默认压缩设置」模板（启用且至少配了一项）；没有就是 nil。
    @State private var formatDefaultsPreset: CompressionFormatPreset?
    /// 「使用本格式默认值」复选框。有模板时默认勾上 = 套用模板值 + 隐藏模板已配的那些选项；
    /// 取消勾选则恢复显示全部选项（值不回滚，用户可继续手改）。
    @State private var useFormatDefaults = false
    private let compressionDefaultsStore = CompressionDefaultsStore()
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    private var hasUsablePreset: Bool { presetPasswordEnabled && !presetPassword.isEmpty }

    /// 某选项是否被本格式模板接管而应在创建对话框里隐藏 —— 勾了「使用默认值」且该字段在模板里。
    private func hidden(_ field: CompressionOptionField) -> Bool {
        useFormatDefaults && (formatDefaultsPreset?.includedFields.contains(field) ?? false)
    }

    /// 重新读取当前格式的模板：有启用且非空的就缓存 + 默认勾选 + 立即套用；否则清空。
    /// onAppear 与切换格式时调用。
    private func reloadFormatDefaults() {
        if let preset = compressionDefaultsStore.preset(for: request.options.format),
           preset.enabled, !preset.includedFields.isEmpty {
            formatDefaultsPreset = preset
            useFormatDefaults = true
            preset.apply(to: &request.options)
        } else {
            formatDefaultsPreset = nil
            useFormatDefaults = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 hero：彩色渐变瓦片 + 标题 + 「压缩 N 个项目」副标题 —— 与浮窗 / 欢迎助手同一套视觉语言。
            HStack(spacing: 12) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("archive.create.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.format("archive.create.subtitle", "\(request.sourceURLs.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // 0.4.1 重构：平铺 ScrollView → grouped Form 分区卡片（系统设置同款体例）。
            // 所有选项、显隐门控（hidden() / supports*）、onChange 行为与 0.3.x 完全一致，只换排版。
            ScrollViewReader { scrollProxy in
                Form {
                    basicsSection
                    if request.options.format.supportsPassword {
                        passwordSection
                    }
                    if request.options.format == .sevenZip {
                        sevenZipSection
                    }
                    if request.options.format.supportsExcludeRules {
                        excludeSection
                    }
                    if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                        gpgSection
                    }
                }
                .formStyle(.grouped)
                .onChange(of: request.options.gpgSign) { newValue in
                    // 用户勾 GPG 签名后，新增的多组 UI 都在 Form 底部，默认看不见 —— 自动滚下来。
                    guard newValue else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo("gpgSignAnchor", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 钉底操作栏：bar 材质 + prominent 主按钮。
            HStack {
                ShowDetailsToggleButton(isOn: $request.options.showDetails)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("button.cancel"), action: cancel)
                Button(L10n.text("button.create")) {
                    normalizeDestinationForCurrentFormat()
                    create(request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 700, height: 680)
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
            // 切换格式 → 重新取新格式的默认值模板(有就默认勾上并套用,没有就隐藏复选框)。
            reloadFormatDefaults()
        }
        .onAppear {
            presetPassword = AppPreferences.presetPassword
            // #115 初次打开:若当前格式存了默认值模板,默认勾「使用默认值」并套用 + 隐藏其已配选项。
            reloadFormatDefaults()
            // 默认行为：预设密码可用时复选框默认勾上 + 把预设填入 options.password 和 confirmation。
            if hasUsablePreset {
                useArchivePresetPassword = true
                request.options.password = presetPassword
                request.options.passwordConfirmation = presetPassword
            }
            // Seed 默认签名密钥。只在 options 当前是空字符串时 seed，避免覆盖调用方预设的值（如 Finder 入口）。
            let defaultFp = AppPreferences.gpgDefaultSigningKeyFingerprint
            if !defaultFp.isEmpty && request.options.gpgSigningKeyFingerprint.isEmpty {
                request.options.gpgSigningKeyFingerprint = defaultFp
            }
            // 加载钥匙串（含自有私钥 + 他人公钥）。失败静默忽略，picker 退化到「让 GPG 自动选」/「无可选收件人」。
            if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                Task { @MainActor in
                    if let loaded = try? await GPGBackend.listKeys() {
                        availableKeys = loaded
                    }
                }
            }
        }
    }

    // MARK: - 分区（grouped Form 现代体例；选项集与门控逻辑保持 0.3.x 原样）

    /// 基本：文件名 / 保存位置 / 格式 / 级别 / 更新模式 / 路径模式(非 7z) / 默认值模板 / 分卷。
    @ViewBuilder
    private var basicsSection: some View {
        Section(L10n.text("archive.create.section.basics")) {
            TextField(L10n.text("archive.fileName"), text: fileNameBinding)

            LabeledContent(L10n.text("archive.destination")) {
                HStack(spacing: 8) {
                    Text(request.destinationURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("button.choose")) {
                        chooseDestination()
                    }
                }
            }

            Picker(L10n.text("archive.format"), selection: $request.options.format) {
                ForEach(ArchiveCreateFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .onChange(of: request.options.format) { _ in
                updateDestinationExtension()
            }

            if request.options.format.supportsCompressionLevel, !hidden(.level) {
                Picker(L10n.text("archive.compressionLevel"), selection: $request.options.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
            }

            if request.options.format.supportsUpdateMode, !hidden(.updateMode) {
                Picker(L10n.text("archive.updateMode"), selection: $request.options.updateMode) {
                    ForEach(ArchiveUpdateMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            if request.options.format != .sevenZip, request.options.format.supportsUpdateMode, !hidden(.pathMode) {
                Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                    ForEach(SevenZipPathMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            // #115 本格式存了默认值模板 → 勾上套用模板并隐藏其已配选项，取消则全显。
            if formatDefaultsPreset != nil {
                Toggle(L10n.format("archive.useFormatDefaults", request.options.format.title), isOn: $useFormatDefaults)
                    .help(L10n.text("archive.useFormatDefaults.help"))
                    .onChange(of: useFormatDefaults) { on in
                        if on, let preset = formatDefaultsPreset { preset.apply(to: &request.options) }
                    }
            }

            if request.options.format.supportsVolumeSplitting {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.text("archive.7z.volumeSize"), text: $request.options.sevenZipVolumeSize)
                    if let volumeSizeValidationMessage {
                        validationText(volumeSizeValidationMessage)
                    } else {
                        Text(L10n.text("archive.7z.volumeSizeHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if request.options.format == .rar, !ArchiveService.canCreateRAR() {
                validationText(L10n.text("archive.rar.requiresTool"))
            }
            if let singleFileValidationMessage {
                validationText(singleFileValidationMessage)
            }
        }
    }

    /// 密码与加密：预设密码 / 密码对 / 显示密码 / 加密算法 / 文件名加密(7z·rar)。
    @ViewBuilder
    private var passwordSection: some View {
        Section(L10n.text("archive.create.section.security")) {
            if hasUsablePreset {
                Toggle(L10n.text("button.usePresetPassword"), isOn: $useArchivePresetPassword)
                    .help(L10n.text("button.usePresetPassword.help"))
                    .onChange(of: useArchivePresetPassword) { newValue in
                        if newValue {
                            // 勾选 = password 和 confirmation 都用预设。不动 encryptionMethod。
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
                    if passwordValidationMessage != nil {
                        validationText(L10n.text("error.passwordsDoNotMatch"))
                    }
                }
            }
            if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                if request.options.format == .zip {
                    if !hidden(.encryptionMethod) {
                        Picker(L10n.text("archive.encryptionMethod"), selection: $request.options.encryptionMethod) {
                            ForEach(ArchiveEncryptionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                    }
                } else {
                    LabeledContent(L10n.text("archive.encryptionMethod")) {
                        Text(ArchiveEncryptionMethod.aes256.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if request.options.format == .sevenZip || request.options.format == .rar, !hidden(.encryptFileNames) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.text("archive.7z.encryptFileNames"), isOn: $request.options.sevenZipEncryptFileNames)
                        .disabled(request.options.password.isEmpty)
                    if request.options.password.isEmpty {
                        Text(L10n.text("archive.7z.encryptFileNamesHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 7-Zip 参数：算法 / 字典 / 单词 / 线程 / 内存预估 + 高级折叠区。
    @ViewBuilder
    private var sevenZipSection: some View {
        Section(L10n.text("archive.create.section.sevenZip")) {
            if !hidden(.sevenZipMethod) {
                Picker(L10n.text("archive.7z.method"), selection: $request.options.sevenZipMethod) {
                    ForEach(SevenZipCompressionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
            }
            if !hidden(.dictionarySize) {
                Picker(L10n.text("archive.7z.dictionarySize"), selection: $request.options.sevenZipDictionarySizeMB) {
                    ForEach(dictionarySizeOptions, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
            }
            if !hidden(.wordSize) {
                Picker(L10n.text("archive.7z.wordSize"), selection: $request.options.sevenZipWordSize) {
                    ForEach(wordSizeOptions, id: \.self) { wordSize in
                        Text("\(wordSize)").tag(wordSize)
                    }
                }
            }
            if !hidden(.threadCount) {
                HStack {
                    Text(L10n.text("archive.7z.threads"))
                    Spacer()
                    // 不能 .labelsHidden() —— Stepper 的「label」正是要显示的线程数值（自动 / N）。
                    Stepper(value: $request.options.sevenZipThreadCount, in: 0...maxThreadCount) {
                        Text(threadCountLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent(L10n.text("archive.memoryUsageCompressing")) {
                Text(estimatedCompressionMemoryText)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.text("archive.memoryUsageDecompressing")) {
                Text(estimatedDecompressionMemoryText)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(L10n.text("archive.7z.advanced"), isExpanded: $showsSevenZipAdvancedOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    if !hidden(.solid) {
                        Toggle(L10n.text("archive.7z.solid"), isOn: $request.options.sevenZipSolidArchive)
                    }
                    if request.options.sevenZipSolidArchive, !hidden(.solidBlockSize) {
                        Picker(L10n.text("archive.7z.solidBlockSize"), selection: $request.options.sevenZipSolidBlockSize) {
                            ForEach(SevenZipSolidBlockSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                    }
                    if !hidden(.pathMode) {
                        Picker(L10n.text("archive.7z.pathMode"), selection: $request.options.sevenZipPathMode) {
                            ForEach(SevenZipPathMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    if !hidden(.storeSymlinks) {
                        Toggle(L10n.text("archive.7z.storeSymbolicLinks"), isOn: $request.options.sevenZipStoreSymbolicLinks)
                    }
                    if !hidden(.storeHardlinks) {
                        Toggle(L10n.text("archive.7z.storeHardLinks"), isOn: $request.options.sevenZipStoreHardLinks)
                    }
                    if !hidden(.compressShared) {
                        Toggle(L10n.text("archive.7z.compressSharedFiles"), isOn: $request.options.sevenZipCompressSharedFiles)
                    }
                    Toggle(L10n.text("archive.7z.deleteAfterCompression"), isOn: $request.options.sevenZipDeleteSourceFiles)
                }
                .padding(.top, 6)
            }
        }
    }

    /// 排除规则：.DS_Store / 隐藏文件 / 自定义模式 + 命中计数。
    @ViewBuilder
    private var excludeSection: some View {
        Section(L10n.text("archive.create.section.excludes")) {
            if !hidden(.skipDSStore) {
                Toggle(L10n.text("archive.skipDSStore"), isOn: $request.options.skipDSStore)
            }
            if !hidden(.skipHiddenFiles) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.text("archive.skipHiddenFiles"), isOn: $request.options.skipHiddenFiles)
                    Text(L10n.text("archive.skipHiddenFilesHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !hidden(.customExcludes) {
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
        }
    }

    /// GPG 签名与投递：签名开关 / 密钥 picker(ask 模式) / 留言 / 加密总开关 + 收件人 + 对称密码。
    /// 只在「主开关 + 后端可用」时整段渲染（A4 可见性铁律）。
    @ViewBuilder
    private var gpgSection: some View {
        Section(L10n.text("archive.create.section.gpg")) {
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
                // ask 模式下显示密钥 picker；silent 模式静默用默认密钥（onAppear 已 seed 到 options）。
                if gpgPromptForSigningKey {
                    signingKeyPickerRow
                }
                deliveryNoteRow
                // **总开关默认关 = 仅签名 v2 行为**；关闭时下方两组控件灰掉但仍可见，同时清空 options
                // 避免「用户先填后关 toggle 但加密 params 还潜伏在 options 里被发送」的 footgun。
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
                    .id("gpgSignAnchor")
            }
        }
    }

    /// #110 给收件人的留言行 —— 一个多行 TextField（同 .szs 描述的 idiom，不另造卡片，A1）。
    /// 内容进 `.siz` 「收件人说明」最前面并随签名防篡改；留空则只生成自动的验签 / 解密说明。
    @ViewBuilder
    private var deliveryNoteRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("archive.gpgSign.deliveryNote.label"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(
                L10n.text("archive.gpgSign.deliveryNote.placeholder"),
                text: $request.options.gpgDeliveryNote,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            // 起始 1 行、最多长到 3 行就停 —— 之前 2...5 在窄 sheet 里太高,把下方加密选项挤到 ScrollView 外被截断。
            .lineLimit(1...3)
        }
        // 跟签名密钥 / 收件人 / 对称密码行一样缩进 18 —— 之前没缩进,留言行比上下兄弟行多顶出去一截(左边不齐)。
        .padding(.leading, 18)
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

    /// 加密收件人**候选公钥**：两个 ring 都列（`~/.gnupg/` + SimpleZip 私有环），但**只列有加密能力的**——
    /// 纯签名 / 认证密钥不能当收件人，gpg 会报「unusable public key」。私有环收件人的加密走私有 `--homedir`
    /// （ArchiveCreationService 按收件人所在环选 homedir）；不允许一次加密混选两环（下方 `recipientRingValidationMessage` 拦）。
    private var encryptionEligibleKeys: [GPGBackend.GPGKey] {
        availableKeys.filter { $0.canEncryptToRecipient }
    }

    /// 已选收件人分布在哪些 ring —— 用于「混选两环」拦截。一次 gpg 加密只能用一个 homedir。
    private var selectedRecipientSources: Set<GPGBackend.GPGKeyringSource> {
        Set(request.options.gpgRecipientFingerprints.compactMap { fp in
            availableKeys.first(where: { $0.fingerprint == fp })?.source
        })
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
            GPGSecretKeyMenu(
                selection: $request.options.gpgSigningKeyFingerprint,
                secretKeys: availableKeys.filter { $0.hasSecretKey },
                autoLabelKey: "archive.gpgSign.key.auto",
                missingFingerprintKey: "archive.gpgSign.key.missingFingerprint"
            )
        }
        .padding(.leading, 18)
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
        if let recipientRingValidationMessage {
            return recipientRingValidationMessage
        }
        return nil
    }

    /// 收件人混选了两个 keyring → 一次 gpg 加密做不到，拦下来（跟「加密为 GPG」对话框同口径）。
    private var recipientRingValidationMessage: String? {
        selectedRecipientSources.count > 1 ? L10n.text("gpgEncrypt.mixedKeyrings") : nil
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
