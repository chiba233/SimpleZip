//
//  ExtractArchiveOptionsView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/13.
//

import SwiftUI

/// 整包解压前的选项面板：目标目录和可选密码。
struct ExtractArchiveOptionsView: View {
    @State var request: ExtractArchiveRequest
    let extract: (ExtractArchiveRequest) -> Void
    let cancel: () -> Void
    /// 用户可用于解密的私钥（hasSecretKey）。GPG 启用 + 后端可用时 onAppear 异步加载。
    @State private var availableSecretKeys: [GPGBackend.GPGKey] = []

    // 0.4.2 #8 解压前预检：onAppear 后台 list 一次，算「将解出多少 / 多大 / 有无 symlink /
    // 可疑路径 / 加密 / 覆盖风险 / 缺分卷」。读不到（加密 header 等）只收起概要，绝不挡解压。
    @State private var preflight: ArchiveExtractPreflight?
    @State private var preflightTopLevelNames: [String] = []
    @State private var preflightUnavailable = false
    /// 0.4.3 #4:目标卷剩余空间不足时的警示(needed/available 已格式化)。nil = 空间够 / 未知。
    /// 预计大小是**下限**(后端没报大小的条目按 0 计),所以只警示不硬拦 —— 用户可换目标卷再解。
    @State private var lowSpaceWarning: (needed: String, available: String)?
    @State private var overwriteCount = 0
    @State private var missingVolumeCount = 0

