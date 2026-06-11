//
//  SZSVerificationSheet.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/05/30.
//

import AppKit
import SwiftUI

/// `.szs` 签名清单的验证报告 sheet。
///
/// 渲染三段：签名块 + manifest 元信息 + payload 根目录 + 文件列表（含骨架屏加载态）。
/// payloadRoot 默认 = `.szs` 文件所在目录，用户可以重新选；选完自动重新跑 verify。
struct SZSVerificationSheet: View {
    let sourceURL: URL
    let signature: GPGBackend.GPGVerifyResult
    let manifest: SZSArchive.Manifest
    let initialPayloadRoot: URL
    let onClose: () -> Void
    /// 「以虚拟目录浏览」回调 —— 携带验证报告而不是原 manifest。原因：原 manifest 含**所有**文件条目（含
    /// `.mismatch` / `.missing` / `.unreadable`），把它们直接放进虚拟目录 = 用户看到「这是被签名的内容」但实际没通过 SHA 校验，
    /// 等于把未验证文件冒充已验证。模型层用 report 的 `.match` 条目集合构建 allowedFiles，只展示真正过的文件。
    let onOpenAsVirtualFolder: (URL, SZSArchive.VerifyReport) -> Void

    @State private var payloadRoot: URL
    @State private var report: SZSArchive.VerifyReport?
    @State private var isVerifying = false
    @State private var verifyError: String?
    @State private var expandedMismatches: Set<String> = []
    /// 0.4.1：文件清单从平铺改目录树。记**收起**的目录集合（默认全展开 = 报告一眼可见），
    /// 跟比较归档折叠树同一套思路：每层固定缩进、目录行 chevron 开合。
    @State private var collapsedFolders: Set<String> = []
    /// 每次 `verifyNow` 自增；Task 写回前 guard 当前 generation 一致，避免「用户切 payloadRoot 触发第二次 verify，
    /// 第一次因体积大慢到了才回写，覆盖第二次结果」的 race。
    @State private var verifyGeneration: Int = 0
    /// #110「收件人说明」折叠展开状态 —— 默认收起。
    @State private var showInstructions = false
    /// 实测的说明正文高度（GeometryReader 量）—— 用于「自适应高度,到上限才滚动」。
    @State private var instructionsContentHeight: CGFloat = 0
    /// 说明正文最大显示高度；超过就在面板内滚动，避免超长留言把 sheet 撑出屏幕。
    private let maxInstructionsHeight: CGFloat = 280

    private let labelColumnWidth: CGFloat = 96

    init(
        sourceURL: URL,
        signature: GPGBackend.GPGVerifyResult,
        manifest: SZSArchive.Manifest,
        initialPayloadRoot: URL,
        onClose: @escaping () -> Void,
        onOpenAsVirtualFolder: @escaping (URL, SZSArchive.VerifyReport) -> Void
    ) {
        self.sourceURL = sourceURL
        self.signature = signature
        self.manifest = manifest
        self.initialPayloadRoot = initialPayloadRoot
        self.onClose = onClose
        self.onOpenAsVirtualFolder = onOpenAsVirtualFolder
        self._payloadRoot = State(initialValue: initialPayloadRoot)
    }

    var body: some View {
        // 0.4.1 重构：验签状态作 hero（大彩色印章），各信息块进 DialogSection 卡片,操作钉底 bar。
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: SIZSignatureStatus.iconName(for: signature))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        SIZSignatureStatus.color(for: signature).gradient,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(SIZSignatureStatus.title(for: signature))
                        .font(.title3.weight(.semibold))
                    Text(SIZSignatureStatus.summary(for: signature))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DialogSection { signerDetailBlock }
                    DialogSection(L10n.text("szs.verify.manifestSection")) { manifestBlock }
                    DialogSection(L10n.text("szs.verify.payloadRoot")) {
                        payloadRootBlock
                        filesBlock
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 560)

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("szs.verify.dismissButton"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("szs.verify.openAsVirtualFolderButton")) {
                    if let report {
                        onOpenAsVirtualFolder(payloadRoot, report)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying || report == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 700)
        .onAppear { verifyNow() }
    }

