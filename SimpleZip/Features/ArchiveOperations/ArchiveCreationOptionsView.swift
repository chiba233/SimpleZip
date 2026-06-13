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
    @State private var excludedFileCount: Int?
    /// 0.4.2 #18：被排除文件的相对路径预览（跟 count 同一次扫描取回）。nil = 还没统计过。
    @State private var excludedPreview: [String]?
    /// 0.4.2 #19：压缩前预检结果。nil = 还没跑。
    @State private var dryRun: ArchiveService.ArchiveCreationDryRun?
    @State private var isRunningDryRun = false
    /// 0.4.4 #12:压缩率**预估**(取样 + Compression 框架外推;dryRun / 格式 / 级别变了重算)。nil = 未算 / 无法估。
    @State private var estimatedCompressedBytes: Int64?
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
    /// 0.4.2 #17：套模板改格式时跳过一次「按格式默认值」重套 —— 模板优先于格式默认值。
    @State private var suppressFormatDefaultsOnce = false
    /// 0.4.4 #33:本格式「你最常用的设置」推荐(由本地使用频率得出)。只在没有保存默认值模板时出现,
    /// 一键把习惯选项填进来 —— 与「使用默认值」互斥(有保存默认值时由那条接管)。
    @State private var usageRecommendation: CompressionFormatPreset?
    /// 0.4.2 #30：智能卡在位状态。nil = 还没检测（或检测中）。
    @State private var smartcardPresent: Bool?
    @State private var isCheckingSmartcard = false
    private let compressionDefaultsStore = CompressionDefaultsStore()
    /// 「使用发布助手」(套用模板旁,用户点名):关掉本对话框、带着当前请求转进发布助手。
    /// nil = 不显示按钮(调用方没接)。
    var openReleaseAssistant: (() -> Void)? = nil
    let create: (ArchiveCreationRequest) -> Void
    let cancel: () -> Void

    private var hasUsablePreset: Bool { presetPasswordEnabled && !presetPassword.isEmpty }

    /// 某选项是否被本格式模板接管而应在创建对话框里隐藏 —— 勾了「使用默认值」且该字段在模板里。
    private func hidden(_ field: CompressionOptionField) -> Bool {
        useFormatDefaults && (formatDefaultsPreset?.includedFields.contains(field) ?? false)
    }

    /// 0.4.2 #17：内置任务模板菜单 —— 一键套常见场景（GitHub Release ZIP / Windows 友好 ZIP /
    /// 最大压缩 7z / 加密投递包 / 源码包 / 备份包）。只动通用选项；密码 / GPG / 名字目的地保留。
    @ViewBuilder
    private var templateMenuRow: some View {
        HStack {
            Menu {
                ForEach(CompressionPreset.builtInTemplates()) { template in
                    Button(template.name) { applyBuiltInTemplate(template) }
                }
            } label: {
                Label(L10n.text("archive.template.menu"), systemImage: "wand.and.stars")
            }
            .fixedSize()
            if let openReleaseAssistant {
                // 发布场景的一键转场:打包+检查+校验文件一条流交给发布助手。
                Button(action: openReleaseAssistant) {
                    Label(L10n.text("archive.useReleaseAssistant"), systemImage: "shippingbox.and.arrow.backward")
                }
                .fixedSize()
            }
            Spacer()
        }
    }

    private func applyBuiltInTemplate(_ template: CompressionPreset) {
        var options = template.options
        // 逐次字段不受模板影响：密码区 / 详情开关 / GPG 配置都保留用户当前所填。
        options.password = request.options.password
        options.passwordConfirmation = request.options.passwordConfirmation
        options.showPassword = request.options.showPassword
        options.showDetails = request.options.showDetails
        options.gpgSign = request.options.gpgSign
        options.gpgSigningKeyFingerprint = request.options.gpgSigningKeyFingerprint
        options.gpgRecipientFingerprints = request.options.gpgRecipientFingerprints
        options.gpgSymmetricPassphrase = request.options.gpgSymmetricPassphrase
        options.gpgDeliveryNote = request.options.gpgDeliveryNote
        // 模板优先：若格式因此切换，跳过那一次「按格式默认值」重套；同格式时直接关掉默认值接管。
        suppressFormatDefaultsOnce = options.format != request.options.format
        useFormatDefaults = false
        request.options = options
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
        reloadUsageRecommendation()
    }

    /// #33:刷新「你最常用的设置」推荐 —— 仅在记录开关开、且本格式没有保存默认值(那条更优先)时取众数预设。
    private func reloadUsageRecommendation() {
        guard AppPreferences.compressionUsageTrackingEnabled, formatDefaultsPreset == nil else {
            usageRecommendation = nil
            return
        }
        usageRecommendation = CompressionUsageStore().mostUsedPreset(for: request.options.format)
    }

    /// 应用推荐会不会真的改动当前选项(不会改 = 不展示推荐行,避免无意义入口)。
    private var usageRecommendationWouldChange: Bool {
        guard let preset = usageRecommendation else { return false }
        var probe = request.options
        preset.apply(to: &probe)
        return probe != request.options
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "plus.square.on.square",
                colors: [.orange, .pink],
                title: L10n.text("archive.create.title"),
                subtitle: L10n.format("archive.create.subtitle", "\(request.sourceURLs.count)")
            )

            // 0.4.1（用户拍板）：常用选项直出（基本 / 密码），不常用选项全部进抽屉（高级 / 7-Zip /
            // 排除 / GPG）。高度自适应内容，maxHeight 兜底防超屏 —— 不再写死 sheet 高度。
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        templateMenuRow
                        basicsSection
                        // 0.4.2 用户点名：预检是高频 UI，不进二级抽屉 —— 常驻概要条，
                        // 出现即自动统计，排除规则 / 分卷 / 格式变更自动重算。
                        preflightStrip
                        if request.options.format.supportsPassword {
                            passwordSection
                        }
                        if showsAdvancedDrawer {
                            advancedDrawer
                        }
                        if request.options.format == .sevenZip {
                            sevenZipDrawer
                        }
                        if request.options.format.supportsExcludeRules {
                            excludeDrawer
                        }
                        if AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                            gpgDrawer
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 620)
                .onChange(of: request.options.gpgSign) { newValue in
                    guard newValue else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo("gpgSignAnchor", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            PinnedBottomBar {
                ShowDetailsToggleButton(isOn: $request.options.showDetails)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: cancel) {
                    Label(L10n.text("button.cancel"), systemImage: "xmark")
                }
                Button {
                    normalizeDestinationForCurrentFormat()
                    create(request)
                } label: {
                    Label(L10n.text("button.create"), systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 700)
        // 点输入框以外的任意空白 → 释放第一响应者（用户报：焦点一直黏在输入框上，UX 很差）。
        // 手势挂在整个 sheet 上：控件自己吃掉点击，只有空白区会落到这里。
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .animation(.default, value: request.options.format)
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
            // 0.4.2 #17:刚套完内置模板的那次格式切换除外 —— 模板的值优先,不被默认值盖掉。
            if suppressFormatDefaultsOnce {
                suppressFormatDefaultsOnce = false
                formatDefaultsPreset = compressionDefaultsStore.preset(for: request.options.format)
                useFormatDefaults = false
                reloadUsageRecommendation()
            } else {
                reloadFormatDefaults()
            }
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

    // MARK: - 分区（常用直出）与抽屉（不常用收起）。所有选项与门控逻辑保持原样。

    /// 基本（常用）：文件名 / 保存位置 / 格式 / 压缩级别 / 默认值模板。
    @ViewBuilder
    private var basicsSection: some View {
        DialogSection(L10n.text("archive.create.section.basics")) {
            LabeledContent {
                TextField("", text: fileNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
            } label: {
                DialogRowLabel(L10n.text("archive.fileName"), systemImage: "character.cursor.ibeam", tint: .pink)
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Text(request.destinationURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button(L10n.text("button.choose")) {
                        chooseDestination()
                    }
                }
            } label: {
                DialogRowLabel(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue)
            }

            LabeledContent {
                Picker("", selection: $request.options.format) {
                    ForEach(ArchiveCreateFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: request.options.format) { _ in
                    updateDestinationExtension()
                }
            } label: {
                DialogRowLabel(L10n.text("archive.format"), systemImage: "shippingbox.fill", tint: .brown)
            }

            if request.options.format.supportsCompressionLevel, !hidden(.level) {
                LabeledContent {
                    Picker("", selection: $request.options.compressionLevel) {
                        ForEach(CompressionLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // #12:级别影响预估(仅存储 vs 压缩),变了重算。
                    .onChange(of: request.options.compressionLevel) { _ in recomputeCompressionEstimate() }
                } label: {
                    DialogRowLabel(L10n.text("archive.compressionLevel"), systemImage: "gauge.with.dots.needle.67percent", tint: .green)
                }
            }

            // #115 本格式存了默认值模板 → 勾上套用模板并隐藏其已配选项，取消则全显。
            if formatDefaultsPreset != nil {
                DialogToggleRow(
                    title: L10n.format("archive.useFormatDefaults", request.options.format.title),
                    systemImage: "square.stack.3d.up.fill",
                    tint: .indigo,
                    isOn: $useFormatDefaults
                )
                .help(L10n.text("archive.useFormatDefaults.help"))
                .onChange(of: useFormatDefaults) { on in
                    if on, let preset = formatDefaultsPreset { preset.apply(to: &request.options) }
                }
            }

            // #33:没有保存默认值时,给「你最常用的设置」一键应用入口(应用后这条自动消失,因为不再有变化)。
            if formatDefaultsPreset == nil, usageRecommendation != nil, usageRecommendationWouldChange {
                LabeledContent {
                    Button(L10n.text("archive.usageRecommendation.apply")) {
                        if let preset = usageRecommendation {
                            preset.apply(to: &request.options)
                            recomputeCompressionEstimate()
                        }
                    }
                } label: {
                    DialogRowLabel(L10n.text("archive.usageRecommendation.title"), systemImage: "wand.and.stars", tint: .purple)
                }
                .help(L10n.text("archive.usageRecommendation.help"))
            }

            if request.options.format == .rar, !ArchiveService.canCreateRAR() {
                validationText(L10n.text("archive.rar.requiresTool"))
            }
            if let singleFileValidationMessage {
                validationText(singleFileValidationMessage)
            }
        }
    }

    /// 密码与加密（常用）：预设密码 / 密码对 / 显示密码 / 加密算法 / 文件名加密(7z·rar)。
    @ViewBuilder
    private var passwordSection: some View {
        DialogSection(L10n.text("archive.create.section.security")) {
            if hasUsablePreset {
                DialogToggleRow(
                    title: L10n.text("button.usePresetPassword"),
                    systemImage: "key.fill",
                    tint: .orange,
                    isOn: $useArchivePresetPassword
                )
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
                passwordField(L10n.text("archive.password"), systemImage: "key.fill", text: $request.options.password)
                if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                    passwordField(L10n.text("archive.passwordConfirm"), systemImage: "key.viewfinder", text: $request.options.passwordConfirmation)
                    DialogToggleRow(
                        title: L10n.text("archive.showPassword"),
                        systemImage: "eye.fill",
                        tint: .gray,
                        isOn: $request.options.showPassword
                    )
                    if passwordValidationMessage != nil {
                        validationText(L10n.text("error.passwordsDoNotMatch"))
                    }
                }
            }
            if !request.options.password.isEmpty || !request.options.passwordConfirmation.isEmpty {
                if request.options.format == .zip {
                    if !hidden(.encryptionMethod) {
                        LabeledContent {
                            Picker("", selection: $request.options.encryptionMethod) {
                                ForEach(ArchiveEncryptionMethod.allCases) { method in
                                    Text(method.title).tag(method)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            DialogRowLabel(L10n.text("archive.encryptionMethod"), systemImage: "shield.lefthalf.filled", tint: .purple)
                        }
                    }
                } else {
                    LabeledContent {
                        Text(ArchiveEncryptionMethod.aes256.title)
                            .foregroundStyle(.secondary)
                    } label: {
                        DialogRowLabel(L10n.text("archive.encryptionMethod"), systemImage: "shield.lefthalf.filled", tint: .purple)
                    }
                }
            }
            if request.options.format == .sevenZip || request.options.format == .rar, !hidden(.encryptFileNames) {
                VStack(alignment: .leading, spacing: 4) {
                    DialogToggleRow(
                        title: L10n.text("archive.7z.encryptFileNames"),
                        systemImage: "eye.slash.fill",
                        tint: .purple,
                        isOn: $request.options.sevenZipEncryptFileNames
                    )
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

    /// 抽屉内的二级开关行：单色 Label，**复选框紧随文字右侧**（复选框一律不靠左,设计准则）。
    private func drawerToggle(_ titleKey: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Label(L10n.text(titleKey), systemImage: systemImage)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    /// 高级抽屉是否有内容可展示（没有任何适用行就整个不渲染）。
    private var showsAdvancedDrawer: Bool {
        request.options.format.supportsUpdateMode
            || request.options.format.supportsVolumeSplitting
            || request.options.format.supportsRawParameters
    }

    /// 高级选项（抽屉·不常用）：更新模式 / 路径模式(非 7z) / 分卷 / 自定义参数。
    @ViewBuilder
    private var advancedDrawer: some View {
        DialogDrawer(L10n.text("archive.create.section.advanced"), systemImage: "slider.horizontal.3", color: .gray) {
            // 0.4.3 #10:可复现压缩(仅 zip / 7z —— tar 系走系统 tar,无时间戳钳制参数)。
            if request.options.format == .zip || request.options.format == .sevenZip {
                VStack(alignment: .leading, spacing: 4) {
                    drawerToggle("archive.reproducible", systemImage: "equal.circle", isOn: Binding(
                        get: { request.options.reproducibleArchive == true },
                        set: { request.options.reproducibleArchive = $0 ? true : nil }
                    ))
                    Text(L10n.text("archive.reproducible.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if request.options.format.supportsUpdateMode, !hidden(.updateMode) {
                LabeledContent {
                    Picker("", selection: $request.options.updateMode) {
                        ForEach(ArchiveUpdateMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.updateMode"), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if request.options.format != .sevenZip, request.options.format.supportsUpdateMode, !hidden(.pathMode) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipPathMode) {
                        ForEach(SevenZipPathMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.pathMode"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }

            if request.options.format.supportsVolumeSplitting {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        TextField("", text: $request.options.sevenZipVolumeSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    } label: {
                        Label(L10n.text("archive.7z.volumeSize"), systemImage: "square.split.2x1.fill")
                    }
                    if let volumeSizeValidationMessage {
                        validationText(volumeSizeValidationMessage)
                    } else {
                        Text(L10n.text("archive.7z.volumeSizeHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if request.options.format.supportsRawParameters, !hidden(.rawParameters) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        TextField("", text: $request.options.rawParameters)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                    } label: {
                        Label(L10n.text("archive.parameters"), systemImage: "terminal.fill")
                    }
                    Text(L10n.text("archive.parametersHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 7-Zip 参数（抽屉·不常用）：算法 / 字典 / 单词 / 线程 / 内存预估 / 固实与链接等全部参数。
    @ViewBuilder
    private var sevenZipDrawer: some View {
        DialogDrawer(L10n.text("archive.create.section.sevenZip"), systemImage: "gearshape.2.fill", color: .indigo) {
            if !hidden(.sevenZipMethod) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipMethod) {
                        ForEach(SevenZipCompressionMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.method"), systemImage: "cpu.fill")
                }
            }
            if !hidden(.dictionarySize) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipDictionarySizeMB) {
                        ForEach(dictionarySizeOptions, id: \.self) { size in
                            Text("\(size) MB").tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.dictionarySize"), systemImage: "memorychip.fill")
                }
            }
            if !hidden(.wordSize) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipWordSize) {
                        ForEach(wordSizeOptions, id: \.self) { wordSize in
                            Text("\(wordSize)").tag(wordSize)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.wordSize"), systemImage: "textformat.123")
                }
            }
            if !hidden(.threadCount) {
                // 数值文本钉死在 ▲▼ 按钮左侧（用户报：值会到处飘）。
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(threadCountLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $request.options.sevenZipThreadCount, in: 0...maxThreadCount)
                            .labelsHidden()
                    }
                } label: {
                    Label(L10n.text("archive.7z.threads"), systemImage: "square.stack.3d.forward.dottedline.fill")
                }
            }

            LabeledContent {
                Text(estimatedCompressionMemoryText)
                    .foregroundStyle(.secondary)
            } label: {
                Label(L10n.text("archive.memoryUsageCompressing"), systemImage: "memorychip")
            }
            LabeledContent {
                Text(estimatedDecompressionMemoryText)
                    .foregroundStyle(.secondary)
            } label: {
                Label(L10n.text("archive.memoryUsageDecompressing"), systemImage: "arrow.down.circle.fill")
            }

            Divider()

            if !hidden(.solid) {
                drawerToggle("archive.7z.solid", systemImage: "cube.fill", isOn: $request.options.sevenZipSolidArchive)
            }
            if request.options.sevenZipSolidArchive, !hidden(.solidBlockSize) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipSolidBlockSize) {
                        ForEach(SevenZipSolidBlockSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.solidBlockSize"), systemImage: "square.grid.3x3.fill")
                }
            }
            if !hidden(.pathMode) {
                LabeledContent {
                    Picker("", selection: $request.options.sevenZipPathMode) {
                        ForEach(SevenZipPathMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Label(L10n.text("archive.7z.pathMode"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
            if !hidden(.storeSymlinks) {
                drawerToggle("archive.7z.storeSymbolicLinks", systemImage: "link", isOn: $request.options.sevenZipStoreSymbolicLinks)
            }
            if !hidden(.storeHardlinks) {
                drawerToggle("archive.7z.storeHardLinks", systemImage: "link.badge.plus", isOn: $request.options.sevenZipStoreHardLinks)
            }
            if !hidden(.compressShared) {
                drawerToggle("archive.7z.compressSharedFiles", systemImage: "doc.on.doc.fill", isOn: $request.options.sevenZipCompressSharedFiles)
            }
            drawerToggle("archive.7z.deleteAfterCompression", systemImage: "trash.fill", isOn: $request.options.sevenZipDeleteSourceFiles)
        }
    }

    /// 排除规则（抽屉·不常用）：.DS_Store / 隐藏文件 / 自定义模式 + 命中计数。
    @ViewBuilder
    private var excludeDrawer: some View {
        DialogDrawer(L10n.text("archive.create.section.excludes"), systemImage: "eye.slash.fill", color: .teal) {
            if !hidden(.skipDSStore) {
                drawerToggle("archive.skipDSStore", systemImage: "doc.badge.gearshape.fill", isOn: $request.options.skipDSStore)
            }
            if !hidden(.skipHiddenFiles) {
                VStack(alignment: .leading, spacing: 4) {
                    drawerToggle("archive.skipHiddenFiles", systemImage: "eye.slash", isOn: $request.options.skipHiddenFiles)
                    Text(L10n.text("archive.skipHiddenFilesHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !hidden(.customExcludes) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("archive.customExcludes"), systemImage: "line.3.horizontal.decrease.circle.fill")
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
                        Button {
                            countExcludedFiles()
                        } label: {
                            Label(L10n.text("archive.countExcludedFiles"), systemImage: "number.circle.fill")
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
                    // 0.4.2 #18：被排除文件的预览列表（前 15 条 + 折叠计数），跟统计同一次扫描。
                    if let excludedPreview, !excludedPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(excludedPreview.prefix(15), id: \.self) { path in
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                            if excludedPreview.count > 15 {
                                Text(L10n.format("archive.excludedPreview.more", "\(excludedPreview.count - 15)"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 0.4.2（用户点名升一级）：创建前预检 —— 常驻概要条。出现即自动统计；
    /// 排除规则 / 分卷 / 格式变更自动重算（onChange 挂在本条上）。输出名冲突即时显示。
    @ViewBuilder
    private var preflightStrip: some View {
        DialogSection(L10n.text("archive.dryRun.section")) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let dryRun {
                    // 概要项进自适应网格：每项**强制单行**（lineLimit(1)+fixedSize），
                    // 放不下换列不换行 —— 0.4.2 用户报「有的挤成两行有的一行」。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                        Label(
                            L10n.format(
                                "archive.dryRun.input",
                                "\(dryRun.inputFileCount)",
                                ByteCountFormatter.string(fromByteCount: dryRun.totalBytes, countStyle: .file)
                            ),
                            systemImage: "doc.on.doc"
                        )
                        .lineLimit(1).fixedSize()
                        // #12:压缩率预估(取样外推;标「≈」表明是估算)。
                        if let estimate = estimatedCompressedBytes, dryRun.totalBytes > 0 {
                            Label(
                                L10n.format(
                                    "archive.dryRun.estimate",
                                    ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file),
                                    "\(Int((Double(estimate) / Double(dryRun.totalBytes) * 100).rounded()))%"
                                ),
                                systemImage: "arrow.down.right.and.arrow.up.left"
                            )
                            .lineLimit(1).fixedSize()
                            .help(L10n.text("archive.dryRun.estimate.help"))
                        }
                        if dryRun.excludedCount > 0 {
                            Label(L10n.format("archive.dryRun.excluded", "\(dryRun.excludedCount)"), systemImage: "eye.slash")
                                .lineLimit(1).fixedSize()
                        }
                        if dryRun.symlinkCount > 0 {
                            Label(L10n.format("archive.dryRun.symlinks", "\(dryRun.symlinkCount)"), systemImage: "link")
                                .lineLimit(1).fixedSize()
                        }
                        if dryRun.packageCount > 0 {
                            Label(L10n.format("archive.dryRun.packages", "\(dryRun.packageCount)"), systemImage: "shippingbox")
                                .lineLimit(1).fixedSize()
                        }
                        if let volumes = dryRun.estimatedVolumeCount {
                            Label(L10n.format("archive.dryRun.volumes", "\(volumes)"), systemImage: "square.stack.3d.up")
                                .lineLimit(1).fixedSize()
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Label(L10n.text("archive.dryRun.calculating"), systemImage: "doc.on.doc")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if isRunningDryRun {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        runDryRun()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("archive.dryRun.run"))
                }
            }
            // 输出名冲突即时检查 —— 不用走文件树，随渲染刷新。
            if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                Label(L10n.text("archive.dryRun.outputExists"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            // 打开窗口即静默跑的内联 AI 速览(预估耗时 + 格式/级别建议 + 冲突提醒)。动态:数据/格式/级别变了重跑。仅 isReady 时出现。
            if let dryRun {
                // 统计区 ↔ AI 区之间一道很薄的分割线(用户点名);仅 AI 可用、确实会出速览时才画,避免悬空线。
                if AIReportAssistant.isReady {
                    Divider().opacity(0.5).padding(.vertical, 1)
                }
                InlineAIAdvisory(
                    token: "\(dryRun.inputFileCount)|\(dryRun.totalBytes)|\(estimatedCompressedBytes ?? -1)|\(request.options.format)|\(request.options.compressionLevel)|\(FileManager.default.fileExists(atPath: request.destinationURL.path))"
                ) {
                    guard #available(macOS 26.0, *) else { return "" }
                    let built = AIReportAssistant.createAdvisoryPrompt(
                        dryRun: dryRun,
                        estimatedCompressedBytes: estimatedCompressedBytes,
                        format: "\(request.options.format)",
                        compressionLevel: "\(request.options.compressionLevel)",
                        outputExists: FileManager.default.fileExists(atPath: request.destinationURL.path)
                    )
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
            }
        }
        .onAppear { runDryRun() }
        .onChange(of: request.options.skipDSStore) { _ in runDryRun() }
        .onChange(of: request.options.skipHiddenFiles) { _ in runDryRun() }
        .onChange(of: request.options.customExcludes) { _ in runDryRun() }
        .onChange(of: request.options.sevenZipVolumeSize) { _ in runDryRun() }
        .onChange(of: request.options.format) { _ in runDryRun() }
    }

    /// GPG 签名与投递（抽屉·不常用）。只在「主开关 + 后端可用」时整个抽屉渲染（A4 可见性铁律）。
    @ViewBuilder
    private var gpgDrawer: some View {
        DialogDrawer(L10n.text("archive.create.section.gpg"), systemImage: "signature", color: .green, initiallyExpanded: request.options.gpgSign) {
            drawerToggle("archive.gpgSign", systemImage: "checkmark.seal.fill", isOn: $request.options.gpgSign)
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
                drawerToggle("archive.gpgEncrypt.useEncryption", systemImage: "lock.fill", isOn: $useGPGEncryption)
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
        // 用户拍板：标签和输入框必须两行（标签在上、输入框整行在下），不搞「标签 + 右侧输入框」。
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("archive.gpgSign.deliveryNote.label"), systemImage: "text.bubble.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(
                L10n.text("archive.gpgSign.deliveryNote.placeholder"),
                text: $request.options.gpgDeliveryNote,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
        }
    }

    /// 收件人 picker 行 —— GPG 签名勾上时显示。当前选中的收件人以 chip 形式横列；右侧 Menu 按钮可点开添加新收件人。
    /// 多次点击 Menu 累加多个收件人；chip 上的 × 移除单个。0 收件人 = 「未加密」（除非另设了对称密码）。
    @ViewBuilder
    private var recipientsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(L10n.text("archive.gpgEncrypt.recipientsLabel"), systemImage: "person.2.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                GPGAddRecipientMenu(eligibleKeys: encryptionEligibleKeys, selection: $request.options.gpgRecipientFingerprints)
                Spacer()
            }
            GPGRecipientChipRow(selection: $request.options.gpgRecipientFingerprints, lookupKeys: availableKeys)
        }
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
        // 标签在上、输入框整行在下（用户拍板的两行布局），提示再占一行。
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("archive.gpgEncrypt.passphraseLabel"), systemImage: "lock.rectangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            SecureField(L10n.text("archive.gpgEncrypt.passphrasePlaceholder"), text: $request.options.gpgSymmetricPassphrase)
                .textFieldStyle(.roundedBorder)
            Text(L10n.text("archive.gpgEncrypt.passphraseHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 签名密钥 picker —— ask 模式下显示在「用 GPG 签名」复选框正下方。
    /// 列出所有 `hasSecretKey` 密钥（含智能卡 stub），首项「让 GPG 自动选」对应空 fingerprint = 走 gpg default-key。
    @ViewBuilder
    private var signingKeyPickerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("archive.gpgSign.keyLabel"), systemImage: "person.badge.key.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            GPGSecretKeyMenu(
                selection: $request.options.gpgSigningKeyFingerprint,
                secretKeys: availableKeys.filter { $0.hasSecretKey },
                autoLabelKey: "archive.gpgSign.key.auto",
                missingFingerprintKey: "archive.gpgSign.key.missingFingerprint"
            )
            // 0.4.2 #30：选中的签名密钥在智能卡上 → 明确预告（需插卡 / 可能弹 PIN）+ 实测卡在不在位。
            if selectedSigningKeyUsesSmartcard {
                smartcardStatusRow
            }
        }
    }

    /// 选中的签名密钥（或其能签名的子密钥）私钥是否在智能卡上。
    private var selectedSigningKeyUsesSmartcard: Bool {
        let fingerprint = request.options.gpgSigningKeyFingerprint
        guard !fingerprint.isEmpty,
              let key = availableKeys.first(where: { $0.fingerprint == fingerprint }) else { return false }
        return key.isSecretKeyOnSmartcard || key.subkeys.contains { $0.isOnSmartcard && $0.canSign }
    }

    @ViewBuilder
    private var smartcardStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L10n.text("archive.gpgSign.smartcard.notice"), systemImage: "creditcard")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch smartcardPresent {
                case .some(true):
                    Label(L10n.text("archive.gpgSign.smartcard.present"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .some(false):
                    Label(L10n.text("archive.gpgSign.smartcard.absent"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .none:
                    if isCheckingSmartcard {
                        ProgressView().controlSize(.small)
                    }
                }
                Button(L10n.text("archive.gpgSign.smartcard.recheck")) {
                    checkSmartcardPresence()
                }
                .controlSize(.small)
                .disabled(isCheckingSmartcard)
            }
        }
        .onAppear { checkSmartcardPresence() }
        .onChange(of: request.options.gpgSigningKeyFingerprint) { _ in
            checkSmartcardPresence()
        }
    }

    /// 问 gpg 卡在不在位（`--card-status`）。抛错 / 返回 nil 都按「未检测到卡」处理。
    private func checkSmartcardPresence() {
        guard !isCheckingSmartcard else { return }
        isCheckingSmartcard = true
        Task { @MainActor in
            let status = try? await GPGBackend.cardStatus()
            smartcardPresent = (status != nil)
            isCheckingSmartcard = false
        }
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
            excludedPreview = []
            return
        }
        let sourceURLs = request.sourceURLs
        let options = request.options
        isCountingExcludedFiles = true
        Task { @MainActor in
            // 0.4.2 #18：同一次扫描顺便取回被排除文件列表（预览）——count 和列表绝不允许两套口径。
            let preview = await Task.detached(priority: .utility) {
                ArchiveService.excludedFilePreview(in: sourceURLs, options: options)
            }.value
            excludedFileCount = preview.count
            excludedPreview = preview
            isCountingExcludedFiles = false
        }
    }

    /// 0.4.2 #19：压缩前预检 —— 输入文件数 / 总大小 / 排除数 / 符号链接 / 包目录 / 分卷估算。
    private func runDryRun() {
        let sourceURLs = request.sourceURLs
        let options = request.options
        isRunningDryRun = true
        Task { @MainActor in
            let summary = await Task.detached(priority: .utility) {
                ArchiveService.dryRunSummary(sourceURLs: sourceURLs, options: options)
            }.value
            dryRun = summary
            isRunningDryRun = false
            recomputeCompressionEstimate()
        }
    }

    /// #12:取样 + Compression 框架外推压缩率预估。依赖 dryRun.totalBytes;取样 I/O 放后台。
    private func recomputeCompressionEstimate() {
        guard let total = dryRun?.totalBytes, total > 0 else { estimatedCompressedBytes = nil; return }
        let sourceURLs = request.sourceURLs
        let format = request.options.format
        let level = request.options.compressionLevel.rawValue
        Task { @MainActor in
            let estimate = await Task.detached(priority: .utility) { () -> Int64? in
                let sample = Self.gatherCompressionSample(from: sourceURLs)
                guard let compressed = CompressionEstimator.compressedSampleSize(of: sample, format: format, level: level) else { return nil }
                return CompressionEstimator.estimatedTotal(totalBytes: total, sampleBytes: sample.count, compressedSample: compressed)
            }.value
            estimatedCompressedBytes = estimate
        }
    }

    /// 跨选区抽样:最多 64 个文件、各取头部一段,总量封顶 4MB —— 够代表性又不读爆大目录。
    /// `nonisolated`:纯 FS 读,从 Task.detached(非主 actor)调,不碰主 actor 状态。
    private nonisolated static func gatherCompressionSample(from urls: [URL], budget: Int = 4_000_000) -> Data {
        let fileManager = FileManager.default
        var files: [URL] = []
        outer: for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for case let candidate as URL in enumerator {
                    if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        files.append(candidate)
                        if files.count >= 64 { break outer }
                    }
                }
            } else {
                files.append(url)
                if files.count >= 64 { break }
            }
        }
        guard !files.isEmpty else { return Data() }
        let perFile = max(64_000, budget / files.count)
        var sample = Data()
        for file in files {
            guard sample.count < budget else { break }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            if let chunk = try? handle.read(upToCount: perFile) { sample.append(chunk) }
        }
        return sample
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
    private func passwordField(_ title: String, systemImage: String, text: Binding<String>) -> some View {
        LabeledContent {
            Group {
                if request.options.showPassword {
                    TextField("", text: text)
                } else {
                    SecureField("", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .dialogFieldEmphasis()
            .frame(maxWidth: 260)
        } label: {
            DialogRowLabel(title, systemImage: systemImage, tint: .orange)
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
