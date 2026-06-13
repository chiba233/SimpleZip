//
//  ReportExportMenu.swift
//  SimpleZip
//
//  0.4.4 F2:统一报告导出控件 —— 放进各报告 sheet 的 PinnedBottomBar:
//  复制摘要 / 复制为 GitHub Issue / 导出 Markdown… / 导出 JSON…。
//  用原生 Menu 下拉(用户拍板):confirmationDialog 在 macOS 上塞不下「4 选项 + 取消」——
//  加取消会把「导出 JSON」挤掉。Menu 稳定显示全部项,点菜单外 / Esc 即取消(天然反悔出口),
//  也是 macOS 选导出格式的标准控件。保存走 NSSavePanel(照 ArchiveDiffView.exportReport 体例)。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 统一导出按钮。`report` 是任何接了 ReportExportable 的报告值。
/// `extraActions`:宿主报告特有的导出/复制项(发布说明、SHA256SUMS 等)挂进同一个弹窗 ——
/// 底栏只占一个按钮,不再排一排截断的文字按钮(用户点名)。
struct ReportExportControl: View {
    struct ExtraAction: Identifiable {
        let id = UUID()
        let title: String
        let action: () -> Void

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    let report: any ReportExportable
    var extraActions: [ExtraAction] = []

    var body: some View {
        // 与创建对话框「套用模板」同款下拉(用户点名):默认 Menu 样式 = 带 chevron 的 bordered 按钮,
        // .fixedSize 不被拉伸。复制类 / 导出类 / 宿主特有项用 Divider 分组。
        Menu {
            Button(L10n.text("report.copySummary")) { copySummary() }
            Button(L10n.text("report.copyAsIssue")) { copyAsIssue() }
            Divider()
            Button(L10n.text("report.export.markdown")) { export(.markdown) }
            Button(L10n.text("report.export.json")) { export(.json) }
            if !extraActions.isEmpty {
                Divider()
                ForEach(extraActions) { extra in
                    Button(extra.title, action: extra.action)
                }
            }
        } label: {
            Label(L10n.text("report.export.menu"), systemImage: "square.and.arrow.up")
        }
        .fixedSize()
    }

    private enum Format {
        case markdown, json
        var fileExtension: String { self == .markdown ? "md" : "json" }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.reportSummaryLine, forType: .string)
    }

    private func copyAsIssue() {
        let report = report
        Task { @MainActor in
            let metadata = await ReportMetadataBuilder.make(targetPath: report.reportTargetPath)
            let body = ReportExport.gitHubIssueBody(
                title: report.reportTitle,
                summaryLine: report.reportSummaryLine,
                reportMarkdown: report.reportMarkdown(metadata: nil),
                metadata: metadata
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
    }

    private func export(_ format: Format) {
        let report = report
        Task { @MainActor in
            let metadata = await ReportMetadataBuilder.make(targetPath: report.reportTargetPath)
            let content: String
            do {
                switch format {
                case .markdown: content = report.reportMarkdown(metadata: metadata)
                case .json: content = try report.reportJSON(metadata: metadata)
                }
            } catch {
                presentExportError(error)
                return
            }
            let panel = NSSavePanel()
            // 文件名 = 报告标题去掉路径分隔符(报告标题可能含归档名)。
            let stem = report.reportTitle.replacingOccurrences(of: "/", with: "-")
            panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
            if let type = UTType(filenameExtension: format.fileExtension) {
                panel.allowedContentTypes = [type]
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentExportError(error)
            }
        }
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("report.export.failedTitle")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// 报告元数据拼装:版本 / 系统一次性读取,后端版本要跑 `7zz -version` 子进程 ——
/// 取一次后静态缓存(避免每次导出都起进程)。
@MainActor
enum ReportMetadataBuilder {
    private static var cachedBackendVersion: String?

    static func make(targetPath: String?) async -> ReportMetadata {
        let backendVersion: String
        if let cachedBackendVersion {
            backendVersion = cachedBackendVersion
        } else {
            backendVersion = await ArchiveService.sevenZipVersion()
            cachedBackendVersion = backendVersion
        }
        return ReportMetadata(
            generatedAt: Date(),
            targetPath: targetPath,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            backendVersion: backendVersion
        )
    }
}