    /// 签名者细节（fingerprint / 签名者名）—— 从原 signatureBlock 拆出状态印章后剩下的部分。
    @ViewBuilder
    private var signerDetailBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let signerLine = extractSignerLine() {
                Text(signerLine)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }
            if let fp = extractFingerprint() {
                Text(fp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            infoRow(L10n.text("siz.signatureSheet.source"), sourceURL.path, monospaced: true)
        }
    }


    private func extractSignerLine() -> String? {
        if case .validSignature(let signer, _, _, _) = signature, let s = signer, !s.isEmpty { return s }
        if case .badSignature(let signer, _) = signature, let s = signer, !s.isEmpty { return s }
        return nil
    }

    private func extractFingerprint() -> String? {
        if case .validSignature(_, let fp, _, _) = signature, let fp { return fp }
        if case .badSignature(_, let fp) = signature, let fp { return fp }
        return nil
    }

    // MARK: - Manifest 元信息

    @ViewBuilder
    private var manifestBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 源文件路径已移到 signerDetailBlock，这里不重复。
            if let title = manifest.title, !title.isEmpty {
                infoRow(L10n.text("szs.verify.manifestTitle"), title)
            }
            if let desc = manifest.description, !desc.isEmpty {
                infoRow(L10n.text("szs.verify.manifestDescription"), desc)
            }
            infoRow(L10n.text("szs.verify.manifestCreatedAt"), manifest.createdAt)
            infoRow(L10n.text("szs.verify.manifestCreatedBy"), manifest.createdBy)
            infoRow(L10n.text("siz.signatureSheet.formatVersion"), ".\(SZSArchive.extensionName) v\(manifest.version)")
            infoRow(L10n.text("szs.verify.manifestFileCount"), "\(manifest.files.count)")
            // #110 收件人说明：作为 manifest 信息块里的一行（标题对齐标签列、展开正文对齐值列），跟其它行一致。
            if let instructions = manifest.instructions, !instructions.isEmpty {
                instructionsRow(instructions)
            }
        }
    }

    // MARK: - #110 收件人说明

    /// #110「收件人说明」—— manifest 信息块里的一行：标题右对齐到标签列（跟「源文件/说明/文件数」齐），
    /// 点标题区折叠展开；展开正文缩进到**值列**（`labelColumnWidth + 8`，跟上面各行的值左对齐），不贴左、有舒适内边距。
    @ViewBuilder
    private func instructionsRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showInstructions.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("siz.instructions.disclosure"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: labelColumnWidth, alignment: .trailing)
                    Image(systemName: showInstructions ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showInstructions {
                VStack(alignment: .leading, spacing: 8) {
                    // 自适应高度：到上限后面板内滚动，避免超长留言撑出屏幕（见 .siz 同款实现）。
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: InstructionsHeightKey.self, value: proxy.size.height)
                            })
                    }
                    .frame(height: min(instructionsContentHeight, maxInstructionsHeight))
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onPreferenceChange(InstructionsHeightKey.self) { instructionsContentHeight = $0 }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label(L10n.text("siz.instructions.copy"), systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                // 正文缩进到值列（标签宽 + HStack spacing 8），跟上面各行的值左对齐。
                .padding(.leading, labelColumnWidth + 8)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: - payload 根目录

    private var payloadRootBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.text("szs.verify.payloadRoot"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .trailing)
            Text(payloadRoot.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button(L10n.text("szs.verify.pickPayloadRoot")) {
                choosePayloadRoot()
            }
            .controlSize(.small)
            .disabled(isVerifying)
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
            verifyNow()
        }
    }

    // MARK: - 文件块（含骨架屏）

    @ViewBuilder
    private var filesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("szs.verify.filesSection"))
                    .font(.headline)
                Spacer()
                summaryBadge
            }

            if let error = verifyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
            } else if isVerifying {
                // 骨架屏：默认渲染 5 行占位（按 manifest.files.count 上限取 min 避免少文件清单也撑出 5 行）。
                skeletonFileList(count: min(manifest.files.count, 5))
            } else if let report {
                // 目录树（0.4.1）：按 relativePath 分层，目录行可折叠（抽屉），每层固定缩进 16pt。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        treeRows(buildTree(from: report.entries), depth: 0)
                    }
                }
                .frame(maxHeight: 280)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 目录树（0.4.1：平铺 → 抽屉式文件夹）

    /// 树节点：目录（children 非空、entry 为 nil）或文件叶子。`path` 作折叠状态的稳定 key。
    private struct SZSPathNode: Identifiable {
        let name: String
        let path: String
        var children: [SZSPathNode] = []
        var entry: SZSArchive.VerifyReport.Entry?
        var id: String { path }

        /// 目录聚合：自己 / 后代里有没有未通过项（mismatch/missing/unreadable）。
        var hasProblem: Bool {
            if let entry {
                if case .match = entry { return false }
                return true
            }
            return children.contains(where: \.hasProblem)
        }

        /// 后代文件总数（目录行右侧的计数）。
        var fileCount: Int {
            if entry != nil { return 1 }
            return children.reduce(0) { $0 + $1.fileCount }
        }
    }

    /// 把平铺的报告条目按路径折成树：目录在前、文件在后，各自字母序。
    private func buildTree(from entries: [SZSArchive.VerifyReport.Entry]) -> [SZSPathNode] {
        var root = SZSPathNode(name: "", path: "")
        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            insert(entry: entry, components: components, into: &root, parentPath: "")
        }
        sortNodes(&root.children)
        return root.children
    }

    private func insert(entry: SZSArchive.VerifyReport.Entry, components: [String], into node: inout SZSPathNode, parentPath: String) {
        guard let first = components.first else { return }
        let childPath = parentPath.isEmpty ? first : parentPath + "/" + first
        if components.count == 1 {
            var leaf = SZSPathNode(name: first, path: childPath)
            leaf.entry = entry
            node.children.append(leaf)
            return
        }
        if let index = node.children.firstIndex(where: { $0.path == childPath && $0.entry == nil }) {
            insert(entry: entry, components: Array(components.dropFirst()), into: &node.children[index], parentPath: childPath)
        } else {
            var folder = SZSPathNode(name: first, path: childPath)
            insert(entry: entry, components: Array(components.dropFirst()), into: &folder, parentPath: childPath)
            node.children.append(folder)
        }
    }

    private func sortNodes(_ nodes: inout [SZSPathNode]) {
        nodes.sort { lhs, rhs in
            let lhsIsDir = lhs.entry == nil
            let rhsIsDir = rhs.entry == nil
            if lhsIsDir != rhsIsDir { return lhsIsDir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for index in nodes.indices where nodes[index].entry == nil {
            sortNodes(&nodes[index].children)
        }
    }

    /// 递归渲染：目录行（chevron + 文件夹图标 + 名 + 计数 + 状态点）+ 展开时的子级。
    /// 递归进 ViewBuilder 必须 AnyView 断环（与比较归档折叠树同款手法）。
    private func treeRows(_ nodes: [SZSPathNode], depth: Int) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                if let entry = node.entry {
                    entryRow(entry, displayName: node.name, depth: depth)
                    Divider()
                } else {
                    folderRow(node, depth: depth)
                    Divider()
                    if !collapsedFolders.contains(node.path) {
                        treeRows(node.children, depth: depth + 1)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func folderRow(_ node: SZSPathNode, depth: Int) -> some View {
        Button {
            if collapsedFolders.contains(node.path) {
                collapsedFolders.remove(node.path)
            } else {
                collapsedFolders.insert(node.path)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: collapsedFolders.contains(node.path) ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(node.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(node.fileCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                // 聚合状态点：目录下有任何未通过项 → 橙；全部通过 → 绿。收起也能一眼看到问题在哪个抽屉里。
                Circle()
                    .fill(node.hasProblem ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var summaryBadge: some View {
        if isVerifying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.text("szs.verify.verifying"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let report {
            let s = report.summary
            HStack(spacing: 6) {
                Circle()
                    .fill(s.allFilesOk ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(L10n.format("szs.verify.summary", s.matched, s.total, s.mismatched, s.missing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 骨架屏：N 行占位，每行图标 + 路径 placeholder。视觉提示「文件列表正在加载」，
    /// 比之前一行小 spinner + raw L10n key 强很多。
    @ViewBuilder
    private func skeletonFileList(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(count, 1), id: \.self) { idx in
                HStack(alignment: .center, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 60, height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(maxWidth: skeletonWidth(for: idx), maxHeight: 10)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 让骨架屏 placeholder 宽度参差不齐（伪「不同长度的文件名」），视觉真实感更强。
    private func skeletonWidth(for index: Int) -> CGFloat {
        switch index % 4 {
        case 0: return 220
        case 1: return 320
        case 2: return 180
        default: return 260
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SZSArchive.VerifyReport.Entry, displayName: String, depth: Int) -> some View {
        // 从 manifest 反查这一行对应的 FileEntry —— 拿 size / sha256 / mediaType 给行尾展示。
        let manifestEntry = manifest.files.first(where: { $0.relativePath == entry.relativePath })
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                entryBadge(entry)
                // 树模式只显示文件名（层级由缩进表达）；完整相对路径进 tooltip。
                Text(displayName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(entry.relativePath)
                Spacer()
                if let bytes = manifestEntry?.size {
                    Text(formattedBytes(bytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                if let sha = manifestEntry?.sha256 {
                    Text(sha.prefix(8))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(sha) // tooltip 显示完整 SHA
                }
                if case .mismatch = entry {
                    Button {
                        toggleExpand(entry.relativePath)
                    } label: {
                        Image(systemName: expandedMismatches.contains(entry.relativePath) ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            if case .mismatch(_, let expected, let actual) = entry,
               expandedMismatches.contains(entry.relativePath) {
                VStack(alignment: .leading, spacing: 2) {
                    mismatchHashRow(label: L10n.text("szs.verify.entry.expectedSHA"), sha: expected, color: .green)
                    mismatchHashRow(label: L10n.text("szs.verify.entry.actualSHA"), sha: actual, color: .red)
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(depth) * 16)
    }

    /// 展开后的 expected / actual SHA 行：标签放固定宽列、SHA 另起一个 Text —— 这样两行 SHA 起始位置严格对齐。
    /// 旧实现把标签和 SHA 拼进同一个 Text 用手动空格凑对齐，但「期望 / 实际」两个本地化标签宽度不同，
    /// SHA 永远对不齐（中文尤其明显）。
    private func mismatchHashRow(label: String, sha: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(sha)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    /// 把字节数格式化成人类可读单位（KB / MB / GB）。复用 Foundation `ByteCountFormatter` 保持本地化一致。
    private func formattedBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func toggleExpand(_ path: String) {
        if expandedMismatches.contains(path) {
            expandedMismatches.remove(path)
        } else {
            expandedMismatches.insert(path)
        }
    }

    @ViewBuilder
    private func entryBadge(_ entry: SZSArchive.VerifyReport.Entry) -> some View {
        switch entry {
        case .match:
            Text(L10n.text("szs.verify.entry.match"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
                .frame(width: 80, alignment: .leading)
        case .mismatch:
            Text(L10n.text("szs.verify.entry.mismatch"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .frame(width: 80, alignment: .leading)
        case .missing:
            Text(L10n.text("szs.verify.entry.missing"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .frame(width: 80, alignment: .leading)
        case .unreadable(_, let reason):
            Text(L10n.format("szs.verify.entry.unreadable", reason))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80, alignment: .leading)
        }
    }

    // MARK: - 校验触发

    private func verifyNow() {
        verifyGeneration += 1
        let myGen = verifyGeneration
        isVerifying = true
        verifyError = nil
        Task {
            do {
                let result = try await SignedContainerService.verifySZS(
                    manifestURL: sourceURL,
                    payloadRoot: payloadRoot
                )
                await MainActor.run {
                    // race 防护：用户切了 payloadRoot 又触发一次 verifyNow，
                    // 旧 Task 慢到了不能覆盖新的 result / 状态。
                    guard myGen == verifyGeneration else { return }
                    self.report = result
                    self.isVerifying = false
                }
            } catch {
                await MainActor.run {
                    guard myGen == verifyGeneration else { return }
                    self.verifyError = error.localizedDescription
                    self.isVerifying = false
                }
            }
        }
    }
}

/// 量「收件人说明」正文真实高度的 PreferenceKey —— 给「自适应高度,到上限才滚动」用。
private struct InstructionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
