//
//  ReleaseInspectionView.swift
//  SimpleZip
//
//  Created by HoshinoYumeka on 2026/06/11.
//
//  0.4.2 #15：发布包检查报告。检查在 model（runReleaseInspection：list → 条目侧统计(Core) →
//  完整性测试 → SHA-256），这里只展示：每项检查一行 ✓/⚠/✗，SHA-256 可复制，整份报告可复制纯文本。
//

import AppKit
import SwiftUI

struct ReleaseInspectionView: View {
    let report: ArchiveBrowserModel.ReleaseInspectionReport
    /// 0.4.3 #11:「导出 SHA256SUMS」—— 在归档旁写 GNU 兼容校验文件(非 SimpleZip 用户可验)。nil = 不显示。
    var onExportChecksums: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "checklist",
                colors: [.teal, .green],
                title: L10n.text("inspect.title"),
                subtitle: report.archiveURL.lastPathComponent
            )

            HeightCappedScrollView(maxHeight: 680) {
                VStack(alignment: .leading, spacing: 12) {
                    // 对 .app 目录的纯 bundle 检查没有归档侧步骤,首区(完整性/条目)整段不渲染。
                    if !report.isBundleOnly {
                        DialogSection {
                            testRow
                            if let stats = report.stats {
                                row(ok: true,
                                    text: L10n.format(
                                        "inspect.entries",
                                        "\(stats.fileCount)", "\(stats.folderCount)",
                                        ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)
                                    ),
                                    neutral: true)
                            } else {
                                row(ok: false, text: L10n.text("inspect.notListable"))
                            }
                        }
                    }

                    // #6 专项检查:.app / DMG / XIP 的 bundle 级结论(Info.plist/codesign/Gatekeeper/
                    // DMG 顶层结构/XIP 签名)。
                    if !report.bundleFindings.isEmpty {
                        DialogSection(L10n.text("inspect.section.bundle")) {
                            ForEach(report.bundleFindings) { finding in
                                bundleRow(finding)
                            }
                        }
                    }

                    if let stats = report.stats {
                        DialogSection(L10n.text("inspect.section.hygiene")) {
                            countRow(count: report.securityFindings.reduce(0) { $0 + $1.entryPaths.count }, key: "inspect.suspiciousPaths")
                            countRow(count: stats.junkCount, key: "inspect.junk")
                            countRow(count: stats.emptyDirectoryCount, key: "inspect.emptyDirs")
                            countRow(count: stats.executableCount, key: "inspect.executables", informational: true)
                            countRow(count: stats.symlinkCount, key: "inspect.symlinks", informational: true)
                            row(ok: true, text: L10n.text(report.hasComment ? "inspect.comment.present" : "inspect.comment.none"), neutral: true)
                            // 公钥同捆提醒(发包端闭环):目录里有签名容器(.szs/.siz)才显示这一行。
                            if let hasPublicKey = report.publicKeyBesideSignature {
                                row(ok: hasPublicKey,
                                    text: L10n.text(hasPublicKey ? "inspect.publicKey.present" : "inspect.publicKey.missing"),
                                    neutral: hasPublicKey)
                            }
                        }
                    }

                    if let sha256 = report.sha256 {
                        DialogSection(L10n.text("inspect.section.checksum")) {
                            HStack(spacing: 8) {
                                Text(sha256)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(sha256, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.text("button.copyAll"))
                            }
                        }
                    }

                    // #9 结构指纹:重新打包(时间戳/压缩参数变了)指纹不变 —— 给「这两个包是不是同一份东西」用。
                    if let fingerprint = report.structuralFingerprint {
                        DialogSection(L10n.text("inspect.section.fingerprint")) {
                            HStack(spacing: 8) {
                                Text(fingerprint)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.text("button.copyAll"))
                            }
                            Text(L10n.text("inspect.fingerprint.note"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            PinnedBottomBar {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainTextSummary, forType: .string)
                } label: {
                    Label(L10n.text("button.copyAll"), systemImage: "doc.on.doc")
                }
                // .app 目录的 bundle-only 报告没有归档/哈希步骤,「导出 SHA256SUMS」不适用。
                if let onExportChecksums, !report.isBundleOnly {
                    Button {
                        onExportChecksums()
                    } label: {
                        Label(L10n.text("checksum.export.button"), systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label(L10n.text("button.ok"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 540)
    }

    @ViewBuilder
    private var testRow: some View {
        switch report.testPassed {
        case .some(true):
            row(ok: true, text: L10n.text("inspect.test.passed"))
        case .some(false):
            VStack(alignment: .leading, spacing: 2) {
                row(ok: false, text: L10n.text("inspect.test.failed"))
                if let message = report.testFailureMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 22)
                }
            }
        case .none:
            row(ok: false, text: L10n.text("inspect.test.skipped"), neutral: true)
        }
    }

    /// 计数行：0 = 绿 ✓「无 …」；>0 = 橙 ⚠（informational = 灰 i，如可执行 / symlink 本身不算问题）。
    @ViewBuilder
    private func countRow(count: Int, key: String, informational: Bool = false) -> some View {
        if count == 0 {
            row(ok: true, text: L10n.format("\(key).none", ""))
        } else {
            Label(L10n.format("\(key).some", "\(count)"), systemImage: informational ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(informational ? Color.secondary : Color.orange)
        }
    }

    /// #6 专项检查行:✓/i/⚠/✗ + 标题(L10n key 渲染)+ 工具原始输出 detail(次要小字)。
    @ViewBuilder
    private func bundleRow(_ finding: BundleReleaseCheck.Finding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(Self.bundleFindingTitle(finding))
            } icon: {
                switch finding.severity {
                case .pass:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .info:
                    Image(systemName: "info.circle").foregroundStyle(Color.secondary)
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
            .font(.callout)
            if let detail = finding.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }

    static func bundleFindingTitle(_ finding: BundleReleaseCheck.Finding) -> String {
        if let argument = finding.titleArgument {
            return L10n.format(finding.titleKey, argument)
        }
        return L10n.text(finding.titleKey)
    }

    @ViewBuilder
    private func row(ok: Bool, text: String, neutral: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: neutral ? "info.circle" : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(neutral ? Color.secondary : (ok ? Color.green : Color.red))
        }
        .font(.callout)
    }

    /// 纯文本报告（复制给 release note / issue）。
    private var plainTextSummary: String {
        var lines = ["\(L10n.text("inspect.title")): \(report.archiveURL.lastPathComponent)"]
        if !report.bundleFindings.isEmpty {
            lines.append(L10n.text("inspect.section.bundle") + ":")
            for finding in report.bundleFindings {
                let mark: String
                switch finding.severity {
                case .pass: mark = "✓"
                case .info: mark = "i"
                case .warning: mark = "⚠"
                case .failure: mark = "✗"
                }
                var line = "\(mark) \(Self.bundleFindingTitle(finding))"
                if let detail = finding.detail, !detail.isEmpty {
                    line += " — \(detail)"
                }
                lines.append(line)
            }
        }
        if report.isBundleOnly {
            return lines.joined(separator: "\n")
        }
        switch report.testPassed {
        case .some(true): lines.append("✓ \(L10n.text("inspect.test.passed"))")
        case .some(false): lines.append("✗ \(L10n.text("inspect.test.failed")) — \(report.testFailureMessage ?? "")")
        case .none: lines.append("- \(L10n.text("inspect.test.skipped"))")
        }
        if let stats = report.stats {
            lines.append(L10n.format("inspect.entries", "\(stats.fileCount)", "\(stats.folderCount)",
                                     ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)))
            let suspicious = report.securityFindings.reduce(0) { $0 + $1.entryPaths.count }
            lines.append("\(L10n.format("inspect.suspiciousPaths.some", "\(suspicious)"))")
            lines.append("\(L10n.format("inspect.junk.some", "\(stats.junkCount)"))")
            lines.append("\(L10n.format("inspect.emptyDirs.some", "\(stats.emptyDirectoryCount)"))")
            lines.append("\(L10n.format("inspect.executables.some", "\(stats.executableCount)"))")
            lines.append("\(L10n.format("inspect.symlinks.some", "\(stats.symlinkCount)"))")
        } else {
            lines.append(L10n.text("inspect.notListable"))
        }
        if let sha256 = report.sha256 {
            lines.append("SHA-256: \(sha256)")
        }
        if let fingerprint = report.structuralFingerprint {
            lines.append("\(L10n.text("inspect.section.fingerprint")): \(fingerprint)")
        }
        if let hasPublicKey = report.publicKeyBesideSignature {
            lines.append((hasPublicKey ? "✓ " : "✗ ") + L10n.text(hasPublicKey ? "inspect.publicKey.present" : "inspect.publicKey.missing"))
        }
        return lines.joined(separator: "\n")
    }
}
