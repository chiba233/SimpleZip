//
//  ReleaseAssistantSheet.swift
//  SimpleZip
//
//  发布助手:选产物目录 → 打包(可排垃圾、可复现) → 发布检查 → SHA256SUMS → 可选签名清单,
//  一条流。每一步都是现成能力(创建选项 / ReleaseInspection / ChecksumFile / CreateSZSSheet),
//  这里只是把它们按发布工作流串起来 —— 不造平行引擎。执行管线在
//  ArchiveBrowserModel.runReleaseAssistant(_:),走 startManagedArchiveTask(活动中心可见、可取消)。
//

import AppKit
import SwiftUI

/// 发布助手的待确认配置。`sourceFolder` 是要打包的产物目录;归档落在 `destinationFolder` 下
/// (默认产物目录的父目录),重名自动唯一化,绝不覆盖。
struct ReleaseAssistantRequest: Identifiable {
    let id = UUID()
    var sourceFolder: URL?
    var fileName: String = ""
    /// #2:版本标签(可选,进发布账本;空则用文件名顶上)。
    var versionLabel: String = ""
    /// 仅 zip / 7z —— 可复现压缩只有这两个格式支持(tar 家族走系统 tar 没有时间戳钳制)。
    var format: ArchiveCreateFormat = .zip
    var destinationFolder: URL?
    var excludeJunk = true
    var reproducible = true
    var runInspection = true
    var writeChecksums = true
    /// #4:在产物旁写机器可读的 release-manifest.json(名字/版本/SHA-256/大小/结构指纹)。
    var writeManifest = false
    /// 完成后用现有「创建签名清单」sheet 继续签 `.szs`(A4:GPG 主开关关闭时该行不渲染)。
    var createSignedManifest = false
    /// #10:发布前质量门(默认全关 = 行为不变)。
    var gateRules = ReleaseGateRules()
}

struct ReleaseAssistantSheet: View {
    @State var request: ReleaseAssistantRequest
    let confirm: (ReleaseAssistantRequest) -> Void
    let cancel: () -> Void
    /// #3:文件级对比回调(两个产物都还在时) —— 调现有归档比较任务流,结果走现有 ArchiveDiffView。
    var onCompareArtifacts: ((URL, URL) -> Void)? = nil

    /// #18:命名工作区预设(整套发布配置一把存取;store 在 Core,随设置备份)。
    @State private var workspacePresets: [ReleaseWorkspacePreset] = ReleaseWorkspacePresetStore().loadAll()
    /// #8:保存 / 重命名预设的 NameInputSheet 展示状态(取代 NSAlert)。
    @State private var showsSavePreset = false
    @State private var renamingPreset: ReleaseWorkspacePreset?
    /// #2:发布账本(sheet 打开时读一次;本次跑完的记录下次打开可见)。
    @State private var ledgerEntries: [ReleaseLedgerEntry] = ReleaseLedgerStore().loadAll()
    /// #3:待展示的账面对比(新条目 vs 它的上一条)。
    @State private var ledgerComparison: LedgerComparisonRequest?

    private var canConfirm: Bool {
        let baseName = request.fileName.trimmingCharacters(in: .whitespaces)
        return request.sourceFolder != nil
            && request.destinationFolder != nil
            && !baseName.isEmpty
            // 安全:文件名是单段基名,含 `/`、`..`、盘符等会把产物带出所选目录 → 禁用确认。
            && !ArchiveSafety.isUnsafeOutputBaseName(baseName)
    }

    private var showsGPGRow: Bool {
        AppPreferences.gpgEnabled && GPGBackend.isAvailable()
    }

    // MARK: - #18 工作区预设

