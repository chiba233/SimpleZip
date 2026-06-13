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
    /// 0.4.4 E:报告间跳转 —— 对同一归档打开空间分析(数据同源,按 URL 重列)。nil = 不显示。
    var onOpenSpaceAnalysis: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogHero(
                systemImage: "checklist",
                colors: [.teal, .green],
                title: L10n.text("inspect.title"),
                subtitle: report.archiveURL.lastPathComponent
            )

            HeightCappedScrollView(maxHeight: 580) {
                VStack(alignment: .leading, spacing: 12) {
                    // #10:质量门触发的规则置顶(警告档;阻断档的运行根本到不了报告 sheet)。
                    if !report.gateViolations.isEmpty {
                        DialogSection(L10n.text("releaseGate.section")) {
                            ForEach(report.gateViolations, id: \.rule) { violation in
                                gateViolationRow(violation)
                            }
                        }
                    }
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

                    // C:发布运行的步骤耗时(右键检查没有步骤引擎 → 空数组,整段不渲染)。
                    if !report.steps.isEmpty {
                        DialogSection(L10n.text("inspect.section.steps")) {
                            ForEach(report.steps, id: \.id) { step in
                                HStack(spacing: 8) {
                                    Image(systemName: step.status == .skipped ? "minus.circle" : (step.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                        .foregroundStyle(step.status == .skipped ? Color.secondary : (step.status == .succeeded ? Color.green : Color.red))
                                    Text(L10n.text("releaseAssistant.step.\(step.id.rawValue)"))
                                        .font(.callout)
                                    Spacer()
                                    Text(step.status == .skipped ? L10n.text("transfer.section.skipped") : step.formattedDuration)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
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
                // 用户点名:底栏一排文字按钮被截断 → 全部并进「导出报告」一个弹窗里选
                // (F2 四项 + 发布说明 / 全部复制 / SHA256SUMS)。
                ReportExportControl(report: report, extraActions: exportExtraActions)
                // E:跳转到同一归档的空间分析(bundle-only 检查没有归档侧数据,不显示)。
                if let onOpenSpaceAnalysis, !report.isBundleOnly {
                    Button {
                        onOpenSpaceAnalysis()
                        onClose()
                    } label: {
                        Label(L10n.text("space.menu"), systemImage: "chart.pie")
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
        .frame(width: 640)
    }

    /// 导出弹窗里的报告特有项:发布说明(#5)/ 全部复制 / 导出 SHA256SUMS(#11 前身)。
    private var exportExtraActions: [ReportExportControl.ExtraAction] {
        var actions: [ReportExportControl.ExtraAction] = []
        if !report.isBundleOnly {
            actions.append(.init(L10n.text("inspect.copyReleaseNotes")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(releaseNotesDraft, forType: .string)
            })
        }
        actions.append(.init(L10n.text("button.copyAll")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plainTextSummary, forType: .string)
        })
        if let onExportChecksums, !report.isBundleOnly {
            actions.append(.init(L10n.text("checksum.export.button")) {
                onExportChecksums()
            })
        }
        return actions
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

    /// #10:质量门违规行 —— 警告橙 ⚠ / 阻断红 ✗,带命中数。
    @ViewBuilder
    private func gateViolationRow(_ violation: ReleaseGate.Violation) -> some View {
        let name = L10n.text("releaseGate.rule.\(violation.rule.rawValue)")
        Label {
            Text(violation.count.map { "\(name) — \($0)" } ?? name)
        } icon: {
            Image(systemName: violation.isBlocking ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(violation.isBlocking ? Color.red : Color.orange)
        }
        .font(.callout)
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

    /// #5:发布说明草稿。版本 / 可复现 / SHA256SUMS 标记从发布账本认领(账面里有这次产物才有);
    /// GPG 段三道闸:gpgEnabled(A4)+ 产物旁恰好一个 .szs + 公钥 .asc 在场 + 默认签名密钥指纹可用 ——
    /// 缺任何一件就整段不出,不猜。
    private var releaseNotesDraft: String {
        let ledgerEntry = ReleaseLedgerStore().loadAll().first { $0.artifactPath == report.archiveURL.path }
        var inputs = ReleaseNotesDraft.Inputs(
            artifactName: report.archiveURL.lastPathComponent,
            versionLabel: ledgerEntry?.versionLabel,
            sha256: report.sha256,
            fileCount: report.stats?.fileCount,
            totalBytes: report.stats?.totalBytes,
            testPassed: report.testPassed,
            reproducible: ledgerEntry?.reproducible,
            wroteChecksums: ledgerEntry?.wroteChecksums ?? false
        )
        let defaultFingerprint = AppPreferences.gpgDefaultSigningKeyFingerprint
        if AppPreferences.gpgEnabled, !defaultFingerprint.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: report.archiveURL.deletingLastPathComponent().path) {
            let containers = names.filter { $0.lowercased().hasSuffix(".\(SZSArchive.extensionName)") }
            let publicKeys = names.filter { $0.lowercased().hasSuffix(".asc") }
            if containers.count == 1, publicKeys.count == 1 {
                inputs.signedContainerName = containers[0]
                inputs.publicKeyFileName = publicKeys[0]
                inputs.fingerprint = defaultFingerprint
            }
        }
        return ReleaseNotesDraft.make(inputs)
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

// MARK: - 统一导出（0.4.4 F2）

/// 发布检查报告接统一导出底座:Markdown 跟 UI 语言;JSON 字段名固定英文(交换格式契约)。
extension ArchiveBrowserModel.ReleaseInspectionReport: ReportExportable {
    var reportTitle: String { "\(L10n.text("inspect.title")) — \(archiveURL.lastPathComponent)" }
    var reportTargetPath: String? { archiveURL.path }

    var reportSummaryLine: String {
        var parts: [String] = [archiveURL.lastPathComponent]
        switch testPassed {
        case .some(true): parts.append(L10n.text("inspect.test.passed"))
        case .some(false): parts.append(L10n.text("inspect.test.failed"))
        case .none: break
        }
        if let stats {
            parts.append(L10n.format("inspect.entries", "\(stats.fileCount)", "\(stats.folderCount)",
                                     ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)))
            let issues = securityFindings.reduce(0) { $0 + $1.entryPaths.count } + stats.junkCount + stats.emptyDirectoryCount
            parts.append(L10n.format("inspect.summary.issues", "\(issues)"))
        }
        let failures = bundleFindings.filter { $0.severity == .failure || $0.severity == .warning }.count
        if failures > 0 {
            parts.append(L10n.format("inspect.summary.bundleIssues", "\(failures)"))
        }
        return parts.joined(separator: " · ")
    }

    func reportMarkdown(metadata: ReportMetadata?) -> String {
        var lines: [String] = []
        lines.append("# \(L10n.text("inspect.title"))")
        lines.append("")
        lines.append("**\(archiveURL.lastPathComponent)**")
        lines.append("")
        if !bundleFindings.isEmpty {
            lines.append("## \(L10n.text("inspect.section.bundle"))")
            lines.append("")
            for finding in bundleFindings {
                let mark: String
                switch finding.severity {
                case .pass: mark = "✓"
                case .info: mark = "ℹ︎"
                case .warning: mark = "⚠"
                case .failure: mark = "✗"
                }
                var line = "- \(mark) \(ReleaseInspectionView.bundleFindingTitle(finding))"
                if let detail = finding.detail, !detail.isEmpty {
                    line += " — `\(detail)`"
                }
                lines.append(line)
            }
            lines.append("")
        }
        if !isBundleOnly {
            switch testPassed {
            case .some(true): lines.append("- ✓ \(L10n.text("inspect.test.passed"))")
            case .some(false): lines.append("- ✗ \(L10n.text("inspect.test.failed")) — \(testFailureMessage ?? "")")
            case .none: lines.append("- \(L10n.text("inspect.test.skipped"))")
            }
            if let stats {
                lines.append("- \(L10n.format("inspect.entries", "\(stats.fileCount)", "\(stats.folderCount)", ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)))")
                let suspicious = securityFindings.reduce(0) { $0 + $1.entryPaths.count }
                lines.append("- \(L10n.format("inspect.suspiciousPaths.some", "\(suspicious)"))")
                lines.append("- \(L10n.format("inspect.junk.some", "\(stats.junkCount)"))")
                lines.append("- \(L10n.format("inspect.emptyDirs.some", "\(stats.emptyDirectoryCount)"))")
                lines.append("- \(L10n.format("inspect.executables.some", "\(stats.executableCount)"))")
                lines.append("- \(L10n.format("inspect.symlinks.some", "\(stats.symlinkCount)"))")
            } else {
                lines.append("- \(L10n.text("inspect.notListable"))")
            }
            if let hasPublicKey = publicKeyBesideSignature {
                lines.append("- \(hasPublicKey ? "✓" : "✗") \(L10n.text(hasPublicKey ? "inspect.publicKey.present" : "inspect.publicKey.missing"))")
            }
            if let sha256 {
                lines.append("")
                lines.append("`SHA-256: \(sha256)`")
            }
            if let structuralFingerprint {
                lines.append("")
                lines.append("`\(L10n.text("inspect.section.fingerprint")): \(structuralFingerprint)`")
            }
        }
        lines.append("")
        var markdown = lines.joined(separator: "\n")
        if let metadata {
            markdown += ReportExport.markdownFooter(metadata) + "\n"
        }
        return markdown
    }

    /// JSON 快照(只编码;字段名固定英文)。
    private struct JSONReport: Encodable {
        struct Stats: Encodable {
            let fileCount: Int
            let folderCount: Int
            let totalBytes: Int64
            let junkCount: Int
            let emptyDirectoryCount: Int
            let executableCount: Int
            let symlinkCount: Int
        }
        struct BundleFinding: Encodable {
            let severity: String
            let title: String
            let detail: String?
        }
        let archive: String
        let listable: Bool
        let testPassed: Bool?
        let testFailureMessage: String?
        let stats: Stats?
        let suspiciousPathCount: Int
        let hasComment: Bool
        let publicKeyBesideSignature: Bool?
        let sha256: String?
        let structuralFingerprint: String?
        let bundleFindings: [BundleFinding]
        let metadata: ReportMetadata?
    }

    func reportJSON(metadata: ReportMetadata?) throws -> String {
        let snapshot = JSONReport(
            archive: archiveURL.lastPathComponent,
            listable: listable,
            testPassed: testPassed,
            testFailureMessage: testFailureMessage,
            stats: stats.map {
                JSONReport.Stats(
                    fileCount: $0.fileCount,
                    folderCount: $0.folderCount,
                    totalBytes: $0.totalBytes,
                    junkCount: $0.junkCount,
                    emptyDirectoryCount: $0.emptyDirectoryCount,
                    executableCount: $0.executableCount,
                    symlinkCount: $0.symlinkCount
                )
            },
            suspiciousPathCount: securityFindings.reduce(0) { $0 + $1.entryPaths.count },
            hasComment: hasComment,
            publicKeyBesideSignature: publicKeyBesideSignature,
            sha256: sha256,
            structuralFingerprint: structuralFingerprint,
            bundleFindings: bundleFindings.map { finding in
                let severity: String
                switch finding.severity {
                case .pass: severity = "pass"
                case .info: severity = "info"
                case .warning: severity = "warning"
                case .failure: severity = "failure"
                }
                return JSONReport.BundleFinding(
                    severity: severity,
                    title: ReleaseInspectionView.bundleFindingTitle(finding),
                    detail: finding.detail
                )
            },
            metadata: metadata
        )
        return String(decoding: try ReportExport.jsonEncoder().encode(snapshot), as: UTF8.self)
    }
}