    var body: some View {
        ExtractOptionsForm(
            title: L10n.text("extract.archive.title"),
            subtitle: request.archiveURL.lastPathComponent,
            destinationURL: $request.destinationURL,
            password: $request.password,
            zipDecryptionMethod: $request.zipDecryptionMethod,
            showDetails: $request.showDetails,
            showsZipDecryptionMethod: request.archiveURL.pathExtension.lowercased() == "zip",
            zipEncryptionDetectionText: request.detectedZipEncryption.autoDetectionText,
            confirm: { extract(request) },
            cancel: cancel
        ) {
            // #12:套用预设 —— 与创建对话框「套用模板」同款形态,一键填常见开关组合。
            presetMenuRow
            // 0.4.2 #8：解压前概要（文件数 / 大小 / 风险行）。
            preflightRows
            // 0.4.2 用户点名：不解压 macOS 元数据垃圾（staging 上清扫,目标目录原有文件零接触）。
            skipJunkToggle
            // 0.4.3 #15：不解压符号链接（同样 staging 上处理;预检概要里有链接计数行可对照）。
            skipSymlinksToggle
            // #13 智能去单层目录:仅当预检发现统一壳时出现,副标题写清两种选择的**最终路径**。
            if request.detectedSingleRootFolder != nil {
                stripSingleRootToggle
            }
            // #12:解到同名文件夹 / 冲突自动重命名 / 完成后显示 / 原包进废纸篓(全部默认关)。
            intoSubfolderToggle
            autoRenameToggle
            revealWhenDoneToggle
            trashOriginalToggle
            // `.siz` 直接解压时多三行：签名状态 / 签名时间 / 签名指纹。普通归档时为 nil，extraControls 为空。
            if let signature = request.sizSignature {
                SIZSignatureRows(signature: signature)
            }
            // GPG 解密密钥 picker —— **仅 `.siz` 解压时显示**。
            // 因为只有 SimpleZip 专有 `.siz` v3 会用 GPG 多收件人加密内层 archive；
            // 通用 zip / 7z / rar / tar 等格式不支持 GPG 非对称加密，picker 出现是噪音。
            if isSizExtract && AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                gpgDecryptionKeyRow
                // 加密 .siz 且带对称密码时，多一个 SecureField 让用户填 GPG 解密密码。
                // 0.1.9 的关键 UX：跟内层 ZIP/7z 的加密密码（password 字段）**完全独立** —— 它俩可能是两份不同密码。
                if request.sizSignature?.encryption?.hasSymmetricPassphrase == true {
                    gpgDecryptionPassphraseRow
                }
            }
        }
        .frame(width: 560)
        .onAppear {
            // 仅 .siz 才需要载入密钥列表 —— 通用格式 picker 不显示，省一次 listKeys 调用。
            if isSizExtract && AppPreferences.gpgEnabled && GPGBackend.isAvailable() {
                Task { @MainActor in
                    if let loaded = try? await GPGBackend.listKeys() {
                        availableSecretKeys = loaded.filter { $0.hasSecretKey }
                    }
                }
            }
            loadPreflight()
            computeMissingVolumes()
        }
        // 用户换目标目录 → 覆盖风险行实时重算。
        .onChange(of: request.destinationURL) { _ in
            recomputeOverwriteCount()
        }
    }

    /// #12:套用预设菜单(内置目录,见 ExtractionPreset.builtInPresets 的场景注释)。
    /// 只动开关组合;目的地 / 密码 / 解密方式保留用户当前所填。
    @ViewBuilder
    private var presetMenuRow: some View {
        HStack {
            Menu {
                ForEach(ExtractionPreset.builtInPresets()) { preset in
                    Button(L10n.text(preset.nameKey)) { apply(preset) }
                }
            } label: {
                Label(L10n.text("extract.preset.menu"), systemImage: "wand.and.stars")
            }
            .fixedSize()
            Spacer()
        }
    }

    private func apply(_ preset: ExtractionPreset) {
        request.skipJunk = preset.skipJunk
        request.skipSymlinks = preset.skipSymlinks
        // 去单层壳只有预检发现壳时才有意义(管线对无壳包安静放弃,勾上也无害,但 UI 不显示开关会困惑)。
        request.stripSingleRootFolder = preset.stripSingleRootFolder && request.detectedSingleRootFolder != nil
        request.extractIntoSubfolder = preset.extractIntoSubfolder
        request.autoRenameConflicts = preset.autoRenameConflicts
        request.revealWhenDone = preset.revealWhenDone
        request.trashOriginalWhenDone = preset.trashOriginalWhenDone
    }

    /// #12:解到同名文件夹 —— 副标题实时写出最终落点(同 #13 的硬要求:UI 必须写清最终路径)。
    @ViewBuilder
    private var intoSubfolderToggle: some View {
        let stem = request.archiveURL.deletingPathExtension().lastPathComponent
        DialogToggleRow(
            title: L10n.text("extract.intoSubfolder"),
            subtitle: request.extractIntoSubfolder
                ? L10n.format("extract.intoSubfolder.on", "\(request.destinationURL.lastPathComponent)/\(stem)/")
                : L10n.format("extract.intoSubfolder.off", "\(request.destinationURL.lastPathComponent)/"),
            systemImage: "folder.badge.plus",
            tint: .blue,
            pinsToTrailing: true,
            isOn: $request.extractIntoSubfolder
        )
    }

    @ViewBuilder
    private var autoRenameToggle: some View {
        DialogToggleRow(
            title: L10n.text("extract.autoRename"),
            subtitle: L10n.text("extract.autoRename.detail"),
            systemImage: "pencil.and.list.clipboard",
            tint: .purple,
            pinsToTrailing: true,
            isOn: $request.autoRenameConflicts
        )
    }

    @ViewBuilder
    private var revealWhenDoneToggle: some View {
        DialogToggleRow(
            title: L10n.text("extract.revealWhenDone"),
            subtitle: L10n.text("extract.revealWhenDone.detail"),
            systemImage: "arrow.up.forward.app",
            tint: .cyan,
            pinsToTrailing: true,
            isOn: $request.revealWhenDone
        )
    }

    @ViewBuilder
    private var trashOriginalToggle: some View {
        DialogToggleRow(
            title: L10n.text("extract.trashOriginal"),
            subtitle: L10n.text("extract.trashOriginal.detail"),
            systemImage: "trash",
            tint: .red,
            pinsToTrailing: true,
            isOn: $request.trashOriginalWhenDone
        )
    }

    @ViewBuilder
    private var skipJunkToggle: some View {
        DialogToggleRow(
            title: L10n.text("extract.skipJunk"),
            subtitle: L10n.text("extract.skipJunk.detail"),
            systemImage: "doc.badge.gearshape.fill",
            tint: .teal,
            pinsToTrailing: true,
            isOn: $request.skipJunk
        )
    }

    /// #13:去单层目录开关。副标题随勾选实时切换,明确写出最终落点(用户硬要求:UI 必须写清最终路径)。
    @ViewBuilder
    private var stripSingleRootToggle: some View {
        let root = request.detectedSingleRootFolder ?? ""
        let destination = request.destinationURL.lastPathComponent
        DialogToggleRow(
            title: L10n.format("extract.stripSingleRoot", root),
            subtitle: request.stripSingleRootFolder
                ? L10n.format("extract.stripSingleRoot.on", destination, root)
                : L10n.format("extract.stripSingleRoot.off", destination, root),
            systemImage: "square.3.layers.3d.down.left",
            tint: .indigo,
            pinsToTrailing: true,
            isOn: $request.stripSingleRootFolder
        )
    }

    @ViewBuilder
    private var skipSymlinksToggle: some View {
        DialogToggleRow(
            title: L10n.text("extract.skipSymlinks"),
            subtitle: L10n.text("extract.skipSymlinks.detail"),
            systemImage: "link",
            tint: .orange,
            pinsToTrailing: true,
            isOn: $request.skipSymlinks
        )
    }

    // MARK: - 解压前预检（0.4.2 #8）

    @ViewBuilder
    private var preflightRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preflight {
                // 预检概要是不可选择的信息行 —— 低调化(callout + secondary),跟创建对话框预检条同档。
                Label(
                    L10n.format(
                        "extract.preflight.summary",
                        "\(preflight.fileCount)",
                        "\(preflight.folderCount)",
                        ByteCountFormatter.string(fromByteCount: preflight.totalBytes, countStyle: .file)
                    ),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if preflight.encryptedEntryCount > 0 {
                    preflightCaption("extract.preflight.encrypted", "\(preflight.encryptedEntryCount)", icon: "key.fill", tint: .secondary)
                }
                if let lowSpaceWarning {
                    Label(
                        L10n.format("extract.preflight.lowSpace", lowSpaceWarning.needed, lowSpaceWarning.available),
                        systemImage: "externaldrive.fill.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 2)
                }
                if overwriteCount > 0 {
                    preflightCaption("extract.preflight.overwrite", "\(overwriteCount)", icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                if missingVolumeCount > 0 {
                    preflightCaption("extract.preflight.missingVolumes", "\(missingVolumeCount)", icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                if preflight.suspiciousEntryCount > 0 {
                    preflightCaption("extract.preflight.suspicious", "\(preflight.suspiciousEntryCount)", icon: "exclamationmark.shield.fill", tint: .orange)
                }
                if preflight.symlinkCount > 0 {
                    preflightCaption("extract.preflight.symlinks", "\(preflight.symlinkCount)", icon: "link", tint: .secondary)
                }
            } else if preflightUnavailable {
                Label(L10n.text("extract.preflight.unavailable"), systemImage: "list.bullet.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("extract.preflight.loading"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func preflightCaption(_ key: String, _ value: String, icon: String, tint: Color) -> some View {
        Label(L10n.format(key, value), systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.leading, 2)
    }

    private func loadPreflight() {
        let url = request.archiveURL
        let password = request.password
        Task { @MainActor in
            do {
                let items = try await ArchiveService.list(url, password: password)
                preflight = ArchiveExtractPreflight.analyze(items)
                preflightTopLevelNames = ArchiveExtractPreflight.topLevelNames(of: items)
                // #13:检测「单层包装壳」,有则显示去壳开关(默认关)。
                request.detectedSingleRootFolder = ArchiveSingleRootFolder.detect(in: items)
                recomputeOverwriteCount()
            } catch {
                // 读不到（header 加密没密码 / 损坏）→ 收起概要即可，对话框本职（选目录、给密码）不受影响。
                preflightUnavailable = true
            }
        }
    }

    private func recomputeOverwriteCount() {
        let destination = request.destinationURL
        overwriteCount = preflightTopLevelNames.filter {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
        }.count
        recomputeLowSpaceWarning()
    }

    /// 0.4.3 #4:目标卷剩余 < 预计解出大小 → 橙色警示「至少需要约 X,当前剩余 Y」。
    private func recomputeLowSpaceWarning() {
        guard let preflight, preflight.totalBytes > 0,
              let available = DiskSpacePreflight.availableCapacity(at: request.destinationURL),
              available < preflight.totalBytes else {
            lowSpaceWarning = nil
            return
        }
        lowSpaceWarning = (
            needed: ByteCountFormatter.string(fromByteCount: preflight.totalBytes, countStyle: .file),
            available: ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        )
    }

    private func computeMissingVolumes() {
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: request.archiveURL.deletingLastPathComponent().path),
              let set = FileSplitCombine.volumeSet(forMemberNamed: request.archiveURL.lastPathComponent, among: siblings) else { return }
        missingVolumeCount = set.missingIndices.count
    }

    /// 是否在解压 `.siz` 单文件签名容器 —— 决定 GPG 解密密钥 picker 是否出现。
    /// **判定靠 `sizSignature` 而不是文件扩展名** —— 解压时 `request.archiveURL` 是 unwrap 后的内层 archive（archive.zip / archive.zip.gpg），
    /// 后缀已经不是 `.siz`；只有 `.siz` 走 unwrapAndVerifySIZ 时才会把 sizSignature 塞进 request。
    /// 历史 bug（0.1.8 落地以来一直存在）：旧版用 archiveURL 扩展名判，导致 .siz 解压时 picker 一直没显示。
    private var isSizExtract: Bool {
        request.sizSignature != nil
    }

    /// 解密密钥 picker —— Menu 风格，跟创建对话框签名密钥 picker 视觉对齐。
    /// 首项「让 GPG 自动选」对应空 fingerprint = gpg 按 keyring 自己选合适的私钥（GPG 加密元数据里都会标 recipient key id）。
    @ViewBuilder
    private var gpgDecryptionKeyRow: some View {
        // 跟同 Form 里其它行（保存到 / 密码 / 解密方式）保持 body 字号，不专门 .font(.caption)，避免视觉错落。
        HStack(alignment: .center, spacing: 6) {
            DialogRowLabel(L10n.text("extract.gpgDecryptionKey.label"), systemImage: "person.badge.key.fill", tint: .green, width: 180)
            Spacer()
            GPGSecretKeyMenu(
                selection: $request.gpgDecryptionKeyFingerprint,
                secretKeys: availableSecretKeys,
                autoLabelKey: "extract.gpgDecryptionKey.auto",
                missingFingerprintKey: "extract.gpgDecryptionKey.missingFingerprint"
            )
        }
    }

    /// `.siz` v3 对称加密的密码输入。和「内层 ZIP/7z 解压密码」独立 —— 用户的两份密码通常不一样。
    /// 长说明放下方 caption Text，避免 SecureField placeholder 横向被截断。
    @ViewBuilder
    private var gpgDecryptionPassphraseRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                DialogRowLabel(L10n.text("extract.gpgDecryptionPassphrase.label"), systemImage: "lock.rectangle.fill", tint: .orange, width: 180)
                SecureField(L10n.text("extract.gpgDecryptionPassphrase.placeholder"), text: $request.gpgDecryptionPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .dialogFieldEmphasis()
                    .frame(maxWidth: 260)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(L10n.text("extract.gpgDecryptionPassphrase.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 186)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// `.siz` 解压对话框里多出来的三行：签名状态、签名时间、签名指纹。
/// 走标准 Form 的行布局，不另开卡片块，保持跟 destination / password / decryptionMethod 等行一致。
/// 用户要求签名时间 + 公钥指纹必须可见，不藏 tooltip。
private struct SIZSignatureRows: View {
    let signature: SIZSignatureSummary

    var body: some View {
        // Form 内部会按行折行，每个 HStack = 一行。标签 = 彩色瓦片,180pt 对齐其余行(保存到/密码)。
        // 值列竖排(状态一行+签名者一行,长状态标题不再炸版)且**靠右对齐** ——
        // 解压对话框拍板:所有值列靠最右(与 保存到/密码 同列)。
        HStack(alignment: .top, spacing: 6) {
            DialogRowLabel(L10n.text("siz.signatureSheet.signer"), systemImage: "person.fill", tint: .green, width: 180)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: SIZSignatureStatus.iconName(for: signature.verify))
                    Text(SIZSignatureStatus.title(for: signature.verify))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SIZSignatureStatus.color(for: signature.verify))
                Text(signature.signerDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        HStack(alignment: .center, spacing: 6) {
            DialogRowLabel(L10n.text("siz.signatureSheet.signedAt"), systemImage: "clock.fill", tint: .purple, width: 180)
            Spacer(minLength: 12)
            Text(signature.signedAt)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        HStack(alignment: .center, spacing: 6) {
            DialogRowLabel(L10n.text("siz.signatureSheet.keyFingerprint"), systemImage: "touchid", tint: .indigo, width: 180)
            Spacer(minLength: 12)
            Text(signature.signerFingerprint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// 跨 view 共用的「GPGVerifyResult → 图标 / 颜色 / 标题」mapping —— sheet 跟 banner 都从这里取。
/// 避免在两个地方各写一份 switch（之前的弯路）。
enum SIZSignatureStatus {
    static func iconName(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            // 有 concerns（密钥过期 / 撤销 / 签名过期）= 密码学有效但「不能放心」→ 跟 untrusted 同视觉档。
            if !concerns.isEmpty { return "checkmark.seal" }
            return trusted ? "checkmark.seal.fill" : "checkmark.seal"
        case .unknownSigner: return "questionmark.circle.fill"
        case .badSignature: return "exclamationmark.triangle.fill"
        case .verificationError: return "xmark.octagon.fill"
        }
    }

    static func color(for verify: GPGBackend.GPGVerifyResult) -> Color {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            // 只有「受信任 + 无 concerns」才给绿；未受信任（ownertrust undefined/never）虽然 GOODSIG
            // 但密码学有效 ≠ 可信，必须降级为 orange，跟 iconName/title 的区分保持一致（避免「永不信任的 key 标绿」）。
            return (trusted && concerns.isEmpty) ? .green : .orange
        case .unknownSigner, .verificationError: return .orange
        case .badSignature: return .red
        }
    }

    static func title(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            if concerns.contains(.keyRevoked) { return L10n.text("siz.verify.valid.keyRevoked.title") }
            if concerns.contains(.keyExpired) { return L10n.text("siz.verify.valid.keyExpired.title") }
            if concerns.contains(.signatureExpired) { return L10n.text("siz.verify.valid.sigExpired.title") }
            return trusted
                ? L10n.text("siz.verify.valid.trusted.title")
                : L10n.text("siz.verify.valid.untrusted.title")
        case .unknownSigner: return L10n.text("siz.verify.unknownSigner.title")
        case .badSignature: return L10n.text("siz.verify.bad.title")
        case .verificationError: return L10n.text("siz.verify.error.title")
        }
    }

    /// sheet 用的副标题文案 —— 短句解释当前状态。
    static func summary(for verify: GPGBackend.GPGVerifyResult) -> String {
        switch verify {
        case .validSignature(_, _, let trusted, let concerns):
            if concerns.contains(.keyRevoked) { return L10n.text("siz.signatureSheet.valid.keyRevoked.summary") }
            if concerns.contains(.keyExpired) { return L10n.text("siz.signatureSheet.valid.keyExpired.summary") }
            if concerns.contains(.signatureExpired) { return L10n.text("siz.signatureSheet.valid.sigExpired.summary") }
            // 未受信任：签名密码学有效但 ownertrust 不足，副标题要明确告诉用户「公钥在但没标信任」，
            // 不能再显示「一切正常」的 valid.summary（跟降级为 orange 的颜色 / untrusted 标题保持一致）。
            if !trusted { return L10n.text("siz.signatureSheet.untrusted.note") }
            return L10n.text("siz.signatureSheet.valid.summary")
        case .unknownSigner: return L10n.text("siz.signatureSheet.unknownSigner.summary")
        case .badSignature: return L10n.text("siz.signatureSheet.bad.summary")
        case .verificationError(let message): return message
        }
    }
}