    /// 套用:路径仅在目录仍存在时回填(项目挪走了就留空让用户重挑,不瞎填死路径)。
    private func apply(_ preset: ReleaseWorkspacePreset) {
        func existingDirectory(_ path: String?) -> URL? {
            guard let path else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
        request.sourceFolder = existingDirectory(preset.sourceFolderPath)
        request.destinationFolder = existingDirectory(preset.destinationFolderPath)
        request.fileName = preset.fileName
        request.versionLabel = preset.versionLabel ?? ""
        if let format = ArchiveCreateFormat(rawValue: preset.formatRawValue),
           format == .zip || format == .sevenZip {
            request.format = format
        }
        request.excludeJunk = preset.excludeJunk
        request.reproducible = preset.reproducible
        request.runInspection = preset.runInspection
        request.writeChecksums = preset.writeChecksums
        request.writeManifest = preset.writeManifest ?? false
        request.gateRules = preset.gateRules ?? ReleaseGateRules()
        request.createSignedManifest = preset.createSignedManifest && showsGPGRow
    }

    /// 保存当前配置为命名预设(同名覆盖)。#8:名字输入由 SwiftUI `NameInputSheet` 收(吃 Writing Tools),
    /// 这里只做保存逻辑。
    private func saveWorkspacePreset(named name: String) {
        let preset = ReleaseWorkspacePreset(
            name: name,
            sourceFolderPath: request.sourceFolder?.path,
            fileName: request.fileName,
            versionLabel: request.versionLabel.isEmpty ? nil : request.versionLabel,
            formatRawValue: request.format.rawValue,
            destinationFolderPath: request.destinationFolder?.path,
            excludeJunk: request.excludeJunk,
            reproducible: request.reproducible,
            runInspection: request.runInspection,
            writeChecksums: request.writeChecksums,
            writeManifest: request.writeManifest,
            createSignedManifest: request.createSignedManifest,
            gateRules: request.gateRules.isAllOff ? nil : request.gateRules
        )
        ReleaseWorkspacePresetStore().save(preset)
        workspacePresets = ReleaseWorkspacePresetStore().loadAll()
    }

    /// C:重命名预设。#8:名字由 `NameInputSheet` 收。同名覆盖语义由 store.save 保证 ——
    /// 改完名先删旧条目再存,避免旧名残留。
    private func renameWorkspacePreset(_ preset: ReleaseWorkspacePreset, to newName: String) {
        guard newName != preset.name else { return }
        let store = ReleaseWorkspacePresetStore()
        store.delete(id: preset.id)
        var renamed = preset
        renamed.name = newName
        store.save(renamed)
        workspacePresets = store.loadAll()
    }

    var body: some View {
        TaskDialogShell(
            heroSystemImage: "shippingbox.and.arrow.backward.fill",
            heroColors: [.teal, .green],
            title: L10n.text("releaseAssistant.title"),
            subtitle: L10n.text("releaseAssistant.subtitle"),
            confirmTitle: L10n.text("releaseAssistant.start"),
            confirmSystemImage: "shippingbox.and.arrow.backward",
            confirmDisabled: !canConfirm,
            confirm: { confirm(request) },
            cancel: cancel
        ) {
            // #18:工作区预设 —— 与创建对话框「套用模板」同款形态:套用 / 保存当前 / 删除。
            HStack {
                Menu {
                    ForEach(workspacePresets) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                    if !workspacePresets.isEmpty {
                        Divider()
                        // C:预设可编辑 —— 重命名 / 删除(store 早有 save/delete,这里只补 UI 入口)。
                        Menu(L10n.text("releaseAssistant.workspace.rename")) {
                            ForEach(workspacePresets) { preset in
                                Button(preset.name) { renamingPreset = preset }
                            }
                        }
                        Menu(L10n.text("releaseAssistant.workspace.delete")) {
                            ForEach(workspacePresets) { preset in
                                Button(preset.name) {
                                    ReleaseWorkspacePresetStore().delete(id: preset.id)
                                    workspacePresets = ReleaseWorkspacePresetStore().loadAll()
                                }
                            }
                        }
                    }
                    Divider()
                    Button(L10n.text("releaseAssistant.workspace.save")) { showsSavePreset = true }
                } label: {
                    Label(L10n.text("releaseAssistant.workspace.menu"), systemImage: "square.stack.3d.up")
                }
                .fixedSize()
                Spacer()
            }
            // #8:保存 / 重命名预设用 SwiftUI NameInputSheet(吃 Writing Tools),取代 NSAlert+NSTextField。
            .sheet(isPresented: $showsSavePreset) {
                NameInputSheet(
                    title: L10n.text("releaseAssistant.workspace.savePrompt.title"),
                    message: L10n.text("releaseAssistant.workspace.savePrompt.message"),
                    initialName: request.sourceFolder?.lastPathComponent ?? request.fileName,
                    confirmTitle: L10n.text("button.save")
                ) { saveWorkspacePreset(named: $0) }
            }
            .sheet(item: $renamingPreset) { preset in
                NameInputSheet(
                    title: L10n.text("releaseAssistant.workspace.renamePrompt.title"),
                    message: L10n.format("releaseAssistant.workspace.renamePrompt.message", preset.name),
                    initialName: preset.name,
                    confirmTitle: L10n.text("button.save")
                ) { renameWorkspacePreset(preset, to: $0) }
            }

            DialogSection(L10n.text("releaseAssistant.section.source")) {
                // 值一侧全部顶到右缘:label + Spacer + 值,与解压家族同款。
                // LabeledContent 在普通 VStack 里只按自然宽度排,右缘会参差。
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("releaseAssistant.sourceFolder"), systemImage: "hammer.fill", tint: .orange)
                    Spacer(minLength: 12)
                    folderPicker(
                        selection: $request.sourceFolder,
                        prompt: L10n.text("releaseAssistant.chooseSource")
                    ) { chosen in
                        // 选完产物目录顺手把空着的文件名 / 输出目录补全 —— 已手改过的不动。
                        if request.fileName.trimmingCharacters(in: .whitespaces).isEmpty {
                            request.fileName = chosen.lastPathComponent
                        }
                        if request.destinationFolder == nil {
                            request.destinationFolder = chosen.deletingLastPathComponent()
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("archive.fileName"), systemImage: "shippingbox.fill", tint: .brown)
                    Spacer(minLength: 12)
                    TextField("", text: $request.fileName)
                        .textFieldStyle(.roundedBorder)
                        .dialogFieldEmphasis()
                        .frame(maxWidth: 200)
                    Picker("", selection: $request.format) {
                        ForEach([ArchiveCreateFormat.zip, .sevenZip]) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                HStack(alignment: .center, spacing: 12) {
                    // 与创建对话框「保存到」同键同图标同色(同类同色)。
                    DialogRowLabel(L10n.text("archive.destination"), systemImage: "folder.fill", tint: .blue)
                    Spacer(minLength: 12)
                    folderPicker(
                        selection: $request.destinationFolder,
                        prompt: L10n.text("releaseAssistant.chooseDestination")
                    ) { _ in }
                }

                // #2:版本标签(可选)—— 进发布账本,历史里按版本认领;空则用文件名顶上。
                HStack(alignment: .center, spacing: 12) {
                    DialogRowLabel(L10n.text("releaseAssistant.versionLabel"), systemImage: "tag.fill", tint: .purple)
                    Spacer(minLength: 12)
                    TextField(L10n.text("releaseAssistant.versionLabel.placeholder"), text: $request.versionLabel)
                        .textFieldStyle(.roundedBorder)
                        .dialogFieldEmphasis()
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            DialogSection(L10n.text("releaseAssistant.section.steps")) {
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.excludeJunk"),
                    subtitle: L10n.text("releaseAssistant.excludeJunk.subtitle"),
                    systemImage: "paintbrush.fill", tint: .pink,
                    pinsToTrailing: true,
                    isOn: $request.excludeJunk
                )
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.reproducible"),
                    subtitle: L10n.text("releaseAssistant.reproducible.subtitle"),
                    systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .purple,
                    pinsToTrailing: true,
                    isOn: $request.reproducible
                )
                DialogToggleRow(
                    title: L10n.text("releaseAssistant.inspect"),
                    subtitle: L10n.text("releaseAssistant.inspect.subtitle"),
                    systemImage: "checklist", tint: .teal,
                    pinsToTrailing: true,
                    isOn: $request.runInspection
                )
            }

            // #18 一级密度治理:伴生产物(SHA256SUMS / .szs 签名)收进普通抽屉,子行单色;
            // 打包行为三开关(排垃圾/可复现/发布检查)是本对话框的灵魂,留一级。
            DialogDrawer(L10n.text("releaseAssistant.section.outputs"), systemImage: "square.and.arrow.down", color: .orange) {
                drawerToggle("releaseAssistant.checksums", subtitleKey: "releaseAssistant.checksums.subtitle", systemImage: "number.square", isOn: $request.writeChecksums)
                drawerToggle("releaseAssistant.manifest", subtitleKey: "releaseAssistant.manifest.subtitle", systemImage: "doc.badge.gearshape", isOn: $request.writeManifest)
                if showsGPGRow {
                    drawerToggle("releaseAssistant.sign", subtitleKey: "releaseAssistant.sign.subtitle", systemImage: "signature", isOn: $request.createSignedManifest)
                }
            }

            // #10:质量门抽屉 —— 六条规则各三态(关/警告/阻断),默认全关;子行单色。
            DialogDrawer(L10n.text("releaseAssistant.section.gate"), systemImage: "checkmark.shield", color: .red, initiallyExpanded: !request.gateRules.isAllOff) {
                gateRow(.suspiciousPaths, systemImage: "exclamationmark.shield")
                gateRow(.junkFiles, systemImage: "paintbrush")
                gateRow(.emptyDirectories, systemImage: "folder.badge.minus")
                gateRow(.missingChecksums, systemImage: "number.square")
                if showsGPGRow {
                    gateRow(.missingSignature, systemImage: "signature")
                }
            }

            // #2:发布历史抽屉 —— 最近几条账本记录(版本 / 日期 / SHA-256 可复制 / 产物在不在),
            // 子行单色。没跑过 = 整个抽屉不渲染,零占位。
            if !ledgerEntries.isEmpty {
                DialogDrawer(L10n.text("releaseAssistant.section.history"), systemImage: "clock.arrow.circlepath", color: .indigo) {
                    ForEach(Array(ledgerEntries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        ledgerRow(entry, previous: ledgerEntries[safe: index + 1])
                    }
                }
            }
        }
        // #3:账面对比小弹窗(嵌套 sheet;文件级对比按钮转交回调走现有比较任务流)。
        .sheet(item: $ledgerComparison) { comparison in
            LedgerComparisonView(
                old: comparison.old,
                new: comparison.new,
                onCompareArtifacts: onCompareArtifacts,
                onClose: { ledgerComparison = nil }
            )
        }
    }

    /// #10:质量门规则行(单色子行):规则名 + 三态下拉。
    private func gateRow(_ rule: ReleaseGate.Rule, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Label(L10n.text("releaseGate.rule.\(rule.rawValue)"), systemImage: systemImage)
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { request.gateRules.mode(for: rule) },
                set: { request.gateRules.setMode($0, for: rule) }
            )) {
                ForEach(ReleaseGateMode.allCases, id: \.self) { mode in
                    Text(L10n.text("releaseGate.mode.\(mode.rawValue)")).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// #2:历史抽屉里的一条账本记录(单色子行)。#3:有上一条时给「与上次对比」。
    private func ledgerRow(_ entry: ReleaseLedgerEntry, previous: ReleaseLedgerEntry?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(entry.versionLabel, systemImage: "shippingbox")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.artifactExists {
                    Text(L10n.text("releaseAssistant.history.artifactMissing"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                if let previous {
                    Button {
                        ledgerComparison = LedgerComparisonRequest(old: previous, new: entry)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("releaseCompare.button"))
                }
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    deleteLedgerEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("file.delete"))
            }
            if let sha256 = entry.sha256 {
                HStack(spacing: 6) {
                    Text(sha256)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sha256, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("button.copyAll"))
                }
            }
        }
    }

    /// 删除一条发布历史记录(账本只是记录,删除不碰任何真实产物文件)。删后刷新列表 + 同步发布包 Spotlight
    /// 索引(ReleaseLedgerStore.delete 注释要求:账本一变就 reindex,让被删条目从 Spotlight 消失)。
    private func deleteLedgerEntry(_ entry: ReleaseLedgerEntry) {
        ReleaseLedgerStore().delete(id: entry.id)
        ledgerEntries = ReleaseLedgerStore().loadAll()
        ReleasePackageSpotlightIndexer.reindex()
    }

    /// #18 抽屉子行:单色 Label + 紧贴开关 + caption 说明(解压/转换对话框同款)。
    private func drawerToggle(_ titleKey: String, subtitleKey: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L10n.text(titleKey), systemImage: systemImage)
                Toggle("", isOn: isOn)
                    .labelsHidden()
            }
            Text(L10n.text(subtitleKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 文件夹选择行:当前选择(可中截断)+「选择…」按钮。
    private func folderPicker(
        selection: Binding<URL?>,
        prompt: String,
        onChoose: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(selection.wrappedValue?.path ?? prompt)
                .font(.callout)
                .foregroundStyle(selection.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if let current = selection.wrappedValue {
                    panel.directoryURL = current
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                selection.wrappedValue = url
                onChoose(url)
            } label: {
                Label(L10n.text("button.choose"), systemImage: "folder")
            }
        }
    }
}


// MARK: - #3 发布产物对比

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 一次「与上次对比」请求(嵌套 sheet 的 item)。
struct LedgerComparisonRequest: Identifiable {
    let id = UUID()
    let old: ReleaseLedgerEntry
    let new: ReleaseLedgerEntry
}

/// #3:账面对比小报告(close-only)。账面字段产物不在也能比;两个产物都在时
/// 给「文件级对比」按钮 —— 转交回调走现有归档比较任务流(A1:不另画 diff 页)。
struct LedgerComparisonView: View {
    let old: ReleaseLedgerEntry
    let new: ReleaseLedgerEntry
    let onCompareArtifacts: ((URL, URL) -> Void)?
    let onClose: () -> Void

    private var comparison: ReleaseLedgerComparison {
        ReleaseLedgerComparison.compare(old: old, new: new)
    }

    private var bothArtifactsExist: Bool {
        old.artifactExists && new.artifactExists
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "arrow.left.arrow.right",
                colors: [.indigo, .blue],
                title: L10n.text("releaseCompare.title"),
                subtitle: "\(old.versionLabel) → \(new.versionLabel)"
            )

            HeightCappedScrollView(maxHeight: 520) {
                VStack(alignment: .leading, spacing: 12) {
                    DialogSection {
                        infoRow(L10n.text("releaseCompare.dates"),
                                value: "\(old.date.formatted(date: .abbreviated, time: .shortened)) → \(new.date.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: "clock.fill", tint: .purple)
                        if let delta = comparison.totalBytesDelta, let oldBytes = old.totalBytes, let newBytes = new.totalBytes {
                            infoRow(L10n.text("releaseCompare.size"),
                                    value: "\(bytes(oldBytes)) → \(bytes(newBytes)) (\(signedBytes(delta)))",
                                    systemImage: "scalemass.fill", tint: .blue)
                        }
                        if let delta = comparison.fileCountDelta, let oldCount = old.fileCount, let newCount = new.fileCount {
                            infoRow(L10n.text("releaseCompare.fileCount"),
                                    value: "\(oldCount) → \(newCount) (\(delta >= 0 ? "+" : "")\(delta))",
                                    systemImage: "number.square.fill", tint: .teal)
                        }
                        if let changed = comparison.fingerprintChanged {
                            infoRow(L10n.text("releaseCompare.fingerprint"),
                                    value: L10n.text(changed ? "releaseCompare.fingerprint.changed" : "releaseCompare.fingerprint.same"),
                                    systemImage: "touchid", tint: changed ? .orange : .green)
                        }
                        if comparison.junkRegression {
                            Label(L10n.format("releaseCompare.junkRegression", "\(new.junkCount ?? 0)"), systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }

                    // 发布卫生清单:上次 vs 这次 逐项 ✓/✗。
                    DialogSection(L10n.text("releaseCompare.section.hygiene")) {
                        checkRow(L10n.text("releaseAssistant.reproducible"), old: old.reproducible, new: new.reproducible)
                        checkRow(L10n.text("releaseAssistant.checksums"), old: old.wroteChecksums, new: new.wroteChecksums)
                        checkRow(L10n.text("releaseAssistant.sign"), old: old.signRequested, new: new.signRequested)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                if let onCompareArtifacts {
                    Button {
                        onCompareArtifacts(URL(fileURLWithPath: old.artifactPath), URL(fileURLWithPath: new.artifactPath))
                        onClose()
                    } label: {
                        Label(L10n.text("releaseCompare.fileLevel"), systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(!bothArtifactsExist)
                    .help(bothArtifactsExist ? "" : L10n.text("releaseCompare.fileLevel.missing"))
                }
                // #65(macOS 26 AI):把账面对比变一段白话总结 + 点出倒退(junk 回潮 / 指纹意外变 / 校验签名丢失)。只描述不放行。
                AIAssistButton(
                    label: L10n.text("ai.compareSummary"),
                    systemImage: "sparkles",
                    sheetTitle: L10n.text("ai.compareSummary.title"),
                    sheetSubtitle: "\(old.versionLabel) → \(new.versionLabel)"
                ) {
                    guard #available(macOS 26.0, *) else { throw AIAssistError(message: L10n.text("ai.unavailable.osTooOld")) }
                    let built = AIReportAssistant.releaseCompareSummaryPrompt(old: old, new: new, comparison: comparison)
                    return try await AIReportAssistant.generate(instructions: built.instructions, prompt: built.prompt)
                }
                Spacer()
                Button(action: onClose) {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520)
    }

    private func infoRow(_ label: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DialogRowLabel(label, systemImage: systemImage, tint: tint)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkRow(_ label: String, old oldValue: Bool, new newValue: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                mark(oldValue)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                mark(newValue)
            }
        }
    }

    private func mark(_ value: Bool) -> some View {
        Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(value ? Color.green : Color.secondary)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func signedBytes(_ delta: Int64) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file)
        if delta == 0 { return "±0" }
        return (delta > 0 ? "+" : "-") + formatted
    }
}
