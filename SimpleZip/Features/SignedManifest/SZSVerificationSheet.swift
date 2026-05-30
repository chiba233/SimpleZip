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
    /// 每次 `verifyNow` 自增；Task 写回前 guard 当前 generation 一致，避免「用户切 payloadRoot 触发第二次 verify，
    /// 第一次因体积大慢到了才回写，覆盖第二次结果」的 race。
    @State private var verifyGeneration: Int = 0

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
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("szs.verify.title"))
                .font(.title3.weight(.semibold))

            signatureBlock
            Divider()
            manifestBlock
            Divider()
            payloadRootBlock
            Divider()
            filesBlock

            HStack {
                Spacer()
                Button(L10n.text("szs.verify.openAsVirtualFolderButton")) {
                    if let report {
                        onOpenAsVirtualFolder(payloadRoot, report)
                    }
                }
                .disabled(isVerifying || report == nil)
                Button(L10n.text("szs.verify.dismissButton"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear { verifyNow() }
    }

    // MARK: - 签名块

    private var signatureBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SIZSignatureStatus.iconName(for: signature))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SIZSignatureStatus.color(for: signature))
            VStack(alignment: .leading, spacing: 3) {
                Text(SIZSignatureStatus.title(for: signature))
                    .font(.headline)
                Text(SIZSignatureStatus.summary(for: signature))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 签名者名 + email 拆出来显示 —— GPG VALIDSIG 的 signer 文案通常是 `Name <email>` 这种 RFC 2822 格式。
                // 是「这签名是谁的」最直接的回答，比 fingerprint 更人话。
                if let signerLine = extractSignerLine() {
                    Text(signerLine)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                if let fp = extractFingerprint() {
                    Text(fp)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
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
            // 复用 `.siz` 的「源文件」标签 —— 同语义不开重复 key。
            infoRow(L10n.text("siz.signatureSheet.source"), sourceURL.path, monospaced: true)
            if let title = manifest.title, !title.isEmpty {
                infoRow(L10n.text("szs.verify.manifestTitle"), title)
            }
            if let desc = manifest.description, !desc.isEmpty {
                infoRow(L10n.text("szs.verify.manifestDescription"), desc)
            }
            infoRow(L10n.text("szs.verify.manifestCreatedAt"), manifest.createdAt)
            infoRow(L10n.text("szs.verify.manifestCreatedBy"), manifest.createdBy)
            infoRow(L10n.text("szs.verify.manifestFileCount"), "\(manifest.files.count)")
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
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
    private func entryRow(_ entry: SZSArchive.VerifyReport.Entry) -> some View {
        // 从 manifest 反查这一行对应的 FileEntry —— 拿 size / sha256 / mediaType 给行尾展示。
        let manifestEntry = manifest.files.first(where: { $0.relativePath == entry.relativePath })
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                entryBadge(entry)
                Text(entry.relativePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
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
                    Text("\(L10n.text("szs.verify.entry.expectedSHA"))  \(expected)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                    Text("\(L10n.text("szs.verify.entry.actualSHA"))    \(actual)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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
                let result = try await SZSArchive.verify(
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
